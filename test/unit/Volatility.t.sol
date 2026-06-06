// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ScoreAccumulator} from "../../src/libraries/ScoreAccumulator.sol";
contract VolatilityTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_VF = 2 * WAD;
    uint160 constant SQRT1 = 79228162514264337593543950336;

    /// @dev Steady per-step move in bips (1 bip = 0.01%). Realistic per-swap sizes.
    function _steadyBips(uint256 bips) internal pure returns (uint160[10] memory obs) {
        uint256 x = uint256(SQRT1);
        for (uint256 i = 0; i < 10; i++) {
            obs[i] = uint160(x);
            x = x * (10000 + bips) / 10000;
        }
    }

    function _flat() internal pure returns (uint160[10] memory obs) {
        for (uint256 i = 0; i < 10; i++) {
            obs[i] = SQRT1;
        }
    }

    function callVolatility(uint160[10] memory obs) external pure returns (uint256) {
        return ScoreAccumulator.calculateVolatilityFactor(obs);
    }

    function test_vol_identicalIsZero() public pure {
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_flat()), 0);
    }

    function test_vol_zeroObservationReverts() public {
        uint160[10] memory obs = _flat();
        obs[3] = 0;
        vm.expectRevert(ScoreAccumulator.ZeroSqrtPriceObservation.selector);
        this.callVolatility(obs);
    }

    function test_vol_monotonicInMovement() public pure {
        uint256 v1 = ScoreAccumulator.calculateVolatilityFactor(_steadyBips(1));
        uint256 v2 = ScoreAccumulator.calculateVolatilityFactor(_steadyBips(2));
        uint256 v5 = ScoreAccumulator.calculateVolatilityFactor(_steadyBips(5));
        assertLt(v1, v2, "larger steps yield larger volatility");
        assertLt(v2, v5, "larger steps yield larger volatility");
    }

    /// @dev Reference values calibrated for SCALE_FACTOR = 1_144_477_832_530_842_431_258_624.
    ///      Inputs are realistic per-swap bips moves (1 bip = 0.01%).
    ///      Regenerate via scripts/sim/scale_factor_calibration.py if SCALE_FACTOR changes.
    function test_vol_referenceValues() public pure {
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steadyBips(1)), 45779113296655785);
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steadyBips(2)), 183116453200356877);
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steadyBips(5)), 1144477832526264519);
    }

    function test_vol_cappedAtTwoWad() public pure {
        // 10+ bips per swap exceeds cap with calibrated SCALE_FACTOR.
        uint256 vf = ScoreAccumulator.calculateVolatilityFactor(_steadyBips(10));
        assertEq(vf, MAX_VF);
    }

    function test_vol_singleOutlierDampened() public pure {
        // Single 5-bip outlier at obs[5], rest flat.
        uint160[10] memory single = _flat();
        single[5] = uint160(uint256(SQRT1) * 10005 / 10000);
        uint256 vfSingle    = ScoreAccumulator.calculateVolatilityFactor(single);
        uint256 vfSustained = ScoreAccumulator.calculateVolatilityFactor(_steadyBips(5));
        assertLt(vfSingle, vfSustained, "single outlier dampened vs sustained movement");
        assertEq(vfSingle, 254201338334014853);
    }

    /// @dev Regression: an extreme single-swap sqrtPrice jump (price pushed toward
    ///      the tick limit) produces a very large ratio. Squaring it must not
    ///      overflow before the result is downscaled and capped at MAX_VF.
    function test_vol_extremeJumpDoesNotOverflow() public pure {
        uint160[10] memory obs = _flat();
        // Replace one observation with a near-MAX_SQRT_PRICE value so the
        // adjacent ratio is enormous.
        obs[5] = uint160(1461446703485210103287273052203988822378723970341);
        uint256 vf = ScoreAccumulator.calculateVolatilityFactor(obs);
        assertEq(vf, MAX_VF);
    }

    /// @dev Same extreme but as a sustained run, exercising several large ratios.
    function test_vol_extremeRunDoesNotOverflow() public pure {
        uint160[10] memory obs;
        uint256 x = uint256(SQRT1);
        for (uint256 i = 0; i < 10; i++) {
            obs[i] = uint160(x);
            x = x * 1000;
        }
        uint256 vf = ScoreAccumulator.calculateVolatilityFactor(obs);
        assertEq(vf, MAX_VF);
    }

}
