// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract HoldfastHookRemoveLiquidityTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;

    uint256 internal constant BRONZE_SCORE = 10 * 1e18;
    uint256 internal constant BRONZE_BLOCKS = 1_000;
    uint8 internal constant TIER_BRONZE = 1;

    event RealizedILComputed(bytes32 indexed positionKey, int256 il, uint160 currentSqrtPriceX96);

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        vm.roll(1);
    }

    function _openPosition() internal returns (bytes32 positionKey) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQ_DELTA,
                salt: bytes32(0)
            }),
            _ownerHookData()
        );
        positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _removePartial(int256 negDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: negDelta,
                salt: bytes32(0)
            }),
            _ownerHookData()
        );
    }

    function _readRealizedIL(bytes32 key) internal view returns (int256 il) {
        il = harness.getStreak(key).realizedIL;
    }

    function _readTier(bytes32 key) internal view returns (uint8 tier) {
        tier = harness.getStreak(key).currentTier;
    }

    // -----------------------------------------------------------------
    // Realized IL compute
    // -----------------------------------------------------------------

    /// @dev No price change between open and remove: realized IL must be exactly zero.
    function test_remove_noPriceChange_realizedILZero() public {
        bytes32 positionKey = _openPosition();

        // Remove half the liquidity. Price unchanged, so IL = 0.
        _removePartial(-LIQ_DELTA / 2);

        int256 il = _readRealizedIL(positionKey);
        assertEq(il, int256(0), "IL must be zero when price has not moved");
    }

    /// @dev Price moves: IL must be strictly negative (impermanent loss is a loss).
    function test_remove_priceMoved_realizedILNegative() public {
        bytes32 positionKey = _openPosition();

        // Trigger a swap to move the pool price.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e16), sqrtPriceLimitX96: uint160(4295128740)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        _removePartial(-LIQ_DELTA / 2);

        int256 il = _readRealizedIL(positionKey);
        assertLt(il, int256(0), "IL must be negative after a price move");
    }

    function test_remove_emitsRealizedILComputed() public {
        bytes32 positionKey = _openPosition();

        // We do not pre-compute the IL value to assert exactly; instead, assert that
        // the event topic indexes match and the data fields are populated.
        vm.expectEmit(true, false, false, false, address(harness));
        emit RealizedILComputed(positionKey, int256(0), uint160(0));

        _removePartial(-LIQ_DELTA / 2);
    }

    // -----------------------------------------------------------------
    // Unknown position: no-op
    // -----------------------------------------------------------------

    /// @dev Removing liquidity on a position the hook never saw open must be a
    ///      safe no-op. The router still calls our hook, but nothing should write.
    function test_remove_unknownPosition_noOp() public {
        // Open one position so router has nonzero state.
        _openPosition();

        // Now remove against a tick range the hook never tracked. Router accepts the
        // call only if Uniswap also tracks the position; since we never opened this
        // range, Uniswap reverts. Cover the hook-level branch instead by removing
        // a salt-mismatched position: salt(1) was never opened.
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -LIQ_DELTA / 2,
                salt: bytes32(uint256(1))
            }),
            _ownerHookData()
        );

        // The unopened position key should have IL == 0 (default).
        bytes32 unknownKey = Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        assertEq(_readRealizedIL(unknownKey), int256(0));
    }

    // -----------------------------------------------------------------
    // Lazy tier evaluation at remove time
    // -----------------------------------------------------------------

    /// @dev Score and tenure satisfied; remove triggers lazy eval -> NFT minted Bronze.
    function test_remove_triggersLazyTierMint() public {
        bytes32 positionKey = _openPosition();

        // Set score to Bronze threshold and roll past tenure window.
        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);

        // No NFT yet.
        assertEq(nft.nextTokenId(), 1, "no NFT before remove");

        _removePartial(-LIQ_DELTA / 2);

        assertEq(_readTier(positionKey), TIER_BRONZE, "remove should trigger Bronze mint");
        assertEq(nft.nextTokenId(), 2, "one NFT minted");
    }


    // -----------------------------------------------------------------
    // Full vs partial close
    // -----------------------------------------------------------------

    function _readActive(bytes32 key) internal view returns (bool active) {
        active = harness.getStreak(key).isActive;
    }

    function _readFrozenAt(bytes32 key) internal view returns (uint128 frozenAt) {
        frozenAt = harness.getStreak(key).frozenAt;
    }

    function _readScore(bytes32 key) internal view returns (uint256 score) {
        score = harness.getStreak(key).accumulatedScore;
    }

    function _readEntry(bytes32 key) internal view returns (uint160 entry) {
        entry = harness.getStreak(key).entrySqrtPriceX96;
    }

    function _readFirstActiveBlock(bytes32 key) internal view returns (uint256 fab) {
        fab = harness.getStreak(key).firstActiveBlock;
    }

    function _readLastUpdateBlock(bytes32 key) internal view returns (uint256 lub) {
        lub = harness.getStreak(key).lastUpdateBlock;
    }

    event PositionClosed(
        bytes32 indexed positionKey,
        address indexed owner,
        uint256 accumulatedScore,
        int256 realizedIL,
        uint128 frozenAt
    );

    /// @dev Full closure freezes the streak; tier and score preserved (no downgrade).
    function test_remove_fullClose_freezesStreak() public {
        bytes32 positionKey = _openPosition();
        // Pre-seed score to model swap accrual.
        harness.setStreakScore(positionKey, 50 * 1e18);

        vm.roll(block.number + 500);
        _removePartial(-LIQ_DELTA); // full liquidity withdrawal

        assertFalse(_readActive(positionKey), "isActive must be false after full close");
        assertEq(_readFrozenAt(positionKey), uint128(block.number), "frozenAt must be set to current block");
        assertEq(_readScore(positionKey), 50 * 1e18, "accumulatedScore must persist");
    }

    function test_remove_fullClose_emitsPositionClosed() public {
        bytes32 positionKey = _openPosition();
        harness.setStreakScore(positionKey, 50 * 1e18);
        vm.roll(block.number + 500);

        vm.expectEmit(true, true, false, false, address(harness));
        emit PositionClosed(positionKey, address(modifyLiquidityRouter), 0, 0, 0);

        _removePartial(-LIQ_DELTA);
    }

    /// @dev Bronze-tier NFT survives full closure: tier does not downgrade.
    function test_remove_fullClose_tierPersists() public {
        bytes32 positionKey = _openPosition();
        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);

        // First remove triggers Bronze mint via beforeRemoveLiquidity lazy eval.
        _removePartial(-LIQ_DELTA / 2);
        assertEq(_readTier(positionKey), TIER_BRONZE);

        // Now close fully. Tier must stay at Bronze, streak frozen.
        _removePartial(-LIQ_DELTA / 2);
        assertFalse(_readActive(positionKey));
        assertEq(_readTier(positionKey), TIER_BRONZE, "tier must persist through full close");
    }

    /// @dev Partial closure does not freeze: streak remains active, only the
    ///      lazy-update cursor advances.
    function test_remove_partialClose_keepsStreakActive() public {
        bytes32 positionKey = _openPosition();
        uint256 fabBefore = _readFirstActiveBlock(positionKey);

        vm.roll(block.number + 500);
        _removePartial(-LIQ_DELTA / 4);

        assertTrue(_readActive(positionKey), "isActive must remain true on partial close");
        assertEq(_readFrozenAt(positionKey), 0, "frozenAt must remain zero");
        assertEq(_readFirstActiveBlock(positionKey), fabBefore, "firstActiveBlock immutable");
        assertEq(_readLastUpdateBlock(positionKey), block.number, "lastUpdateBlock advances to current");
    }

    // -----------------------------------------------------------------
    // Re-entry after full close
    // -----------------------------------------------------------------

    /// @dev Re-opening a previously frozen position at the same tick range
    ///      resumes the streak: accumulatedScore and currentTier are preserved
    ///      while entrySqrtPriceX96 and firstActiveBlock are reset to current.
    function test_remove_reentry_resumesStreak() public {
        bytes32 positionKey = _openPosition();

        // Mint Bronze and freeze.
        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);
        _removePartial(-LIQ_DELTA); // full close
        assertFalse(_readActive(positionKey));
        assertEq(_readTier(positionKey), TIER_BRONZE);
        uint256 scoreAtFreeze = _readScore(positionKey);
        uint160 entryAtFreeze = _readEntry(positionKey);

        // Move forward a few blocks, then re-open the same position.
        vm.roll(block.number + 100);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQ_DELTA,
                salt: bytes32(0)
            }),
            _ownerHookData()
        );

        // Score and tier preserved.
        assertEq(_readScore(positionKey), scoreAtFreeze, "score must persist across re-entry");
        assertEq(_readTier(positionKey), TIER_BRONZE, "tier must persist across re-entry");

        // Active again, frozen flag cleared.
        assertTrue(_readActive(positionKey), "isActive must be true after re-entry");
        assertEq(_readFrozenAt(positionKey), 0, "frozenAt must reset to zero");

        // entrySqrtPriceX96 and firstActiveBlock reset to current.
        // Entry value may equal old if pool price did not move; assert the field
        // was rewritten by checking firstActiveBlock equals current block.
        assertEq(_readFirstActiveBlock(positionKey), block.number, "firstActiveBlock reset to current block");
        // Sanity: entry remains a valid (non-zero) sqrt price; under no swap it
        // equals entryAtFreeze, which is fine.
        assertGt(_readEntry(positionKey), 0);
        entryAtFreeze; // silence unused warning
    }
}
