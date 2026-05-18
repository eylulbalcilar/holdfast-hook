// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoreAccumulator} from "../../src/libraries/ScoreAccumulator.sol";

contract ScoreAccumulatorTest is Test {
    uint256 constant WAD = 1e18;
    uint160 constant ENTRY_SQRT = 79228162514264337593543950336; // sqrt(1) * 2^96

    // ---------- calculateBlockScore ----------

    function test_blockScore_zeroLiquidity() public pure {
        uint256 score = ScoreAccumulator.calculateBlockScore(0, WAD, WAD);
        assertEq(score, 0);
    }

    function test_blockScore_zeroVolatility() public pure {
        uint256 score = ScoreAccumulator.calculateBlockScore(WAD, 0, WAD);
        assertEq(score, 0);
    }

    function test_blockScore_zeroNarrowness() public pure {
        uint256 score = ScoreAccumulator.calculateBlockScore(WAD, WAD, 0);
        assertEq(score, 0);
    }

    function test_blockScore_allMax() public pure {
        uint256 score = ScoreAccumulator.calculateBlockScore(WAD, WAD, WAD);
        assertEq(score, WAD);
    }

    function test_blockScore_halfLiquidity() public pure {
        uint256 score = ScoreAccumulator.calculateBlockScore(WAD / 2, WAD, WAD);
        assertEq(score, WAD / 2);
    }

    // ---------- calculateRangeNarrowness ----------

    function test_rangeNarrowness_monotonicity() public pure {
        uint256 narrow = ScoreAccumulator.calculateRangeNarrowness(-10, 10);
        uint256 medium = ScoreAccumulator.calculateRangeNarrowness(-100, 100);
        uint256 wide   = ScoreAccumulator.calculateRangeNarrowness(-1000, 1000);
        assertGt(narrow, medium);
        assertGt(medium, wide);
    }

    function test_rangeNarrowness_revertOnInvalid() public {
        vm.expectRevert(ScoreAccumulator.InvalidTickRange.selector);
        this.callRangeNarrowness(100, 100);
    }

    function test_rangeNarrowness_revertOnInverted() public {
        vm.expectRevert(ScoreAccumulator.InvalidTickRange.selector);
        this.callRangeNarrowness(100, 50);
    }

    // ---------- calculateRealizedIL: reference cases (sim 4 CSV) ----------

    function test_realizedIL_noPriceChange() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, ENTRY_SQRT);
        assertEq(il, 0);
    }

    function test_realizedIL_up5pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 81184708056111256723576061952);
        _assertClose(il, -297486247844062, 1e10);
    }

    function test_realizedIL_up20pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 86790103597495583603102318592);
        _assertClose(il, -4140804536061605, 1e10);
    }

    function test_realizedIL_up50pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 97034285709124584035923787776);
        _assertClose(il, -20204102886728744, 1e10);
    }

    function test_realizedIL_double() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 112045541949572287496682733568);
        _assertClose(il, -57190958417936660, 1e10);
    }

    function test_realizedIL_triple() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 137227202865029789651872776192);
        _assertClose(il, -133974596215561320, 1e10);
    }

    function test_realizedIL_down5pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 77222060634363714391462903808);
        _assertClose(il, -328785147798575, 1e10);
    }

    function test_realizedIL_down20pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 70863822845718282283796922368);
        _assertClose(il, -6192010000093471, 1e10);
    }

    function test_realizedIL_down30pct() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 66287036551430451535630303232);
        _assertClose(il, -15694086430499350, 1e10);
    }

    function test_realizedIL_half() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 56022770974786143748341366784);
        _assertClose(il, -57190958417936620, 1e10);
    }

    function test_realizedIL_crash75() public pure {
        int256 il = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 39614081257132168796771975168);
        _assertClose(il, -200000000000000000, 1e10);
    }

    function test_realizedIL_symmetryDoubleVsHalf() public pure {
        int256 ilUp = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 112045541949572287496682733568);
        int256 ilDown = ScoreAccumulator.calculateRealizedIL(ENTRY_SQRT, 56022770974786143748341366784);
        _assertClose(ilUp, ilDown, 1e10);
    }

    function test_realizedIL_revertOnZeroEntry() public {
        vm.expectRevert(ScoreAccumulator.InvalidSqrtPrice.selector);
        this.callRealizedIL(0, ENTRY_SQRT);
    }

    function test_realizedIL_revertOnZeroCurrent() public {
        vm.expectRevert(ScoreAccumulator.InvalidSqrtPrice.selector);
        this.callRealizedIL(ENTRY_SQRT, 0);
    }

    // ---------- fuzz ----------

    function testFuzz_realizedIL_neverPositive(uint160 entry, uint160 current) public pure {
        // Bound to realistic sqrtPriceX96 range (typical LP token pairs)
        entry = uint160(bound(uint256(entry), 1e24, 1e30));
        current = uint160(bound(uint256(current), 1e24, 1e30));
        int256 il = ScoreAccumulator.calculateRealizedIL(entry, current);
        assertLe(il, 0);
    }

    // ---------- helpers ----------

    function _assertClose(int256 actual, int256 expected, uint256 tolerance) internal pure {
        int256 diff = actual > expected ? actual - expected : expected - actual;
        assertLe(uint256(diff), tolerance, "IL diff exceeds tolerance");
    }

    function callRangeNarrowness(int24 a, int24 b) external pure {
        ScoreAccumulator.calculateRangeNarrowness(a, b);
    }

    function callRealizedIL(uint160 a, uint160 b) external pure {
        ScoreAccumulator.calculateRealizedIL(a, b);
    }
}
