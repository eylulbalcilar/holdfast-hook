// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title ScoreAccumulator
/// @notice Pure functions for Holdfast position scoring and realized IL computation.
/// @dev All WAD-scaled (1e18). Score and IL formulas calibrated in scripts/sim/.
library ScoreAccumulator {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 internal constant WAD = 1e18;

    error InvalidTickRange();
    error InvalidSqrtPrice();

    /// @notice Per-block score contribution for a position.
    function calculateBlockScore(
        uint256 liquidityShare,
        uint256 volatilityFactor,
        uint256 rangeNarrowness
    ) internal pure returns (uint256 blockScore) {
       blockScore = liquidityShare.mulWad(volatilityFactor).mulWad(rangeNarrowness);
    }

    /// @notice Logarithmic range narrowness coefficient.
    /// @dev Formula: 1 / ln(tickUpper - tickLower + 2), WAD-scaled.
    function calculateRangeNarrowness(
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256 narrowness) {
        if (tickUpper <= tickLower) revert InvalidTickRange();
        uint256 width = uint256(int256(tickUpper) - int256(tickLower)) + 2;
        int256 lnResult = FixedPointMathLib.lnWad(int256(width * WAD));
        narrowness = (WAD * WAD) / uint256(lnResult);
    }

    /// @notice Realized IL between entry and current price.
    /// @dev IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1, priceRatio = (current/entry)^2.
    function calculateRealizedIL(
        uint160 entrySqrtPriceX96,
        uint160 currentSqrtPriceX96
    ) internal pure returns (int256 il) {
        if (entrySqrtPriceX96 == 0 || currentSqrtPriceX96 == 0) revert InvalidSqrtPrice();

        uint256 sqrtRatioWad = FixedPointMathLib.fullMulDiv(
            uint256(currentSqrtPriceX96),
            WAD,
            uint256(entrySqrtPriceX96)
        );
        uint256 priceRatioWad = FixedPointMathLib.fullMulDiv(sqrtRatioWad, sqrtRatioWad, WAD);
        uint256 numerator = 2 * sqrtRatioWad;
        uint256 denominator = WAD + priceRatioWad;
        uint256 ratioTerm = FixedPointMathLib.fullMulDiv(numerator, WAD, denominator);

        il = int256(ratioTerm) - int256(WAD);
    }
}
