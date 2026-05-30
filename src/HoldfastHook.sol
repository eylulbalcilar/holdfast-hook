// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Position} from "v4-core/libraries/Position.sol";

import {ScoreAccumulator} from "./libraries/ScoreAccumulator.sol";

import {IHoldfastHook} from "./interfaces/IHoldfastHook.sol";
import {HoldfastNFT} from "./HoldfastNFT.sol";
import {YieldRouter} from "./YieldRouter.sol";

/// @title HoldfastHook
/// @notice Uniswap v4 hook measuring IL exposure, partially compensating realized IL,
///         and compounding rewards via Aave V3. Authoritative source of truth for tier
///         eligibility (HoldfastNFT trusts this contract; see DESIGN.md Trust Boundary).
/// @dev Lifecycle bodies are filled in subsequent steps. This skeleton wires permissions,
///      state, tier constants, helpers, and the IHoldfastHook.settleOnTransfer stub.
contract HoldfastHook is BaseHook, IHoldfastHook {
    uint8 internal constant TIER_NONE = 0;
    uint8 internal constant TIER_BRONZE = 1;
    uint8 internal constant TIER_SILVER = 2;
    uint8 internal constant TIER_GOLD = 3;

    uint256 internal constant BRONZE_SCORE = 10 * 1e18;
    uint256 internal constant SILVER_SCORE = 100 * 1e18;
    uint256 internal constant GOLD_SCORE = 1_000 * 1e18;

    uint256 internal constant BRONZE_BLOCKS = 1_000;
    uint256 internal constant SILVER_BLOCKS = 10_000;
    uint256 internal constant GOLD_BLOCKS = 100_000;

    uint8 internal constant VOL_BUFFER_LEN = 10;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant REDISTRIBUTION_RATE_DEFAULT = 15e16;
    uint256 internal constant VOL_MULT_LOWER = 5e17;
    uint256 internal constant VOL_MULT_UPPER = 15e17;
    uint256 internal constant VOL_MULT_MAX = 15e17;

    struct PositionStreak {
        uint256 accumulatedScore;
        uint256 lastUpdateBlock;
        uint256 lastGlobalScoreSnapshot; // global accumulator value at last position interaction (lazy update)
        uint256 firstActiveBlock;
        uint160 entrySqrtPriceX96;
        uint8 currentTier;
        uint256 nftTokenId;
        uint128 frozenAt;
        bool isActive;
        int256 realizedIL;
    }

    struct PoolVolatility {
        uint256[10] recentPriceObservations;
        uint8 cursor;
        uint256 cachedVolatility;
        uint256 lastVolUpdate;
    }

    mapping(bytes32 => PositionStreak) public streaks;
    mapping(PoolId => PoolVolatility) public volatility;
    mapping(PoolId => uint256) public globalScorePerLiquidity; // Curve gauge-style pool-level accumulator, incremented per swap
    mapping(PoolId => uint256) public lastGlobalScoreUpdateBlock;
    mapping(PoolId => uint256) public redistributionRate;

    /// @notice Sum of accumulatedScore across all active positions currently in a given tier.
    /// @dev    WAD scale; consumed by the claim flow for pro-rata tier shares.
    mapping(uint8 => uint256) public sumOfTierScores;

    /// @notice Sum of |realizedIL| across closed positions not yet claimed.
    uint256 public sumOfAbsoluteIL;
    mapping(PoolId => bool) public usdcIsToken0;

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HoldfastNFT public immutable nft;

    /// @notice The bound YieldRouter. Holds Aave V3 supply/withdraw plumbing.
    /// @dev Wired through the constructor. `_afterSwap` captures the redistribution
    ///      via `poolManager.take()` and supplies it to Aave V3 in the same call.
    YieldRouter public immutable yieldRouter;

    /// @notice The USDC token address. Bonus pool denomination; supplied to Aave V3
    ///         on capture, withdrawn on claim. Set once at construction.
    address public immutable usdc;

    /// @notice Thrown by `_afterInitialize` when neither pool currency is USDC.
    /// @dev Holdfast requires the pool to contain USDC as one of its two tokens.
    ///      See DESIGN.md Limitations (Non-USDC pools out of scope).
    error PoolMissingUSDC();

    /// @notice Thrown when a liquidity callback receives empty `hookData`.
    /// @dev    Owner cannot be resolved from `msg.sender` (which is the PoolManager
    ///         or a router contract), so callers MUST pass `abi.encode(lpOwner)` as
    ///         hookData on every modifyLiquidity call routed through this hook.
    error HookDataMissing();

    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint160 entrySqrtPriceX96,
        uint256 firstActiveBlock
    );

    event TierMinted(bytes32 indexed positionKey, address indexed owner, uint256 tokenId);
    event TierUpgraded(bytes32 indexed positionKey, uint256 indexed tokenId, uint8 newTier);
    event RealizedILComputed(bytes32 indexed positionKey, int256 il, uint160 currentSqrtPriceX96);
    event PositionClosed(bytes32 indexed positionKey, address indexed owner, uint256 accumulatedScore, int256 realizedIL, uint128 frozenAt);
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    constructor(IPoolManager _poolManager, HoldfastNFT _nft, YieldRouter _yieldRouter, address _usdc) BaseHook(_poolManager) {
        nft = _nft;
        yieldRouter = _yieldRouter;
        usdc = _usdc;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolVolatility storage vol = volatility[poolId];

        // Cold-start protection: seed the entire ring buffer with the initial sqrtPriceX96.
        // Variance of 10 identical observations is 0, so cachedVolatility is implicitly 0
        // until real swaps populate the buffer.
        for (uint256 i = 0; i < VOL_BUFFER_LEN; i++) {
            vol.recentPriceObservations[i] = sqrtPriceX96;
        }
        vol.cursor = 0;
        vol.cachedVolatility = 0;
        vol.lastVolUpdate = block.number;
        redistributionRate[poolId] = REDISTRIBUTION_RATE_DEFAULT;
        lastGlobalScoreUpdateBlock[poolId] = block.number;

        // Resolve which side of the pool is USDC. Pool must contain USDC; revert otherwise.
        // See DESIGN.md Limitations (Non-USDC pools out of scope).
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == usdc) {
            usdcIsToken0[poolId] = true;
        } else if (c1 == usdc) {
            usdcIsToken0[poolId] = false;
        } else {
            revert PoolMissingUSDC();
        }

        emit PoolInitialized(poolId, sqrtPriceX96, tick);
        return this.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Defensive: only handle positive deltas. Removes go through afterRemoveLiquidity.
        if (params.liquidityDelta <= 0) {
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        // Owner resolved from hookData (not msg.sender, which is the PoolManager).
        // See DESIGN.md State section ("hookData-based owner resolution").
        address owner = _decodeOwner(hookData);
        bytes32 positionKey = _positionKey(owner, params.tickLower, params.tickUpper, params.salt);
        PositionStreak storage s = streaks[positionKey];

        if (!s.isActive && s.firstActiveBlock == 0) {
            // New position: cold init.
            // Snapshot pool sqrtPriceX96 as IL baseline. firstActiveBlock anchors
            // the dual-criterion tenure check. No NFT mint here: Bronze threshold
            // is checked lazily on swap activity, not at position open.
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            s.entrySqrtPriceX96 = sqrtPriceX96;
            s.firstActiveBlock = block.number;
            s.lastUpdateBlock = block.number;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;

            emit PositionOpened(
                positionKey,
                owner,
                key.toId(),
                params.tickLower,
                params.tickUpper,
                sqrtPriceX96,
                block.number
            );
        } else if (!s.isActive && s.frozenAt > 0) {
            // Re-entry: previously frozen position is reopened by the same owner with
            // the same tick range. Streak resumes (accumulatedScore and currentTier
            // preserved) but IL baseline resets per DESIGN.md "Position Lifecycle".
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            s.entrySqrtPriceX96 = sqrtPriceX96;
            s.firstActiveBlock = block.number;
            s.lastUpdateBlock = block.number;
            s.frozenAt = 0;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;

            emit PositionOpened(
                positionKey,
                owner,
                key.toId(),
                params.tickLower,
                params.tickUpper,
                sqrtPriceX96,
                block.number
            );
        } else {
            // Liquidity increase on an already-active position. Entry snapshot and
            // firstActiveBlock are immutable for the position; only update the
            // lazy-update cursor so the next score accrual integrates from now.
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.lastUpdateBlock = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        address owner = _decodeOwner(hookData);
        bytes32 positionKey = _positionKey(owner, params.tickLower, params.tickUpper, params.salt);
        PositionStreak storage s = streaks[positionKey];

        // No streak (unknown position) or already frozen: nothing to compute.
        if (s.firstActiveBlock == 0 || !s.isActive) {
            return this.beforeRemoveLiquidity.selector;
        }

        // Read current pool price and compute realized IL against the entry baseline.
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        int256 il = ScoreAccumulator.calculateRealizedIL(s.entrySqrtPriceX96, currentSqrtPriceX96);
        s.realizedIL = il;
        emit RealizedILComputed(positionKey, il, currentSqrtPriceX96);

        // Settle accrued score with the still-current liquidity before any removal,
        // then advance the snapshot (Curve-gauge lazy update).
        {
            uint128 liq = poolManager.getPositionLiquidity(key.toId(), positionKey);
            uint256 narrowness = ScoreAccumulator.calculateRangeNarrowness(params.tickLower, params.tickUpper);
            _settlePositionScore(positionKey, key.toId(), liq, narrowness);
        }

        // Lazy tier evaluation: claim time may cross a tier threshold for an LP
        // who has accrued enough score and tenure since the last interaction.
        _evaluateAndMaybeMint(positionKey, owner);

        return this.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        address owner = _decodeOwner(hookData);
        bytes32 positionKey = _positionKey(owner, params.tickLower, params.tickUpper, params.salt);
        PositionStreak storage s = streaks[positionKey];

        // Unknown position (never opened through the hook): no-op.
        if (s.firstActiveBlock == 0) {
            return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
        }

        // Authoritative residual liquidity read from PoolManager.
        uint128 remaining = poolManager.getPositionLiquidity(key.toId(), positionKey);

        if (remaining == 0) {
            // Full closure: freeze the streak. Tier persists (no downgrade) and
            // accumulatedScore is preserved so a future re-entry resumes the streak.
            // Tier accounting: closed positions exit the tier sum (claim flow only
            // distributes among active positions). Realized-IL accounting: |IL| enters
            // the realized-IL arm sum for proportional distribution.
            if (s.currentTier != TIER_NONE) {
                sumOfTierScores[s.currentTier] -= s.accumulatedScore;
            }
            if (s.realizedIL < 0) {
                sumOfAbsoluteIL += uint256(-s.realizedIL);
            }
            s.isActive = false;
            s.frozenAt = uint128(block.number);
            emit PositionClosed(positionKey, owner, s.accumulatedScore, s.realizedIL, uint128(block.number));
        } else {
            // Partial closure: liquidityShare in the score formula adjusts on the
            // next afterSwap accrual. Only bump the lazy-update cursor here.
            s.lastUpdateBlock = block.number;
        }

        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 vf = _updateVolatility(poolId);
        _advanceGlobalScore(poolId, vf);

        // Capture only when USDC is the swap's UNSPECIFIED currency. The afterSwap
        // hookDelta return value is applied by PoolManager to the unspecified currency;
        // if USDC is specified, returning a delta would credit/debit the wrong currency
        // and break settlement (see DESIGN.md Limitations on capture coverage).
        //
        // Mapping:
        //   exactIn  (amountSpecified < 0): specified = input  currency
        //   exactOut (amountSpecified > 0): specified = output currency
        //   zeroForOne = true  -> input = currency0, output = currency1
        //   zeroForOne = false -> input = currency1, output = currency0
        bool isToken0 = usdcIsToken0[poolId];
        bool exactIn = params.amountSpecified < 0;
        bool usdcIsSpecified;
        if (exactIn) {
            usdcIsSpecified = (isToken0 == params.zeroForOne);
        } else {
            usdcIsSpecified = (isToken0 != params.zeroForOne);
        }
        if (usdcIsSpecified) {
            return (this.afterSwap.selector, 0);
        }

        // USDC is unspecified. Read its delta from BalanceDelta and capture a fraction.
        int128 usdcSideDelta = isToken0 ? delta.amount0() : delta.amount1();
        uint256 usdcAbs = usdcSideDelta < 0
            ? uint256(uint128(-usdcSideDelta))
            : uint256(uint128(usdcSideDelta));

        uint256 captureRate = (redistributionRate[poolId] * _volatilityMultiplier(vf)) / WAD;
        uint256 captureAmt = (usdcAbs * captureRate) / WAD;
        if (captureAmt == 0) {
            return (this.afterSwap.selector, 0);
        }

        // Take captured USDC from PoolManager into the YieldRouter, then supply to Aave V3.
        // Returning a positive hookDelta on the unspecified currency offsets the take(),
        // so the PoolManager's accounting nets to zero for the hook and the redistribution
        // is funded by reducing the LP-direct fee accrual, not an extra swapper payment.
        poolManager.take(Currency.wrap(usdc), address(yieldRouter), captureAmt);
        yieldRouter.supplyToAave(captureAmt);

        // captureAmt is bounded by the USDC side of a single swap delta, which the
        // PoolManager itself stores as int128; the downcast cannot overflow in practice.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (this.afterSwap.selector, int128(int256(captureAmt)));
    }

    function _updateVolatility(PoolId poolId) internal returns (uint256 vf) {
        PoolVolatility storage vol = volatility[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        vol.recentPriceObservations[vol.cursor] = sqrtPriceX96;
        vol.cursor = uint8((vol.cursor + 1) % VOL_BUFFER_LEN);
        uint160[10] memory ordered = _orderedObservations(vol);
        vf = ScoreAccumulator.calculateVolatilityFactor(ordered);
        vol.cachedVolatility = vf;
        vol.lastVolUpdate = block.number;
    }

    function _advanceGlobalScore(PoolId poolId, uint256 vf) internal {
        uint256 totalLiquidity = poolManager.getLiquidity(poolId);
        uint256 blocksDelta = block.number - lastGlobalScoreUpdateBlock[poolId];
        if (totalLiquidity > 0 && blocksDelta > 0 && vf > 0) {
            globalScorePerLiquidity[poolId] += (vf * blocksDelta * WAD) / totalLiquidity;
        }
        lastGlobalScoreUpdateBlock[poolId] = block.number;
    }


    function _orderedObservations(PoolVolatility storage vol)
        internal
        view
        returns (uint160[10] memory ordered)
    {
        uint8 c = vol.cursor;
        for (uint256 i = 0; i < VOL_BUFFER_LEN; i++) {
            ordered[i] = uint160(vol.recentPriceObservations[(c + i) % VOL_BUFFER_LEN]);
        }
    }

    function _volatilityMultiplier(uint256 volatilityFactor)
        internal
        pure
        returns (uint256)
    {
        if (volatilityFactor <= VOL_MULT_LOWER) return WAD;
        if (volatilityFactor >= VOL_MULT_UPPER) return VOL_MULT_MAX;
        return WAD + ((volatilityFactor - VOL_MULT_LOWER) * 5e17) / WAD;
    }

    /// @inheritdoc IHoldfastHook
    /// @dev Stub: real settlement logic lands in Day 7-8 once bonus pool accounting exists.
    function settleOnTransfer(bytes32 positionKey, address from, address to) external {
        require(msg.sender == address(nft), "HoldfastHook: only nft");
        positionKey; from; to;
    }

    /// @notice Lazy tier evaluation: check the dual criterion and call into the NFT
    ///         if a transition is warranted. Single source of truth for mint and
    ///         upgrade gating; HoldfastNFT performs no redundant checks.
    /// @dev Called from afterSwap (after score accrual) and beforeRemoveLiquidity
    ///         (so a position settling its IL also realizes any pending tier crossing).
    /// @notice Lazy Curve-gauge settle: fold the pool accumulator delta into the
    ///         position score, weighted by liquidity and rangeNarrowness, then advance
    ///         the per-position snapshot. Matches the eager per-block sum.
    function _settlePositionScore(
        bytes32 positionKey,
        PoolId poolId,
        uint128 liquidity,
        uint256 rangeNarrowness
    ) internal {
        PositionStreak storage s = streaks[positionKey];
        uint256 globalNow = globalScorePerLiquidity[poolId];
        uint256 delta = globalNow - s.lastGlobalScoreSnapshot;
        if (delta > 0 && liquidity > 0) {
            s.accumulatedScore += (uint256(liquidity) * delta / WAD) * rangeNarrowness / WAD;
        }
        s.lastGlobalScoreSnapshot = globalNow;
    }

    function _evaluateAndMaybeMint(bytes32 positionKey, address owner) internal {
        PositionStreak storage s = streaks[positionKey];
        if (s.firstActiveBlock == 0) return; // unknown position
        uint256 blocksActive = block.number - s.firstActiveBlock;
        uint8 nextTier = _evaluateNextTier(s.currentTier, s.accumulatedScore, blocksActive);
        if (nextTier == s.currentTier) return; // no transition
        // Tier accounting: a position enters its first tier with its full accumulatedScore.
        // On upgrade the score moves from the old bucket to the new one.
        if (s.currentTier == TIER_NONE) {
            uint256 tokenId = nft.mint(owner, positionKey);
            s.nftTokenId = tokenId;
            s.currentTier = TIER_BRONZE;
            sumOfTierScores[TIER_BRONZE] += s.accumulatedScore;
            emit TierMinted(positionKey, owner, tokenId);
            if (nextTier > TIER_BRONZE) {
                nft.upgradeTier(tokenId, nextTier);
                sumOfTierScores[TIER_BRONZE] -= s.accumulatedScore;
                sumOfTierScores[nextTier] += s.accumulatedScore;
                s.currentTier = nextTier;
                emit TierUpgraded(positionKey, tokenId, nextTier);
            }
        } else {
            sumOfTierScores[s.currentTier] -= s.accumulatedScore;
            sumOfTierScores[nextTier] += s.accumulatedScore;
            nft.upgradeTier(s.nftTokenId, nextTier);
            s.currentTier = nextTier;
            emit TierUpgraded(positionKey, s.nftTokenId, nextTier);
        }
    }

    function _decodeOwner(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length != 32) {
            revert HookDataMissing();
        }
        return abi.decode(hookData, (address));
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        // Byte-identical with Uniswap v4's Position.calculatePositionKey so the
        // same key can be passed to StateLibrary.getPositionLiquidity. See
        // DESIGN.md: position key salt section.
        return Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
    }

    function _evaluateNextTier(uint8 currentTier, uint256 accumulatedScore, uint256 blocksActive)
        internal
        pure
        returns (uint8 nextTier)
    {
        if (currentTier < TIER_GOLD && accumulatedScore >= GOLD_SCORE && blocksActive >= GOLD_BLOCKS) {
            return TIER_GOLD;
        }
        if (currentTier < TIER_SILVER && accumulatedScore >= SILVER_SCORE && blocksActive >= SILVER_BLOCKS) {
            return TIER_SILVER;
        }
        if (currentTier < TIER_BRONZE && accumulatedScore >= BRONZE_SCORE && blocksActive >= BRONZE_BLOCKS) {
            return TIER_BRONZE;
        }
        return currentTier;
    }
}
