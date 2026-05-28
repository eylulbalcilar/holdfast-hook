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
    error ZeroSqrtPriceObservation();

    /// @notice Calibration scalar applied to raw variance before WAD normalization.
    /// @dev Initial placeholder. Calibrated such that ~20% annualized historical
    ///      volatility maps to ~1.0 WAD. Subject to refinement via scripts/sim/.
    uint256 internal constant SCALE_FACTOR = 1e18;

    uint256 internal constant MAX_VOLATILITY_FACTOR = 2 * WAD;

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

    /// @notice Volatility factor derived from 10 consecutive sqrtPriceX96 observations.
    /// @dev Variance of 9 consecutive sqrtPrice ratios, scaled to price variance
    ///      via the d(p)/p ~= 2 * d(sqrtP)/sqrtP identity. WAD-scaled, capped at 2*WAD.
    /// @param observations Ring buffer ordered oldest to newest (caller responsibility).
    /// @return volatilityFactor WAD-scaled volatility, in [0, 2*WAD].
    function calculateVolatilityFactor(
        uint160[10] memory observations
    ) internal pure returns (uint256 volatilityFactor) {
        // 1. Compute 9 consecutive sqrtPrice ratios in WAD scale.
        uint256[9] memory ratios;
        for (uint256 i = 0; i < 9; i++) {
            uint256 prev = uint256(observations[i]);
            uint256 next = uint256(observations[i + 1]);
            if (prev == 0) revert ZeroSqrtPriceObservation();
            ratios[i] = FixedPointMathLib.fullMulDiv(next, WAD, prev);
        }

        // 2. Mean of the 9 ratios.
        uint256 sum;
        for (uint256 i = 0; i < 9; i++) {
            sum += ratios[i];
        }
        uint256 mean = sum / 9;

        // 3. Population variance in WAD squared.
        uint256 sumSquaredDeviations;
        for (uint256 i = 0; i < 9; i++) {
            uint256 diff = ratios[i] >= mean ? ratios[i] - mean : mean - ratios[i];
            sumSquaredDeviations += diff * diff;
        }
        uint256 variance = sumSquaredDeviations / 9;

        // 4. sqrtPrice variance to price variance: multiply by 4.
        //    d(p)/p ~= 2 * d(sqrtP)/sqrtP, so Var(price) ~= 4 * Var(sqrtPrice ratio).
        variance *= 4;

        // 5. WAD squared to WAD, apply SCALE_FACTOR.
        volatilityFactor = FixedPointMathLib.fullMulDiv(variance, SCALE_FACTOR, WAD);

        // 6. Cap at 2 * WAD.
        if (volatilityFactor > MAX_VOLATILITY_FACTOR) {
            volatilityFactor = MAX_VOLATILITY_FACTOR;
        }
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
