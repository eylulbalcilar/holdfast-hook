// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

import {HoldfastHookV2} from "../../src/HoldfastHookV2.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {FundedMockYieldRouter} from "../mocks/FundedMockYieldRouter.sol";

/// @dev Minimal ERC-721 read/transfer interface; IPositionManager does not expose these directly.
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Minimal view of the canonical PositionManager subscriber mapping (INotifier).
interface IPosmSubscriberView {
    function subscriber(uint256 tokenId) external view returns (address);
}

/// @title SubscriberNativeAccrualTest
/// @notice V2 subscriber-native accrual test. Exercises the intended end-to-end flow against
///         HoldfastHookV2: an LP mints a position through the canonical Uniswap
///         PositionManager, subscribes it to the hook via posm.subscribe, swaps churn the
///         pool (advancing the pool-level Curve-gauge accumulator in _afterSwap), blocks
///         advance past the Bronze tenure floor, and a tiny posm liquidity modify fires
///         notifyModifyLiquidity which settles the accrued score. The per-position score is
///         then asserted to be non-zero, keyed by the canonical ERC-721 tokenId.
///
///         This was committed RED against V1 (which has no ISubscriber handler, so subscribe
///         reverted). V2 implements the subscriber surface and the swap-side accumulator,
///         turning it GREEN through the natural flow with no test-only backdoor.
contract SubscriberNativeAccrualTest is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    IAllowanceTransfer internal permit2;
    IPositionManager internal posm;

    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    HoldfastHookV2 internal hook;
    HoldfastNFT internal nft;
    FundedMockYieldRouter internal mockRouter;

    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal lp;
    address internal lp2;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant LIQ = 1e18;

    // Mirrors HoldfastHookV2.BRONZE_BLOCKS (1_000): minimum active tenure for Bronze.
    uint256 internal constant BRONZE_BLOCKS = 1_000;

    // Bonus pool seeded into the funded yield-router mock so the payout path is observable.
    uint256 internal constant BONUS_POOL = 1e24;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        // Two 18-decimal mock tokens, sorted. token0 is designated USDC for the hook,
        // matching the harness convention; the hook requires USDC as a pool currency.
        MockERC20 a = new MockERC20("USDC", "USDC", 18);
        MockERC20 b = new MockERC20("WETH", "WETH", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Fund + approve the test contract (the swapper) on the swap router.
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        nft = new HoldfastNFT(address(this));
        // Funded yield-router mock: holds USDC (token0) so the claim/withdraw payout is observable.
        mockRouter = new FundedMockYieldRouter(address(token0));
        token0.mint(address(mockRouter), BONUS_POOL);

        // Deploy the canonical Uniswap v4 PositionManager locally (same contract code as Base
        // Sepolia 0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80). The hook takes its address at
        // construction (it is the sole authorized ISubscriber caller via onlyByPosm).
        posm = _deployPosm(address(manager), address(permit2));

        // Mine + deploy HoldfastHookV2 at a permission-valid CREATE2 address. V2 permission
        // set: afterInitialize, beforeSwap, afterSwap, afterSwapReturnDelta. usdc = token0.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory cargs = abi.encode(
            IPoolManager(address(manager)), posm, nft, YieldRouter(address(mockRouter)), address(token0)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HoldfastHookV2).creationCode, cargs);
        hook = new HoldfastHookV2{salt: salt}(
            IPoolManager(address(manager)), posm, nft, YieldRouter(address(mockRouter)), address(token0)
        );
        require(address(hook) == hookAddr, "hook mined address mismatch");
        nft.setHook(address(hook));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Two LPs, each funded and wired through the two-step Permit2 -> PositionManager approval.
        lp = makeAddr("lp");
        lp2 = makeAddr("lp2");
        _fundAndApproveLp(lp);
        _fundAndApproveLp(lp2);

        vm.roll(1);
    }

    function _fundAndApproveLp(address who) internal {
        token0.mint(who, 1e24);
        token1.mint(who, 1e24);
        vm.startPrank(who);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Deploys the canonical PositionManager. tokenDescriptor and weth9 are address(0):
    ///      the test never resolves tokenURI or wraps native.
    function _deployPosm(address poolManager_, address permit2_) internal returns (IPositionManager) {
        PositionManager pm = new PositionManager(
            IPoolManager(poolManager_),
            IAllowanceTransfer(permit2_),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        return IPositionManager(address(pm));
    }

    /// @dev Mints a position through the canonical PositionManager (MINT_POSITION + SETTLE_PAIR).
    function _mintPosition(address owner_, uint256 liquidity) internal {
        bytes memory hookData = abi.encode(owner_);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(type(uint128).max),
            uint128(type(uint128).max),
            owner_,
            hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        bytes memory unlockData = abi.encode(actions, params);
        vm.prank(owner_);
        posm.modifyLiquidities(unlockData, block.timestamp + 1);
    }

    function _swap(int256 amount, bool zeroForOne) internal {
        uint160 limit =
            zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _churn() internal {
        for (uint256 i = 0; i < 6; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
    }

    /// @dev GREEN target. The subscriber-native flow accrues per-position score keyed by the
    ///      canonical PositionManager tokenId.
    function test_subscriberNativeAccrual_scoreKeyedByTokenId() public {
        // 1. LP mints a canonical PositionManager position.
        uint256 tokenId = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        assertEq(IERC721Minimal(address(posm)).ownerOf(tokenId), lp, "LP must own the minted position NFT");

        // 2. LP subscribes the position to the Holdfast hook (the V2 entrypoint).
        vm.prank(lp);
        posm.subscribe(tokenId, address(hook), "");

        // 3. Swap churn plus block advancement past the Bronze tenure floor drive the
        //    pool-level Curve-gauge accumulator (globalScorePerLiquidity) in _afterSwap.
        _churn();
        vm.roll(block.number + BRONZE_BLOCKS + 1);
        _swap(-int256(2e16), true);

        // 4. Accrual is lazy: it folds into the position only on a notify. A tiny posm
        //    liquidity increase fires notifyModifyLiquidity -> _settleScore. This is the
        //    natural V2 settle trigger (the subscriber notification path itself), not a
        //    test-only backdoor.
        _increaseLiquidity(lp, tokenId, 1e12);

        // 5. Score must have accrued, keyed by the canonical tokenId (V2 getStreak(uint256)).
        assertGt(
            hook.getStreak(tokenId).accumulatedScore,
            0,
            "score must accrue keyed by tokenId after subscribe + settle"
        );
    }

    /// @dev Triggers a settle through the natural subscriber path: a posm liquidity increase
    ///      notifies the hook via notifyModifyLiquidity. Finalized with CLOSE_CURRENCY per
    ///      token (auto settles or takes by delta sign), which is robust whether the position
    ///      is single- or double-sided after the swaps moved the price.
    function _increaseLiquidity(address owner_, uint256 tokenId, uint256 liquidity) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(tokenId, liquidity, uint128(type(uint128).max), uint128(type(uint128).max), bytes(""));
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        bytes memory unlockData = abi.encode(actions, params);
        vm.prank(owner_);
        posm.modifyLiquidities(unlockData, block.timestamp + 1);
    }

    function _subscribeAs(address owner_, uint256 tokenId) internal {
        vm.prank(owner_);
        posm.subscribe(tokenId, address(hook), "");
    }

    /// @dev Transfers the posm position ERC-721. PositionManager.transferFrom auto-unsubscribes
    ///      a subscribed position (its override calls _unsubscribe), so no manual unsubscribe.
    function _transferPosition(address from, address to, uint256 tokenId) internal {
        vm.prank(from);
        IERC721Minimal(address(posm)).transferFrom(from, to, tokenId);
    }

    /// @notice Anti-theft core (V2 thesis). A transferred position auto-unsubscribes; re-subscribing
    ///         under a new owner finalizes the prior owner's accrued score into their tier-indexed
    ///         pending entitlement and resets the streak for the new owner. The new owner cannot
    ///         reach the prior owner's finalized balance.
    function test_ownerChangeViaTransfer_antiTheft() public {
        // LP1 mints, subscribes, accrues over the churn, and settles via the subscriber path.
        uint256 tokenId = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        _subscribeAs(lp, tokenId);
        uint160 entryAtMint = hook.getStreak(tokenId).entrySqrtPriceX96;

        _churn();
        vm.roll(block.number + BRONZE_BLOCKS + 1);
        _swap(-int256(2e16), true);
        _increaseLiquidity(lp, tokenId, 1e12);

        uint256 scoreBeforeTransfer = hook.getStreak(tokenId).accumulatedScore;
        uint8 tierBefore = hook.getStreak(tokenId).currentTier;
        assertGt(scoreBeforeTransfer, 0, "LP1 must have accrued score before transfer");
        assertGt(tierBefore, 0, "LP1 must have reached a tier before transfer");
        assertEq(hook.getStreak(tokenId).owner, lp, "owner is LP1 before transfer");

        // LP1 transfers the posm position NFT to LP2. PositionManager auto-unsubscribes.
        _transferPosition(lp, lp2, tokenId);
        assertEq(IERC721Minimal(address(posm)).ownerOf(tokenId), lp2, "LP2 now owns the position");
        assertEq(
            IPosmSubscriberView(address(posm)).subscriber(tokenId),
            address(0),
            "transfer must auto-unsubscribe the position"
        );

        // LP2 re-subscribes; notifySubscribe takes the owner-change branch.
        _subscribeAs(lp2, tokenId);

        // Prior owner's score finalized into LP1's tier-indexed pending entitlement; streak reset.
        assertEq(
            hook.pendingScoreByTier(lp, tierBefore),
            scoreBeforeTransfer,
            "LP1's accrued score finalized into pendingScoreByTier[LP1][tier]"
        );
        assertEq(hook.getStreak(tokenId).owner, lp2, "streak owner reset to LP2");
        assertEq(hook.getStreak(tokenId).accumulatedScore, 0, "streak score reset for LP2");
        assertEq(hook.getStreak(tokenId).currentTier, 0, "streak tier reset for LP2");
        assertEq(hook.getStreak(tokenId).nftTokenId, 0, "streak badge ref reset for LP2");
        assertTrue(
            hook.getStreak(tokenId).entrySqrtPriceX96 != entryAtMint,
            "fresh IL baseline re-read at re-subscribe (price moved since mint)"
        );

        // Anti-theft: LP2 has no pending balance of its own, and LP2 claiming cannot drain
        // LP1's pending. pendingScoreByTier is keyed by address, so LP1's amount is segregated.
        assertEq(hook.pendingScoreByTier(lp2, tierBefore), 0, "LP2 has no pending balance");
        vm.prank(lp2);
        hook.claim(tokenId);
        assertEq(
            hook.pendingScoreByTier(lp, tierBefore), scoreBeforeTransfer, "LP2 claim cannot drain LP1's pending"
        );
        assertEq(hook.pendingScoreByTier(lp2, tierBefore), 0, "LP2 still has no pending after claiming");
    }

    /// @notice Multi-LP isolation. Two positions in the same pool accrue independently, each keyed by
    ///         its own tokenId; settling one does not bleed into the other.
    function test_multiLpIsolation() public {
        uint256 tokenId1 = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        _subscribeAs(lp, tokenId1);

        uint256 tokenId2 = posm.nextTokenId();
        _mintPosition(lp2, LIQ);
        _subscribeAs(lp2, tokenId2);
        assertTrue(tokenId1 != tokenId2, "distinct tokenIds");

        // Shared swap churn drives the pool-level accumulator for both positions.
        _churn();
        vm.roll(block.number + BRONZE_BLOCKS + 1);
        _swap(-int256(2e16), true);

        // Settle LP1 only. Its score moves; LP2's stays unsettled (no bleed).
        _increaseLiquidity(lp, tokenId1, 1e12);
        uint256 score1 = hook.getStreak(tokenId1).accumulatedScore;
        assertGt(score1, 0, "LP1 accrued under tokenId1");
        assertEq(hook.getStreak(tokenId2).accumulatedScore, 0, "settling LP1 must not bleed into LP2");

        // Settle LP2. Its score moves; LP1's stays exactly where it was.
        _increaseLiquidity(lp2, tokenId2, 1e12);
        assertGt(hook.getStreak(tokenId2).accumulatedScore, 0, "LP2 accrued under tokenId2");
        assertEq(hook.getStreak(tokenId1).accumulatedScore, score1, "LP2 settle must not change LP1's score");
    }

    /// @dev Drive a subscribed position through swap churn + block advancement past the Bronze
    ///      tenure floor + a settle, so it reaches at least Bronze (score and tenure).
    function _accrueAndSettleToTier(address owner_, uint256 tokenId) internal {
        _churn();
        vm.roll(block.number + BRONZE_BLOCKS + 1);
        _swap(-int256(2e16), true);
        _increaseLiquidity(owner_, tokenId, 1e12);
    }

    /// @notice End-to-end owner change proving the four anti-theft fixes together: a transferred
    ///         position parks the prior owner's tiered score, the new owner is no longer
    ///         tier-blocked (per-subscription-epoch badge key), the parked entitlement is
    ///         drainable for real USDC against the live denominator, and it is segregated from
    ///         the new owner.
    function test_ownerChangeEndToEnd_allFixes() public {
        // 1. LP1 mints, subscribes, accrues, settles, reaches a tier with a badge.
        uint256 tokenId = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        _subscribeAs(lp, tokenId);
        _accrueAndSettleToTier(lp, tokenId);

        uint8 tier = hook.getStreak(tokenId).currentTier;
        uint256 s1 = hook.getStreak(tokenId).accumulatedScore;
        uint256 badge1 = hook.getStreak(tokenId).nftTokenId;
        assertGe(tier, 1, "LP1 reached at least Bronze");
        assertGt(s1, 0, "LP1 has score");
        assertTrue(badge1 != 0, "LP1 badge minted");
        assertEq(nft.ownerOf(badge1), lp, "LP1 owns its badge");

        // 2. LP1 transfers the position to LP2 (real transfer, auto-unsubscribe). The finalize is
        //    deferred to the re-subscribe (notifySubscribe is the authoritative reconciliation
        //    point); transfer alone only fires the best-effort notifyUnsubscribe, so nothing is
        //    parked yet and the streak still belongs to LP1 at this instant.
        _transferPosition(lp, lp2, tokenId);
        assertEq(hook.pendingScoreByTier(lp, tier), 0, "parking deferred until re-subscribe");
        assertEq(hook.getStreak(tokenId).owner, lp, "streak still owned by LP1 until re-subscribe");

        // 3. LP2 re-subscribes: the owner-change finalize parks LP1's tiered score and resets the
        //    streak for LP2.
        _subscribeAs(lp2, tokenId);
        assertEq(hook.pendingScoreByTier(lp, tier), s1, "LP1 score parked in pending");
        assertEq(hook.getStreak(tokenId).currentTier, 0, "streak tier reset");
        assertEq(hook.getStreak(tokenId).nftTokenId, 0, "streak badge ref reset");
        assertEq(hook.getStreak(tokenId).owner, lp2, "streak owner is LP2");

        // 4. LP2 accrues, settles, and NOW reaches a tier with a NEW badge (proves the new owner
        //    is not permanently tier-blocked).
        _accrueAndSettleToTier(lp2, tokenId);

        uint256 badge2 = hook.getStreak(tokenId).nftTokenId;
        assertGe(hook.getStreak(tokenId).currentTier, 1, "LP2 reached at least Bronze after transfer");
        assertTrue(badge2 != 0, "LP2 badge minted");
        assertTrue(badge2 != badge1, "LP2 badge id differs from LP1 badge");
        assertEq(nft.ownerOf(badge2), lp2, "LP2 owns its badge");

        // 5. LP1 drains the parked entitlement for real USDC against the live denominator.
        uint256 pendingS1 = hook.pendingScoreByTier(lp, tier);
        assertEq(pendingS1, s1, "LP1 pending still parked before withdraw");
        uint256 sumBefore = hook.sumOfTierScores(tier);
        uint256 lp1BalBefore = token0.balanceOf(lp);

        vm.prank(lp);
        hook.withdrawPendingClaim();

        assertGt(token0.balanceOf(lp), lp1BalBefore, "LP1 received USDC from the parked entitlement");
        assertEq(hook.pendingScoreByTier(lp, tier), 0, "LP1 pending zeroed after withdraw");
        assertEq(hook.sumOfTierScores(tier), sumBefore - pendingS1, "denominator decremented by LP1 score");

        // 6. LP2 draining pending gets nothing of LP1's (segregation by address).
        uint256 lp2BalBefore = token0.balanceOf(lp2);
        vm.prank(lp2);
        hook.withdrawPendingClaim();
        assertEq(token0.balanceOf(lp2), lp2BalBefore, "LP2 gets nothing from pending");
        assertEq(hook.pendingScoreByTier(lp, tier), 0, "LP1 pending remains zero after LP2 attempt");
    }

    /// @notice Round-trip transfer A->B->A. A returning owner reaches a tier again and receives a
    ///         FRESH badge, proving the per-subscription-epoch key handles round-trips (the hole a
    ///         per-owner key would leave: the returning owner re-colliding with their old badge).
    function test_roundTripTransfer_freshBadgeOnReturn() public {
        uint256 tokenId = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        _subscribeAs(lp, tokenId);
        _accrueAndSettleToTier(lp, tokenId);
        uint256 badge1 = hook.getStreak(tokenId).nftTokenId;
        assertTrue(badge1 != 0, "LP1 first badge minted");

        // A -> B
        _transferPosition(lp, lp2, tokenId);
        _subscribeAs(lp2, tokenId);
        _accrueAndSettleToTier(lp2, tokenId);
        uint256 badge2 = hook.getStreak(tokenId).nftTokenId;
        assertTrue(badge2 != 0 && badge2 != badge1, "LP2 fresh badge after first transfer");

        // B -> A (round-trip back to the original owner)
        _transferPosition(lp2, lp, tokenId);
        _subscribeAs(lp, tokenId);
        _accrueAndSettleToTier(lp, tokenId);
        uint256 badge3 = hook.getStreak(tokenId).nftTokenId;

        assertGe(hook.getStreak(tokenId).currentTier, 1, "returning LP1 reaches a tier again");
        assertTrue(badge3 != 0, "returning LP1 gets a badge");
        assertTrue(badge3 != badge1 && badge3 != badge2, "returning LP1's badge is fresh, not a re-collision");
        assertEq(nft.ownerOf(badge3), lp, "returning LP1 owns the fresh badge");
    }
}
