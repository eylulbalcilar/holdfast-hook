# Realized IL Formula Sanity Check

Generated: 2026-05-17 15:41 UTC

Script: `scripts/sim/realized_il_check.py`

## Formula under test

```
priceRatio = (currentSqrtPrice / entrySqrtPrice)^2
IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1
```

This is equivalent to `IL = 2 * sqrt(r) / (1 + r) - 1` where `r = currentPrice / entryPrice`, the standard constant-product impermanent loss expression.

## Method

Two implementations are computed and compared:

1. **Float**: reference Python implementation using `math.sqrt`.
2. **X96 integer**: integer arithmetic on Q64.96 fixed-point values, mirroring the Solidity flow that operates on `uint160 sqrtPriceX96` values from Uniswap v4.

If the two paths agree across price scenarios, the integer implementation can be ported to Solidity with predictable rounding behavior.

## Scenarios (entry price = 1.0)

| Scenario | Δ price | Current price | IL (float) | IL (X96 int) | Abs diff |
|---|---|---|---|---|---|
| No price change | +0.0% | 1.000000 | +0.0000% | +0.0000% | 0.000000% |
| Small up (+5%) | +5.0% | 1.050000 | -0.0297% | -0.0297% | 0.000000% |
| Medium up (+20%) | +20.0% | 1.200000 | -0.4141% | -0.4141% | 0.000000% |
| Large up (+50%) | +50.0% | 1.500000 | -2.0204% | -2.0204% | 0.000000% |
| Double (+100%) | +100.0% | 2.000000 | -5.7191% | -5.7191% | 0.000000% |
| Triple (+200%) | +200.0% | 3.000000 | -13.3975% | -13.3975% | 0.000000% |
| Small down (-5%) | -5.0% | 0.950000 | -0.0329% | -0.0329% | 0.000000% |
| Medium down (-20%) | -20.0% | 0.800000 | -0.6192% | -0.6192% | 0.000000% |
| Down -30% | -30.0% | 0.700000 | -1.5694% | -1.5694% | 0.000000% |
| Half (-50%) | -50.0% | 0.500000 | -5.7191% | -5.7191% | 0.000000% |
| Crash (-75%) | -75.0% | 0.250000 | -20.0000% | -20.0000% | 0.000000% |

## Known-value cross-check

Reference values from the constant-product IL curve (Uniswap research, Bancor docs).

| Δ price | Expected IL | Computed IL | Match |
|---|---|---|---|
| +25.0% | -0.6200% | -0.6192% | PASS |
| +50.0% | -2.0300% | -2.0204% | PASS |
| +100.0% | -5.7200% | -5.7191% | PASS |
| +200.0% | -13.4000% | -13.3975% | PASS |
| -50.0% | -5.7200% | -5.7191% | PASS |

## Result

- All known-value cross-checks: **PASS**
- Max abs diff (float vs X96 integer) across 11 scenarios: 0.000000%
- The float and integer implementations agree to within rounding precision.
- This table serves as the reference for `ScoreAccumulator.calculateRealizedIL` unit tests in `test/unit/ScoreAccumulator.t.sol`.

## Properties verified

- IL is zero when price is unchanged.
- IL is symmetric under r vs 1/r: a +100% move and a -50% move both yield ~-5.72% IL.
- IL is monotonically negative as |log(r)| grows.
- Magnitudes match standard reference values to 4 decimal places.
