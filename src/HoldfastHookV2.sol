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

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

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
contract HoldfastHookV2 is BaseHook, ISubscriber {
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

    /// @notice Curve gauge-style pool-level score accumulator, incremented per swap (Step 5+).
    /// @dev Read here as the lazy-update snapshot cursor; written by the swap path later.
    mapping(PoolId => uint256) public globalScorePerLiquidity;

    /// @notice Reward finalized to an owner whose position was re-subscribed under a new owner.
    /// @dev WAD-scaled accrued score parked for later conversion and payout via the claim/
    ///      withdraw path. Writing here is a storage write only, no external call.
    mapping(address => uint256) public pendingClaim;

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
    // STEP 2/3: selector-only stubs; logic lands in a later step.
    // ---------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
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

        unchecked {
            // 1) Settle accrued score with the OLD liquidity, BEFORE applying the change,
            //    so the just-ended period is scored at the liquidity that earned it.
            //    globalScorePerLiquidity is monotonic and snapshot <= global, so delta is
            //    non-negative; unchecked still guards never-revert against any pathology.
            uint256 delta = globalScorePerLiquidity[s.poolId] - s.lastGlobalScoreSnapshot;
            s.accumulatedScore += uint256(s.liquidity) * delta;

            // 2) Advance the lazy-update cursor to the current accumulator value.
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[s.poolId];

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
    function notifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) external onlyByPosm {
        // Step 4: finalize realized IL, freeze streak. Must never revert.
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external onlyByPosm {
        // Step 4: best-effort frozen flag only. Gas-capped; correctness must not depend on it.
    }

    // ---------------------------------------------------------------------
    // Internal: tier evaluation (used by notifyModifyLiquidity)
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
                if (nextTier > TIER_BRONZE) {
                    try nft.upgradeTier(badgeId, nextTier) {
                        s.currentTier = nextTier;
                    } catch {}
                }
            } catch {}
        } else {
            try nft.upgradeTier(s.nftTokenId, nextTier) {
                s.currentTier = nextTier;
            } catch {}
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
