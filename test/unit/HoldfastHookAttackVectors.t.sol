// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Attack-vector tests for HoldfastHook lifecycle paths.
///         Pairs with the DESIGN.md "Attack Vectors and Mitigations" table.
///         Library-level mitigations (e.g. logarithmic rangeNarrowness bound)
///         live alongside their library in ScoreAccumulator.t.sol.
contract HoldfastHookAttackVectorsTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    int256 internal constant LIQ_DELTA = 1e18;
    // Wide range for the seed/baseline LP so swaps stay in-range.
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        vm.roll(1);
    }

    function _addLiqWide(int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: WIDE_LOWER,
                tickUpper: WIDE_UPPER,
                liquidityDelta: delta,
                salt: salt
            }),
            _ownerHookData()
        );
    }

    function _addLiq(int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: delta,
                salt: salt
            }),
            _ownerHookData()
        );
    }

    function _swap(int256 amount, bool zeroForOne) internal {
        uint160 limit = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _streakKey(bytes32 salt) internal view returns (bytes32) {
        return Position.calculatePositionKey(
            address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, salt
        );
    }

    function _accumulatedScore(bytes32 key) internal view returns (uint256 score) {
        (score,,,,,,,,,) = harness.streaks(key);
    }

    function _entrySqrtPriceX96(bytes32 key) internal view returns (uint160 entry) {
        (,,,, entry,,,,,) = harness.streaks(key);
    }

    function _isActive(bytes32 key) internal view returns (bool active) {
        (,,,,,,,, active,) = harness.streaks(key);
    }

    /// @notice Same-block add + swap + remove must accrue zero score.
    /// @dev    DESIGN.md claims a 1-block delay against flash-loan transient
    ///         liquidity. The real implementation relies on the lazy-update
    ///         accumulator: snapshot at add time equals globalScore at the
    ///         same-block remove time, so delta is zero and no score accrues.
    function test_attack_flashLoanSameBlock_accruesNoScore() public {
        _addLiqWide(LIQ_DELTA * 1000, bytes32(uint256(0xBEEF)));
        vm.roll(block.number + 50);
        _swap(-int256(1e16), true);
        vm.roll(block.number + 50);
        _swap(-int256(1e16), false);

        bytes32 attackerKey = _streakKey(bytes32(uint256(0xA11ACC)));
        _addLiq(LIQ_DELTA, bytes32(uint256(0xA11ACC)));
        uint256 scoreAfterAdd = _accumulatedScore(attackerKey);

        _swap(-int256(1e16), true);
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xA11ACC)));
        uint256 scoreAfterClose = _accumulatedScore(attackerKey);

        assertEq(scoreAfterClose, scoreAfterAdd, "same-block cycle accrued score");
    }

    /// @notice Whale split sybil: splitting one position into N (different
    ///         salts, same tick range) must not amplify total accumulated
    ///         score. Linear liquidityShare in _settlePositionScore enforces
    ///         this at the formula level.
    function test_attack_whaleSplitSybil_totalScoreEqualsSingle() public {
        // Single setUp, single pool. Open three positions in the same block
        // with different salts: one "big" (2x liquidity) and two "small"
        // (1x liquidity each). Under linear liquidityShare in the score
        // formula, the big position's score must equal the sum of the two
        // small positions' scores within rounding tolerance, since they all
        // see the same global accumulator delta over the same blocks.

        // Wide co-LP so swaps stay in-range during the whole sequence.
        _addLiqWide(LIQ_DELTA * 1000, bytes32(uint256(0xCAFE)));

        bytes32 bigKey = _streakKey(bytes32(uint256(0xB16)));
        bytes32 smallKeyA = _streakKey(bytes32(uint256(0xA1)));
        bytes32 smallKeyB = _streakKey(bytes32(uint256(0xA2)));

        _addLiq(LIQ_DELTA * 2, bytes32(uint256(0xB16)));
        _addLiq(LIQ_DELTA, bytes32(uint256(0xA1)));
        _addLiq(LIQ_DELTA, bytes32(uint256(0xA2)));

        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 10);
            _swap(-int256(2e16), i % 2 == 0);
        }

        _addLiq(-(LIQ_DELTA * 2), bytes32(uint256(0xB16)));
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xA1)));
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xA2)));

        uint256 bigScore = _accumulatedScore(bigKey);
        uint256 splitTotal =
            _accumulatedScore(smallKeyA) + _accumulatedScore(smallKeyB);

        assertGt(bigScore, 0, "baseline must accrue some score");
        // Linearity: split total must not exceed single big, and must match
        // within tight rounding tolerance.
        assertLe(splitTotal, bigScore, "split exceeds single (sybil amplification)");
        assertGe(splitTotal + 1e6, bigScore, "split severely under-accrues vs single");
    }

    /// @notice IL baseline immutability: re-adding liquidity to an already-active
    ///         position must NOT reset entrySqrtPriceX96. The hook's else branch
    ///         in _afterAddLiquidity only updates the lazy-update cursor, leaving
    ///         the entry snapshot intact. This is the DESIGN.md mitigation against
    ///         "IL baseline manipulation" attacks where an attacker would otherwise
    ///         try to re-anchor the IL baseline after a favorable price move.
    function test_attack_ilBaselineImmutability_reAddDoesNotResetEntry() public {
        bytes32 key = _streakKey(bytes32(uint256(0xBA5E)));
        _addLiqWide(LIQ_DELTA * 1000, bytes32(uint256(0xCAFE)));
        _addLiq(LIQ_DELTA, bytes32(uint256(0xBA5E)));

        uint160 entryBefore = _entrySqrtPriceX96(key);
        assertGt(entryBefore, 0, "entry must be snapshotted on open");

        // Move the pool price via a swap, then re-add liquidity to the same position.
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(block.number + 5);
            _swap(-int256(2e16), i % 2 == 0);
        }

        // Re-add (liquidity increase on the already-active position).
        _addLiq(LIQ_DELTA, bytes32(uint256(0xBA5E)));
        uint160 entryAfter = _entrySqrtPriceX96(key);

        assertEq(entryAfter, entryBefore, "entry must be immutable on re-add");
    }

    /// @notice Open/close farming: rapid open-close cycles by the same LP must
    ///         not amplify accumulatedScore beyond what a single uninterrupted
    ///         position would accrue. Streak freezes on close (does not reset),
    ///         and on re-entry the score persists but does NOT compound across
    ///         cycles without genuine in-range swap activity.
    function test_attack_openCloseFarming_doesNotInflateScore() public {
        _addLiqWide(LIQ_DELTA * 1000, bytes32(uint256(0xCAFE)));

        bytes32 key = _streakKey(bytes32(uint256(0xFA12)));

        // Cycle 1: open, settle (no swaps), close. Score must be zero since
        // there was no in-range swap activity to drive the global accumulator.
        _addLiq(LIQ_DELTA, bytes32(uint256(0xFA12)));
        vm.roll(block.number + 10);
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xFA12)));
        uint256 scoreAfterCycle1 = _accumulatedScore(key);
        assertEq(scoreAfterCycle1, 0, "cycle 1 must not accrue score without swaps");

        // Cycle 2: re-open and immediately close in a later block. Streak
        // resumes (frozenAt cleared), but no swaps occurred so score must
        // remain at the cycle-1 level.
        vm.roll(block.number + 50);
        _addLiq(LIQ_DELTA, bytes32(uint256(0xFA12)));
        vm.roll(block.number + 10);
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xFA12)));
        uint256 scoreAfterCycle2 = _accumulatedScore(key);
        assertEq(scoreAfterCycle2, scoreAfterCycle1, "cycle 2 must not inflate score");

        // Cycle 3: same again. Farming cycles do not produce score.
        vm.roll(block.number + 50);
        _addLiq(LIQ_DELTA, bytes32(uint256(0xFA12)));
        vm.roll(block.number + 10);
        _addLiq(-LIQ_DELTA, bytes32(uint256(0xFA12)));
        uint256 scoreAfterCycle3 = _accumulatedScore(key);
        assertEq(scoreAfterCycle3, scoreAfterCycle2, "cycle 3 must not inflate score");
    }

}
