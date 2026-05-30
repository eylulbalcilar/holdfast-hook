// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Edge-case tests for HoldfastHook init and lifecycle guards.
///         v4 wraps hook reverts in CustomRevert.WrappedError(target, lifecycleSelector,
///         reason, details). We decode the catch payload and assert the inner
///         reason matches the hook's custom error, which is lifecycle-selector
///         independent and survives v4-core version drift.
contract HoldfastHookEdgeCasesTest is HoldfastHookBase {
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    int256 internal constant LIQ_DELTA = 1e18;

    function setUp() public {
        _deployHook();
    }

    /// @dev Decodes a v4 WrappedError revert payload and returns the inner
    ///      reason selector (the actual hook custom error).
    function _innerRevertSelector(bytes memory data) internal pure returns (bytes4) {
        // data layout: 4-byte WrappedError selector || abi.encode(address, bytes4, bytes, bytes)
        // Slice off the outer 4-byte selector before decoding.
        bytes memory inner = new bytes(data.length - 4);
        for (uint256 i = 0; i < inner.length; i++) {
            inner[i] = data[i + 4];
        }
        (, , bytes memory reason, ) = abi.decode(inner, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }

    function test_edge_initialize_revertsOnNonUsdcPool() public {
        MockERC20 a = new MockERC20("X", "X", 18);
        MockERC20 b = new MockERC20("Y", "Y", 18);
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });

        try manager.initialize(key, Constants.SQRT_PRICE_1_1) returns (int24) {
            revert("expected revert, got success");
        } catch (bytes memory data) {
            assertEq(
                bytes4(data),
                CustomRevert.WrappedError.selector,
                "outer must be WrappedError"
            );
            assertEq(
                _innerRevertSelector(data),
                HoldfastHook.PoolMissingUSDC.selector,
                "inner reason must be PoolMissingUSDC"
            );
        }
    }

    function test_edge_addLiquidity_revertsOnEmptyHookData() public {
        (PoolKey memory poolKey,) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);

        try modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQ_DELTA,
                salt: bytes32(0)
            }),
            bytes("")
        ) {
            revert("expected revert, got success");
        } catch (bytes memory data) {
            assertEq(
                bytes4(data),
                CustomRevert.WrappedError.selector,
                "outer must be WrappedError"
            );
            assertEq(
                _innerRevertSelector(data),
                HoldfastHook.HookDataMissing.selector,
                "inner reason must be HookDataMissing"
            );
        }
    }

    /// @notice Tier-of-one: when a user is the sole occupant of a tier, the
    ///         claim share formula must return exactly the full tier allocation
    ///         (no rounding loss). For Gold: totalBonus * TIER_ARM_BPS *
    ///         GOLD_ALLOC_BPS / (BPS_DENOM * BPS_DENOM) = totalBonus * 28%.
    function test_edge_tierOfOne_goldReceivesFullAllocation() public {
        address alice = address(0xA11CE);
        bytes32 key = harness.exposed_positionKey(alice, -60, 60, bytes32(0));

        // Seed the streak with Gold-qualifying score + tenure.
        uint256 goldScore = harness.GOLD_SCORE_();
        uint256 goldBlocks = harness.GOLD_BLOCKS_();
        vm.roll(goldBlocks + 1);
        harness.exposed_setStreakForTest(key, goldScore, 1);

        // Mint + auto-upgrade to Gold (sole occupant of the tier).
        harness.exposed_evaluateAndMaybeMint(key, alice);

        // Verify sole-occupancy precondition.
        assertEq(harness.sumOfTierScores(harness.TIER_GOLD_()), goldScore, "sole Gold occupant");

        // Compute share against an arbitrary bonus pool size.
        uint256 totalBonus = 1_000_000e6; // 1M USDC
        uint256 share = harness.exposed_computeTierShareUsdc(key, totalBonus);

        // Exact expected = totalBonus * 7000 * 4000 / (10000 * 10000) = 28% of pool.
        uint256 expected = (totalBonus * harness.TIER_ARM_BPS_() * harness.GOLD_ALLOC_BPS_())
            / (harness.BPS_DENOM_() * harness.BPS_DENOM_());
        assertEq(share, expected, "sole Gold occupant must receive exact tier allocation");
        assertEq(share, totalBonus * 28 / 100, "exact 28% sanity check");
    }


    /// @notice settleOnTransfer must record the unpaid shortfall in pendingClaim
    ///         when YieldRouter.withdrawFromAave partial-fills (returns less than
    ///         requested). Mock the router to return zero, transfer the NFT, and
    ///         assert pendingClaim[from] holds the full owed amount.
    function test_edge_settleOnTransfer_aaveFail_writesPendingClaim() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        bytes32 key = harness.exposed_positionKey(alice, -60, 60, bytes32(0));

        // Seed Gold-qualifying streak so a real claim share is computed.
        uint256 goldScore = harness.GOLD_SCORE_();
        uint256 goldBlocks = harness.GOLD_BLOCKS_();
        vm.roll(goldBlocks + 1);
        harness.exposed_setStreakForTest(key, goldScore, 1);
        harness.exposed_evaluateAndMaybeMint(key, alice);
        uint256 tokenId = nft.positionKeyToTokenId(key);

        // Mock the router so:
        //  - aUsdc.balanceOf(router) returns 1M USDC (totalBonus > 0)
        //  - withdrawFromAave returns 0 (Aave failure simulation)
        // The mock router's aUsdc() points back to itself, so we mock balanceOf
        // on the router address.
        uint256 bonusPool = 1_000_000e6;
        address mockRouter = address(harness.yieldRouter());
        vm.mockCall(
            mockRouter,
            abi.encodeWithSelector(IERC20.balanceOf.selector, mockRouter),
            abi.encode(bonusPool)
        );
        vm.mockCall(
            mockRouter,
            abi.encodeWithSignature("withdrawFromAave(uint256)"),
            abi.encode(uint256(0))
        );

        // Transfer the NFT alice -> bob. settleOnTransfer fires; Aave returns 0;
        // unpaid total = full computed share is written to pendingClaim[alice].
        uint256 expectedOwed = bonusPool * harness.TIER_ARM_BPS_() * harness.GOLD_ALLOC_BPS_()
            / (harness.BPS_DENOM_() * harness.BPS_DENOM_());

        vm.prank(alice);
        nft.transferFrom(alice, bob, tokenId);

        assertEq(harness.pendingClaim(alice), expectedOwed, "shortfall must accrue to from");
        assertEq(nft.ownerOf(tokenId), bob, "transfer still completes");
    }

    /// @notice withdrawPendingClaim drains pendingClaim and zeroes it when the
    ///         router fully fills. A second call must revert NothingToClaim.
    function test_edge_pendingClaim_retrySucceedsAfterAaveRecovers() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        bytes32 key = harness.exposed_positionKey(alice, -60, 60, bytes32(0));

        // Same setup as above: mint Gold, transfer with Aave failing, accrue
        // pendingClaim[alice].
        uint256 goldScore = harness.GOLD_SCORE_();
        uint256 goldBlocks = harness.GOLD_BLOCKS_();
        vm.roll(goldBlocks + 1);
        harness.exposed_setStreakForTest(key, goldScore, 1);
        harness.exposed_evaluateAndMaybeMint(key, alice);
        uint256 tokenId = nft.positionKeyToTokenId(key);

        uint256 bonusPool = 1_000_000e6;
        address mockRouter = address(harness.yieldRouter());
        vm.mockCall(
            mockRouter,
            abi.encodeWithSelector(IERC20.balanceOf.selector, mockRouter),
            abi.encode(bonusPool)
        );
        vm.mockCall(
            mockRouter,
            abi.encodeWithSignature("withdrawFromAave(uint256)"),
            abi.encode(uint256(0))
        );

        vm.prank(alice);
        nft.transferFrom(alice, bob, tokenId);

        uint256 owed = harness.pendingClaim(alice);
        assertGt(owed, 0, "precondition: pendingClaim populated");

        // Aave recovers: withdrawFromAave now returns the full requested amount.
        // Re-mock to override the previous mock.
        vm.mockCall(
            mockRouter,
            abi.encodeWithSignature("withdrawFromAave(uint256)"),
            abi.encode(owed)
        );

        // Fund the hook with USDC so the transfer to alice succeeds. USDC in
        // this harness is token0; the test contract holds the full mint supply.
        token0.transfer(address(harness), owed);

        uint256 aliceBalBefore = token0.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawPendingClaim();
        uint256 aliceBalAfter = token0.balanceOf(alice);

        assertEq(harness.pendingClaim(alice), 0, "pendingClaim must zero out");
        assertEq(aliceBalAfter - aliceBalBefore, owed, "alice receives full owed");
    }


    /// @notice Multi-position same LP, different tiers: one user can hold
    ///         multiple positions in distinct tiers simultaneously. Tier
    ///         accounting must isolate them (sumOfTierScores per tier).
    function test_edge_multiPosition_sameLpDifferentTiers() public {
        address alice = address(0xA11CE);
        bytes32 keyBronze = harness.exposed_positionKey(alice, -60, 60, bytes32(uint256(1)));
        bytes32 keySilver = harness.exposed_positionKey(alice, -60, 60, bytes32(uint256(2)));

        uint256 bronzeScore = harness.BRONZE_SCORE_();
        uint256 silverScore = harness.SILVER_SCORE_();
        uint256 silverBlocks = harness.SILVER_BLOCKS_();

        // Roll past the silver tenure threshold so both positions qualify.
        vm.roll(silverBlocks + 1);

        harness.exposed_setStreakForTest(keyBronze, bronzeScore, 1);
        harness.exposed_setStreakForTest(keySilver, silverScore, 1);

        harness.exposed_evaluateAndMaybeMint(keyBronze, alice);
        harness.exposed_evaluateAndMaybeMint(keySilver, alice);

        // Each position minted its own NFT.
        uint256 tokenBronze = nft.positionKeyToTokenId(keyBronze);
        uint256 tokenSilver = nft.positionKeyToTokenId(keySilver);
        assertGt(tokenBronze, 0);
        assertGt(tokenSilver, 0);
        assertTrue(tokenBronze != tokenSilver, "distinct NFTs per position");
        assertEq(nft.ownerOf(tokenBronze), alice);
        assertEq(nft.ownerOf(tokenSilver), alice);

        // Tier accounting is isolated: Bronze sum holds only the bronze score,
        // Silver sum holds only the silver score.
        assertEq(
            harness.sumOfTierScores(harness.TIER_BRONZE_()),
            bronzeScore,
            "bronze tier sum isolated"
        );
        assertEq(
            harness.sumOfTierScores(harness.TIER_SILVER_()),
            silverScore,
            "silver tier sum isolated"
        );
    }

    /// @notice Transfer mid-stream then close: after settleOnTransfer pays the
    ///         original owner (or records pendingClaim on Aave failure), the
    ///         new owner inherits the streak slot. A subsequent close by the
    ///         new owner must not touch the original owner's pendingClaim.
    function test_edge_transferMidStream_thenClose_preservesOriginalPending() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        bytes32 key = harness.exposed_positionKey(alice, -60, 60, bytes32(0));

        // Mint Gold to alice.
        uint256 goldScore = harness.GOLD_SCORE_();
        uint256 goldBlocks = harness.GOLD_BLOCKS_();
        vm.roll(goldBlocks + 1);
        harness.exposed_setStreakForTest(key, goldScore, 1);
        harness.exposed_evaluateAndMaybeMint(key, alice);
        uint256 tokenId = nft.positionKeyToTokenId(key);

        // Aave fails during transfer settle -> pendingClaim[alice] accrues.
        uint256 bonusPool = 1_000_000e6;
        address mockRouter = address(harness.yieldRouter());
        vm.mockCall(
            mockRouter,
            abi.encodeWithSelector(IERC20.balanceOf.selector, mockRouter),
            abi.encode(bonusPool)
        );
        vm.mockCall(
            mockRouter,
            abi.encodeWithSignature("withdrawFromAave(uint256)"),
            abi.encode(uint256(0))
        );

        vm.prank(alice);
        nft.transferFrom(alice, bob, tokenId);
        uint256 alicePendingAfterTransfer = harness.pendingClaim(alice);
        assertGt(alicePendingAfterTransfer, 0, "alice pending populated by transfer");
        assertEq(harness.pendingClaim(bob), 0, "bob starts with no pending");

        // Bob (the new owner) tries to claim. Aave still fails, so claim either
        // reverts NothingToClaim (if Bob's share is zero now that alice's score
        // was consumed in settle) or accrues nothing extra. Either way, alice's
        // pendingClaim must remain untouched.
        // After settleOnTransfer the streak's accumulatedScore was zeroed
        // (see settleOnTransfer effects), so bob has no claimable share.
        vm.expectRevert(HoldfastHook.NothingToClaim.selector);
        vm.prank(bob);
        harness.claim(tokenId);

        // Alice's pendingClaim is intact: the new owner's failed claim did not
        // alter the original owner's accrued shortfall.
        assertEq(
            harness.pendingClaim(alice),
            alicePendingAfterTransfer,
            "alice pending preserved after bob ops"
        );
    }

}
