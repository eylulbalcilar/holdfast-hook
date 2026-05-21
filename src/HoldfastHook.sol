// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ScoreAccumulator} from "./libraries/ScoreAccumulator.sol";

import {IHoldfastHook} from "./interfaces/IHoldfastHook.sol";
import {HoldfastNFT} from "./HoldfastNFT.sol";

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

    struct PositionStreak {
        uint256 accumulatedScore;
        uint256 lastUpdateBlock;
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

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HoldfastNFT public immutable nft;

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
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    constructor(IPoolManager _poolManager, HoldfastNFT _nft) BaseHook(_poolManager) {
        nft = _nft;
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
            afterSwapReturnDelta: false,
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

        emit PoolInitialized(poolId, sqrtPriceX96, tick);
        return this.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Defensive: only handle positive deltas. Removes go through afterRemoveLiquidity.
        if (params.liquidityDelta <= 0) {
            return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }

        bytes32 positionKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
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
            s.isActive = true;

            emit PositionOpened(
                positionKey,
                sender,
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
            s.isActive = true;

            emit PositionOpened(
                positionKey,
                sender,
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
            s.lastUpdateBlock = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes32 positionKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
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

        // Lazy tier evaluation: claim time may cross a tier threshold for an LP
        // who has accrued enough score and tenure since the last interaction.
        _evaluateAndMaybeMint(positionKey, sender);

        return this.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
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
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
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
    function _evaluateAndMaybeMint(bytes32 positionKey, address owner) internal {
        PositionStreak storage s = streaks[positionKey];
        if (s.firstActiveBlock == 0) return; // unknown position

        uint256 blocksActive = block.number - s.firstActiveBlock;
        uint8 nextTier = _evaluateNextTier(s.currentTier, s.accumulatedScore, blocksActive);
        if (nextTier == s.currentTier) return; // no transition

        if (s.currentTier == TIER_NONE) {
            // First crossing: mint a Bronze NFT and record the tokenId.
            // Note: nextTier may be Bronze, Silver, or Gold here (direct-jump cases).
            // The NFT contract mints at Bronze; we then upgrade to nextTier if higher.
            uint256 tokenId = nft.mint(owner, positionKey);
            s.nftTokenId = tokenId;
            s.currentTier = TIER_BRONZE;
            emit TierMinted(positionKey, owner, tokenId);

            if (nextTier > TIER_BRONZE) {
                nft.upgradeTier(tokenId, nextTier);
                s.currentTier = nextTier;
                emit TierUpgraded(positionKey, tokenId, nextTier);
            }
        } else {
            // Already minted: upgrade to nextTier.
            nft.upgradeTier(s.nftTokenId, nextTier);
            s.currentTier = nextTier;
            emit TierUpgraded(positionKey, s.nftTokenId, nextTier);
        }
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
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
