// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoreAccumulator} from "../../src/libraries/ScoreAccumulator.sol";

contract VolatilityTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_VF = 2 * WAD;
    uint160 constant SQRT1 = 79228162514264337593543950336;

    function _steady(uint256 num, uint256 den) internal pure returns (uint160[10] memory obs) {
        uint256 x = uint256(SQRT1);
        for (uint256 i = 0; i < 10; i++) {
            obs[i] = uint160(x);
            x = x * num / den;
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
        uint256 v2 = ScoreAccumulator.calculateVolatilityFactor(_steady(102, 100));
        uint256 v5 = ScoreAccumulator.calculateVolatilityFactor(_steady(105, 100));
        uint256 v50 = ScoreAccumulator.calculateVolatilityFactor(_steady(150, 100));
        assertLt(v2, v5, "larger steps yield larger volatility");
        assertLt(v5, v50, "larger steps yield larger volatility");
    }

    function test_vol_referenceValues() public pure {
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steady(102, 100)), 1599999999999996);
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steady(105, 100)), 9999999999999996);
        assertEq(ScoreAccumulator.calculateVolatilityFactor(_steady(150, 100)), 1000000000000000000);
    }

    function test_vol_cappedAtTwoWad() public pure {
        uint256 vf = ScoreAccumulator.calculateVolatilityFactor(_steady(300, 100));
        assertEq(vf, MAX_VF);
    }

    function test_vol_singleOutlierDampened() public pure {
        uint160[10] memory single = _flat();
        single[5] = uint160(uint256(SQRT1) * 110 / 100);
        uint256 vfSingle = ScoreAccumulator.calculateVolatilityFactor(single);
        uint256 vfSustained = ScoreAccumulator.calculateVolatilityFactor(_steady(110, 100));
        assertLt(vfSingle, vfSustained, "single outlier dampened vs sustained movement");
        assertEq(vfSingle, 8117539026629932);
    }
}
