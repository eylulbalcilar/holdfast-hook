// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ISubscriber} from "v4-periphery/interfaces/ISubscriber.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {ScoreAccumulator} from "./libraries/ScoreAccumulator.sol";
import {HoldfastNFT} from "./HoldfastNFT.sol";
import {YieldRouter} from "./YieldRouter.sol";

/// @title HoldfastHookV2
/// @notice Subscriber-native rewrite of the Holdfast hook. A single contract that is
///         simultaneously a Uniswap v4 BaseHook and a canonical PositionManager
///         ISubscriber. Per-position state is keyed by the canonical PositionManager
///         ERC-721 tokenId, removing the V1 hookData-asserted identity surface.
///         See DESIGN.md "V2 Roadmap (Subscriber-Native)".
/// @dev Two distinct call surfaces, two distinct guards that never overlap:
///      - Pool lifecycle callbacks (afterInitialize, beforeSwap, afterSwap) enter
///        through BaseHook's external wrappers, which are `onlyPoolManager`
///        (msg.sender == address(poolManager)). Only the internal `_` bodies are
///        overridden here.
///      - Subscriber notifications (notifySubscribe, notifyModifyLiquidity,
///        notifyBurn, notifyUnsubscribe) are `onlyByPosm`
///        (msg.sender == address(positionManager)).
///      poolManager and positionManager are different contracts, so no function is
///      ever reachable through both guards.
///
///      STEP 2/3 SCAFFOLD: notification bodies are intentionally empty stubs
///      (signatures + guard only); lifecycle bodies return their selectors only.
///      Handler logic lands in Step 4+.
contract HoldfastHookV2 is BaseHook, ISubscriber, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

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

    // Bonus pool split: tier-weighted arm 70%, realized-IL arm 30%.
    uint256 internal constant TIER_ARM_BPS = 7000;
    uint256 internal constant IL_ARM_BPS = 3000;
    uint256 internal constant BPS_DENOM = 10_000;

    // Tier-weighted arm allocation (DESIGN.md): Gold 40%, Silver 35%, Bronze 25%.
    uint256 internal constant BRONZE_ALLOC_BPS = 2500;
    uint256 internal constant SILVER_ALLOC_BPS = 3500;
    uint256 internal constant GOLD_ALLOC_BPS = 4000;

    // WAD-internal bonus-pool accounting; USDC is 6 decimals, WAD is 18.
    uint256 internal constant USDC_TO_WAD = 1e12; // WAD / 1e6, scales a USDC amount up to WAD
    uint256 internal constant WAD = 1e18;
    uint8 internal constant VOL_BUFFER_LEN = 10;

    /// @notice Per-position streak state, keyed by the canonical PositionManager tokenId.
    /// @dev `owner` is cached from IPositionManager.ownerOf at notifySubscribe and is the
    ///      claim-authorization source in V2 (not a live ownerOf read, not NFT.ownerOf).
    ///      `liquidity` baselines from getPositionLiquidity at subscription and tracks the
    ///      authoritative liquidityChange from notifyModifyLiquidity. poolId/tickLower/
    ///      tickUpper are cached from getPoolAndPositionInfo at subscription.
    struct PositionStreak {
        address owner;                    // cached from IPositionManager.ownerOf at notifySubscribe; claim auth source
        uint256 accumulatedScore;         // lifetime, tier qualification and pro-rata
        uint128 liquidity;                // baseline from getPositionLiquidity, tracked via notifyModifyLiquidity
        uint256 lastGlobalScoreSnapshot;  // Curve gauge-style lazy-update cursor
        uint256 firstActiveBlock;         // tier minimum tenure check
        uint160 entrySqrtPriceX96;        // realized IL baseline
        uint8 currentTier;                // 0=none, 1=bronze, 2=silver, 3=gold
        uint256 nftTokenId;               // HoldfastNFT badge id (distinct from the posm tokenId key)
        uint128 frozenAt;                 // block set on unsubscribe/burn; best-effort
        bool isFrozen;                    // best-effort frozen flag set in notifyUnsubscribe; correctness must not depend on it
        bool isActive;
        int256 realizedIL;                // finalized at notifyBurn / liquidity decrease
        PoolId poolId;                    // cached at notifySubscribe
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Position streak state keyed by canonical PositionManager tokenId.
    /// @dev Internal (not public): the auto-generated getter for this 15-field struct
    ///      overflows the stack without via-ir. `getStreak` is the external read path,
    ///      mirroring the V1 HoldfastHook decision for the same reason.
    mapping(uint256 tokenId => PositionStreak) internal streaks;

    /// @notice Read a position's full streak state, keyed by canonical PositionManager tokenId.
    function getStreak(uint256 tokenId) external view returns (PositionStreak memory) {
        return streaks[tokenId];
    }

    /// @notice Curve gauge-style pool-level score accumulator, incremented on every swap.
    /// @dev Read by _settleScore as the lazy-update cursor; advanced in _afterSwap.
    mapping(PoolId => uint256) public globalScorePerLiquidity;

    /// @notice Block at which globalScorePerLiquidity was last advanced for a pool.
    mapping(PoolId => uint256) public lastGlobalScoreUpdateBlock;

    /// @notice Per-pool volatility ring buffer (10 recent sqrtPriceX96 observations).
    struct PoolVolatility {
        uint256[10] recentPriceObservations;
        uint8 cursor;
        uint256 cachedVolatility;
        uint256 lastVolUpdate;
    }

    /// @notice Per-pool volatility state, seeded in _afterInitialize, updated each swap.
    mapping(PoolId => PoolVolatility) public volatility;

    /// @notice Reward finalized to an owner whose position was re-subscribed under a new owner.
    /// @dev WAD-scaled accrued score parked for later conversion and payout via the claim/
    ///      withdraw path. Writing here is a storage write only, no external call.
    mapping(address => uint256) public pendingClaim;

    /// @notice Sum of accumulatedScore across active positions in a given tier (WAD scale).
    /// @dev Decremented (clamped) on burn; the increment side lands with the swap-path
    ///      score accrual in a later step.
    mapping(uint8 => uint256) public sumOfTierScores;

    /// @notice Sum of |realizedIL| across closed positions, denominator for the realized-IL
    ///         claim arm.
    uint256 public sumOfAbsoluteIL;

    /// @notice The canonical Uniswap v4 PositionManager this hook subscribes to.
    /// @dev Sole authorized caller of the ISubscriber notification surface (onlyByPosm).
    IPositionManager public immutable positionManager;

    /// @notice Tier badge NFT. Bound at construction.
    HoldfastNFT public immutable nft;

    /// @notice Aave V3 supply/withdraw adapter holding the bonus pool.
    YieldRouter public immutable yieldRouter;

    /// @notice USDC token; bonus pool denomination.
    address public immutable usdc;

    /// @notice Thrown when a subscriber notification is called by anyone other than the
    ///         bound PositionManager.
    error NotPositionManager();

    /// @notice Thrown when claim is called by anyone other than the cached position owner.
    error NotPositionOwner();

    /// @notice Emitted on every claim. Share amounts are WAD-internal; totals are USDC-native.
    event Claimed(
        uint256 indexed tokenId,
        address indexed claimer,
        uint256 tierShareWad,
        uint256 ilShareWad,
        uint256 totalUsdc,
        uint256 actualPaidUsdc
    );

    /// @notice Restricts the ISubscriber notification surface to the bound PositionManager.
    /// @dev Distinct from BaseHook's `onlyPoolManager` (which checks address(poolManager)).
    ///      positionManager != poolManager, so the two guards never authorize the same call.
    modifier onlyByPosm() {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        HoldfastNFT _nft,
        YieldRouter _yieldRouter,
        address _usdc
    ) BaseHook(_poolManager) {
        positionManager = _positionManager;
        nft = _nft;
        yieldRouter = _yieldRouter;
        usdc = _usdc;
    }

    /// @notice V2 permission set: only afterInitialize, beforeSwap, afterSwap, and the
    ///         afterSwap return-delta. Liquidity-lifecycle hooks are disabled; liquidity
    ///         accounting moves to the subscriber notification surface.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
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

    // ---------------------------------------------------------------------
    // Pool lifecycle callbacks (onlyPoolManager via BaseHook external wrappers)
    // ---------------------------------------------------------------------

    /// @dev Seed the volatility ring buffer with the initial price so the first swaps
    ///      produce low-variance output rather than a cold-start ZeroSqrtPriceObservation
    ///      revert (DESIGN.md), and anchor the global-score update block.
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolVolatility storage vol = volatility[poolId];
        for (uint256 i = 0; i < VOL_BUFFER_LEN; i++) {
            vol.recentPriceObservations[i] = sqrtPriceX96;
        }
        vol.cursor = 0;
        vol.cachedVolatility = 0;
        vol.lastVolUpdate = block.number;
        lastGlobalScoreUpdateBlock[poolId] = block.number;
        return this.afterInitialize.selector;
    }

    /// @dev Intentional no-op. V2 has no before-swap logic; the BEFORE_SWAP_FLAG is part of
    ///      the permission set but the body deliberately does nothing. `pure` documents that.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Score-accumulation path: refresh the volatility factor from the ring buffer and
    ///      advance the Curve-gauge accumulator globalScorePerLiquidity. STEP 9 scope is score
    ///      accrual only; the USDC capture into the bonus pool (take + supplyToAave + return
    ///      delta) is a later step, so a zero hook delta is returned for now.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 vf = _updateVolatility(poolId);
        _advanceGlobalScore(poolId, vf);
        return (this.afterSwap.selector, 0);
    }

    /// @dev Push the current sqrtPriceX96 into the ring buffer and recompute the cached
    ///      volatility factor over the ordered window via ScoreAccumulator.
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

    /// @dev Advance the pool-level accumulator: per block, each unit of liquidity earns
    ///      volatilityFactor / totalLiquidity. liquidityShare (numerator) and rangeNarrowness
    ///      are applied per position in _settleScore.
    function _advanceGlobalScore(PoolId poolId, uint256 vf) internal {
        uint256 totalLiquidity = poolManager.getLiquidity(poolId);
        uint256 blocksDelta = block.number - lastGlobalScoreUpdateBlock[poolId];
        if (totalLiquidity > 0 && blocksDelta > 0 && vf > 0) {
            globalScorePerLiquidity[poolId] += (vf * blocksDelta * WAD) / totalLiquidity;
        }
        lastGlobalScoreUpdateBlock[poolId] = block.number;
    }

    /// @dev Return the 10-observation window ordered oldest-to-newest from the ring buffer.
    function _orderedObservations(PoolVolatility storage vol)
        internal
        view
        returns (uint160[10] memory ordered)
    {
        uint8 c = vol.cursor;
        for (uint256 i = 0; i < VOL_BUFFER_LEN; i++) {
            // Observations are stored sqrtPriceX96 values (uint160 range); the cast is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            ordered[i] = uint160(vol.recentPriceObservations[(c + i) % VOL_BUFFER_LEN]);
        }
    }

    // ---------------------------------------------------------------------
    // ISubscriber notification surface (onlyByPosm)
    // STEP 2/3: empty stubs; handler bodies land in Step 4.
    // notifyModifyLiquidity and notifyBurn MUST NEVER revert (they bubble up and
    // revert the LP's tx in v4-periphery); all external calls are deferred to claim.
    // ---------------------------------------------------------------------

    /// @inheritdoc ISubscriber
    /// @notice Authoritative reconciliation point for identity. Not gas-capped, kept minimal.
    /// @dev Reads identity and position state from the canonical PositionManager, then either
    ///      cold-inits a fresh streak or, on a re-subscribe under a DIFFERENT owner, finalizes
    ///      the prior owner's accrued score into pendingClaim BEFORE resetting for the new
    ///      owner (order is load-bearing: resetting first would discard the old score).
    ///      No external state-changing calls (no Aave); pendingClaim is a pure storage write.
    ///      No loops. Bounded work.
    function notifySubscribe(uint256 tokenId, bytes memory /*data*/) external onlyByPosm {
        // Authoritative identity and position state from the canonical PositionManager.
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId pid = poolKey.toId();
        int24 tl = info.tickLower();
        int24 tu = info.tickUpper();
        uint128 liq = positionManager.getPositionLiquidity(tokenId);

        // getPoolAndPositionInfo yields the range/pool but not the live price; read slot0
        // from PoolManager directly for the realized-IL entry baseline.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);

        PositionStreak storage s = streaks[tokenId];

        if (s.isActive && s.owner != owner) {
            // Re-subscribe under a NEW owner. Finalize the prior owner's accrued score
            // into pendingClaim FIRST, so it is never lost, then reset for the new owner.
            pendingClaim[s.owner] += s.accumulatedScore;

            s.owner = owner;
            s.accumulatedScore = 0;
            s.liquidity = liq;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[pid];
            s.firstActiveBlock = block.number;
            s.entrySqrtPriceX96 = sqrtPriceX96;
            s.poolId = pid;
            s.tickLower = tl;
            s.tickUpper = tu;
            s.frozenAt = 0;
            s.isFrozen = false;
            s.isActive = true;
            return;
        }

        if (!s.isActive) {
            // Cold init: first subscription for this tokenId.
            s.owner = owner;
            s.liquidity = liq;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[pid];
            s.firstActiveBlock = block.number;
            s.entrySqrtPriceX96 = sqrtPriceX96;
            s.poolId = pid;
            s.tickLower = tl;
            s.tickUpper = tu;
            s.isActive = true;
            return;
        }

        // s.isActive && s.owner == owner: same-owner re-subscribe. Not specified for Step 4;
        // leave the streak intact (no reset, no data loss).
    }

    /// @inheritdoc ISubscriber
    /// @notice Lazy score settle plus authoritative liquidity tracking on every modify.
    /// @dev MUST NEVER REVERT. This notification bubbles up inside the LP's own
    ///      modifyLiquidity transaction, so a revert here would brick the LP's position
    ///      operation. Defenses: all arithmetic is `unchecked` (wraps, never reverts) and
    ///      the only external calls (NFT mint/upgrade) are wrapped in try/catch. No Aave,
    ///      no require, no loops.
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta /*feesAccrued*/)
        external
        onlyByPosm
    {
        PositionStreak storage s = streaks[tokenId];

        // 1+2) Settle accrued score with the OLD liquidity, BEFORE applying the change, so the
        //      just-ended period is scored at the liquidity that earned it. The shared helper
        //      also keeps sumOfTierScores in step for a tiered position. Never reverts.
        _settleScore(tokenId);

        unchecked {
            // 3) Apply the authoritative signed liquidity change. liquidityChange may be
            //    negative (partial or full remove). Compute in int256: widening the cached
            //    uint128 via int256(uint256(...)) is always value-preserving and the sum is
            //    in range for uint128-bounded inputs, so the addition cannot overflow. A
            //    direct int256->uint128 cast is disallowed, so narrow through uint256; the
            //    uint128 truncation never reverts.
            int256 newLiquidity = int256(uint256(s.liquidity)) + liquidityChange;
            // Defensive clamp: if cached liquidity and the authoritative delta ever diverge
            // so that newLiquidity is negative, clamp to 0 rather than wrapping a negative
            // value into a huge uint128. Pure branch, no revert (no require, no error).
            if (newLiquidity < 0) {
                s.liquidity = 0;
            } else {
                // Intentional truncation: the never-revert invariant forbids a checked cast.
                // forge-lint: disable-next-line(unsafe-typecast)
                s.liquidity = uint128(uint256(newLiquidity));
            }
        }

        // 4) Lazy tier evaluation; badge mint/upgrade is revert-safe (try/catch).
        _evaluateAndMaybeMint(tokenId);
    }

    /// @inheritdoc ISubscriber
    /// @notice Final score settle, realized-IL snapshot, and streak freeze on position burn.
    /// @dev MUST NEVER REVERT (bubbles up in the LP's burn tx). Arithmetic is unchecked or
    ///      structurally guarded, the tier-sum subtraction is clamped, and the only
    ///      non-storage interaction is getSlot0 (a view staticcall). No Aave, no require,
    ///      no loops. Idempotent: a burn on an already-frozen streak returns early.
    function notifyBurn(
        uint256 tokenId,
        address, // owner (unused; cached streak.owner is authoritative)
        PositionInfo, // info (unused; cached poolId/ticks)
        uint256, // liquidity (unused)
        BalanceDelta // feesAccrued (unused)
    ) external onlyByPosm {
        PositionStreak storage s = streaks[tokenId];

        // Double-burn / burn-after-freeze guard: idempotent, no revert.
        if (!s.isActive) return;

        // 1) Final score settle (shared helper; also keeps sumOfTierScores exact). Never reverts.
        _settleScore(tokenId);

        // 2) Realized IL against the entry baseline. getSlot0 is a view staticcall (allowed);
        //    reuse the existing constant-product formula, do not reimplement it.
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(s.poolId);
        int256 il = ScoreAccumulator.calculateRealizedIL(s.entrySqrtPriceX96, currentSqrtPriceX96);
        s.realizedIL = il;

        // 3) Freeze the streak.
        s.isActive = false;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.frozenAt = uint128(block.number);

        // 4) Tier accounting. Clamped subtraction so a position that never reached a tier
        //    (currentTier == NONE) or whose score was never added to the bucket cannot
        //    underflow. abs(IL) (the formula returns a non-positive value, so il < 0 means a
        //    real loss) feeds the realized-IL claim arm.
        if (s.currentTier != TIER_NONE) {
            uint256 bucket = sumOfTierScores[s.currentTier];
            uint256 score = s.accumulatedScore;
            sumOfTierScores[s.currentTier] = bucket >= score ? bucket - score : 0;
        }
        if (il < 0) {
            unchecked {
                // Safe: il < 0 here, so -il is positive and the uint256 cast is exact.
                // forge-lint: disable-next-line(unsafe-typecast)
                sumOfAbsoluteIL += uint256(-il);
            }
        }
    }

    /// @inheritdoc ISubscriber
    /// @notice Best-effort frozen flag on unsubscribe. PositionManager gas-caps this call
    ///         and swallows its result in a try/catch, so correctness MUST NOT depend on it
    ///         executing. The authoritative reconciliation is notifySubscribe, which
    ///         finalizes any prior owner's accrued score into pendingClaim on re-subscribe.
    /// @dev Absolute minimum: a single storage write. No isActive change, no settle, no tier
    ///      accounting, no IL, no external call, no require, no loop.
    function notifyUnsubscribe(uint256 tokenId) external onlyByPosm {
        streaks[tokenId].isFrozen = true;
    }

    // ---------------------------------------------------------------------
    // Claim (runs in the LP's own tx frame: external calls and reverts allowed)
    // ---------------------------------------------------------------------

    /// @notice Settle and recompute tier for a position ahead of payout. STEP 8a implements
    ///         authorization, the final lazy settle, and tier accounting only; the Aave
    ///         withdraw and USDC transfer are STEP 8b.
    /// @dev Unlike the notify handlers, claim runs in the LP's own transaction frame (not
    ///      bubbled up by PositionManager), so external calls and revert-on-bad-input are
    ///      allowed and correct here. Authorization binds to the CACHED streak.owner, never
    ///      posm.ownerOf: a transferred position arrives unsubscribed, and its new owner must
    ///      re-subscribe to accrue, they cannot claim the prior owner's cached balance.
    function claim(uint256 tokenId) external nonReentrant {
        PositionStreak storage s = streaks[tokenId];

        // Authorization: cached owner only. This is the one place a revert is correct.
        if (msg.sender != s.owner) revert NotPositionOwner();

        // Settle and re-evaluate tier only while the streak is active. A frozen/burned streak
        // already had its final settle and tier accounting in notifyBurn (which also removed
        // it from sumOfTierScores); re-running here would double-count the score and re-add a
        // burned position to the tier sum, breaking the notifyBurn decrement invariant.
        if (s.isActive) {
            _settleScore(tokenId);
            _evaluateAndMaybeMint(tokenId);
        }

        // ---- STEP 8b: payout ----

        // Bonus pool is the router's real aUSDC balance (Aave supply + accrued yield),
        // USDC-native. Express it in WAD for the internal share math; the single conversion
        // back to USDC-native happens once, at the transfer boundary below.
        uint256 bonusPoolUsdc = IERC20(yieldRouter.aUsdc()).balanceOf(address(yieldRouter));
        uint256 bonusPoolWad = bonusPoolUsdc * USDC_TO_WAD;

        // 1) Tier-weighted arm (70%): tierAlloc * (userScore / freshSumOfTierScores[tier]).
        //    Division guarded: a zero denominator or zero user score yields a zero share.
        uint256 tierShareWad = 0;
        uint8 tier = s.currentTier;
        if (tier != TIER_NONE) {
            uint256 tierDenom = sumOfTierScores[tier];
            uint256 userScore = s.accumulatedScore;
            if (tierDenom != 0 && userScore != 0) {
                uint256 tierAllocBps =
                    tier == TIER_GOLD ? GOLD_ALLOC_BPS : (tier == TIER_SILVER ? SILVER_ALLOC_BPS : BRONZE_ALLOC_BPS);
                tierShareWad = (bonusPoolWad * TIER_ARM_BPS * tierAllocBps * userScore)
                    / (BPS_DENOM * BPS_DENOM * tierDenom);
            }
        }

        // 2) Realized-IL arm (30%): ilArm * (|userIL| / sumOfAbsoluteIL). Only positions with a
        //    realized loss participate; division guarded against a zero denominator.
        uint256 ilShareWad = 0;
        if (s.realizedIL < 0 && sumOfAbsoluteIL != 0) {
            uint256 absIl = uint256(-s.realizedIL);
            ilShareWad = (bonusPoolWad * IL_ARM_BPS * absIl) / (BPS_DENOM * sumOfAbsoluteIL);
        }

        // 3) Sum the WAD shares and convert to USDC-native exactly ONCE, at this boundary.
        //    Integer division truncates toward zero, rounding down in the protocol's favor.
        uint256 totalWad = tierShareWad + ilShareWad;
        uint256 totalUsdc = totalWad * 1e6 / 1e18;

        // Nothing payable (empty pool or sub-USDC dust): do not consume the position's score or
        // call the router (which reverts on a zero-amount withdraw). The score is preserved for
        // a later claim once the pool grows.
        if (totalUsdc == 0) {
            emit Claimed(tokenId, msg.sender, tierShareWad, ilShareWad, 0, 0);
            return;
        }

        // 4) EFFECTS BEFORE INTERACTIONS: remove this position's contribution from the
        //    denominators and zero its claimable state, so a repeat/re-entrant claim finds
        //    nothing left. Clamped subtractions never underflow. nonReentrant is the backstop.
        if (tierShareWad > 0) {
            uint256 bucket = sumOfTierScores[tier];
            uint256 userScore = s.accumulatedScore;
            sumOfTierScores[tier] = bucket >= userScore ? bucket - userScore : 0;
            s.accumulatedScore = 0;
        }
        if (ilShareWad > 0) {
            uint256 absIl = uint256(-s.realizedIL);
            sumOfAbsoluteIL = sumOfAbsoluteIL >= absIl ? sumOfAbsoluteIL - absIl : 0;
            s.realizedIL = 0;
        }

        // 5) INTERACTIONS: withdraw from Aave. The router try/catches internally, emits
        //    WithdrawFailed with the reason on failure, never reverts, and returns the actual
        //    filled amount. Any shortfall is recorded to pendingClaim for a later drain.
        uint256 actualPaid = yieldRouter.withdrawFromAave(totalUsdc);
        if (actualPaid < totalUsdc) {
            unchecked {
                pendingClaim[msg.sender] += (totalUsdc - actualPaid);
            }
        }

        // 6) Transfer the available USDC to the claimant (the router withdrew it to this hook).
        if (actualPaid > 0) {
            require(IERC20(usdc).transfer(msg.sender, actualPaid), "HoldfastHookV2: usdc transfer failed");
        }

        // 7) Claimed.
        emit Claimed(tokenId, msg.sender, tierShareWad, ilShareWad, totalUsdc, actualPaid);
    }

    // ---------------------------------------------------------------------
    // Internal: score settle and tier evaluation (shared by notify handlers and claim)
    // ---------------------------------------------------------------------

    /// @dev Lazy tier transition under the dual criterion (score AND tenure). The
    ///      HoldfastNFT mint/upgrade calls are external and can revert
    ///      (PositionAlreadyMinted, TierDowngrade, NotHook, ...), so each is wrapped in
    ///      try/catch; on failure the internal tier is left unchanged and the transition
    ///      is retried on a later notify. This is what keeps notifyModifyLiquidity from
    ///      ever reverting. nft.mint runs with from == address(0), so it does not trigger
    ///      the NFT's settleOnTransfer callback, removing that secondary revert path.
    function _evaluateAndMaybeMint(uint256 tokenId) private {
        PositionStreak storage s = streaks[tokenId];
        if (s.firstActiveBlock == 0) return;

        uint256 blocksActive;
        unchecked {
            blocksActive = block.number - s.firstActiveBlock;
        }
        uint8 nextTier = _evaluateNextTier(s.currentTier, s.accumulatedScore, blocksActive);
        if (nextTier == s.currentTier) return;

        if (s.currentTier == TIER_NONE) {
            // First badge: mint at Bronze, then upgrade in the same call if the position
            // already clears a higher tier. The posm tokenId is the NFT position key.
            try nft.mint(s.owner, bytes32(tokenId)) returns (uint256 badgeId) {
                s.nftTokenId = badgeId;
                s.currentTier = TIER_BRONZE;
                // Bucket maintenance: the position enters its first tier with its full score.
                unchecked {
                    sumOfTierScores[TIER_BRONZE] += s.accumulatedScore;
                }
                if (nextTier > TIER_BRONZE) {
                    try nft.upgradeTier(badgeId, nextTier) {
                        _moveTierBucket(TIER_BRONZE, nextTier, s.accumulatedScore);
                        s.currentTier = nextTier;
                    } catch {}
                }
            } catch {}
        } else {
            try nft.upgradeTier(s.nftTokenId, nextTier) {
                _moveTierBucket(s.currentTier, nextTier, s.accumulatedScore);
                s.currentTier = nextTier;
            } catch {}
        }
    }

    /// @dev Move a position's full accumulatedScore from one tier bucket to another on
    ///      upgrade. The source subtraction is clamped so it can never underflow (preserving
    ///      the never-revert invariant when called from the notify path). Unchecked: pure
    ///      storage arithmetic, no external call.
    function _moveTierBucket(uint8 fromTier, uint8 toTier, uint256 score) private {
        unchecked {
            uint256 b = sumOfTierScores[fromTier];
            sumOfTierScores[fromTier] = b >= score ? b - score : 0;
            sumOfTierScores[toTier] += score;
        }
    }

    /// @dev Lazy Curve-gauge settle: fold the pool accumulator delta into the position's
    ///      score and, for an already-tiered position, into its tier bucket so
    ///      sumOfTierScores stays exact for the notifyBurn decrement. Storage-only and fully
    ///      unchecked: never reverts, so it is safe to call from the never-revert notify
    ///      handlers as well as from the claim flow. This is the single place where an
    ///      incremental score gain updates sumOfTierScores.
    function _settleScore(uint256 tokenId) private {
        PositionStreak storage s = streaks[tokenId];
        unchecked {
            uint256 delta = globalScorePerLiquidity[s.poolId] - s.lastGlobalScoreSnapshot;
            // The tickUpper > tickLower term is defensive: a subscribed position always has a
            // valid range (posm enforces it), so this only excludes an uninitialized streak
            // and guarantees calculateRangeNarrowness cannot revert on the never-revert path.
            if (delta != 0 && s.liquidity != 0 && s.tickUpper > s.tickLower) {
                // blockScore = liquidityShare * volatilityFactor * rangeNarrowness, accumulated.
                // delta already carries volatilityFactor and 1/totalLiquidity from
                // _advanceGlobalScore; liquidity supplies the share numerator; rangeNarrowness
                // is the per-position factor applied here. Two WAD divisions match the
                // WAD-scaled inputs (V1 ScoreAccumulator convention).
                uint256 narrowness = ScoreAccumulator.calculateRangeNarrowness(s.tickLower, s.tickUpper);
                uint256 gained = (uint256(s.liquidity) * delta / WAD) * narrowness / WAD;
                s.accumulatedScore += gained;
                if (s.currentTier != TIER_NONE) {
                    sumOfTierScores[s.currentTier] += gained;
                }
            }
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[s.poolId];
        }
    }

    /// @dev Pure dual-criterion tier ladder: a tier requires both its score threshold and
    ///      its minimum active-block tenure. Returns currentTier when no higher tier is met.
    function _evaluateNextTier(uint8 currentTier, uint256 accumulatedScore, uint256 blocksActive)
        internal
        pure
        returns (uint8)
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
