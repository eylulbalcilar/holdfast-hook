"""
Holdfast - SCALE_FACTOR Calibration
====================================
Target: ~20% annualized volatility -> volatilityFactor ~= 1.0 WAD

The on-chain formula (ScoreAccumulator.calculateVolatilityFactor):
  1. Compute 9 consecutive sqrtPrice ratios in WAD scale
  2. Sum squared deviations from WAD (no-change reference), normalized to WAD
  3. variance = sumSquaredDeviations / 9
  4. variance *= 4  (sqrtPrice -> price conversion)
  5. volatilityFactor = variance * SCALE_FACTOR / WAD

We want: volatilityFactor = 1.0 WAD when annualized vol = 20%

Relationship between annualized vol and per-swap sqrtPrice deviation:
  annualized_vol = sqrt(swaps_per_year) * per_swap_price_stddev
  per_swap_price_stddev = annualized_vol / sqrt(swaps_per_year)

  sqrtPrice deviation ~= price_deviation / 2  (first-order approximation)
  per_swap_sqrt_stddev = per_swap_price_stddev / 2

  variance (WAD-scaled, step 2-3-4) = 4 * E[(sqrtRatio - 1)^2]
                                     = 4 * per_swap_sqrt_stddev^2
                                     = per_swap_price_stddev^2

So: raw_variance_wad = per_swap_price_stddev^2 * WAD

Target: SCALE_FACTOR such that raw_variance_wad * SCALE_FACTOR / WAD = 1.0 WAD
  => SCALE_FACTOR = WAD^2 / raw_variance_wad
                  = WAD / per_swap_price_stddev^2
"""

import math
import json
import numpy as np
from pathlib import Path
from datetime import datetime, timezone

WAD = 10**18

# --- Parameters ---
SWAPS_PER_DAY   = 500       # realistic active USDC/ETH pool on Base
BLOCKS_PER_DAY  = 43_200    # 2s block time
SWAPS_PER_YEAR  = SWAPS_PER_DAY * 365

# Annualized volatility targets to sweep
VOL_TARGETS = [0.10, 0.20, 0.40, 0.60, 0.80, 1.00]

# Number of Monte Carlo sequences per vol target
N_SEQUENCES = 100_000

# Ring buffer size (matches on-chain: 10 observations, 9 ratios)
BUFFER_SIZE = 10


def simulate_ring_buffer_variance(per_swap_price_std: float, n: int = N_SEQUENCES) -> float:
    """
    Simulate n sequences of 10 sqrtPrice observations and compute the mean
    variance as calculated by the on-chain formula.
    Returns mean raw_variance (float, pre-SCALE_FACTOR, pre-WAD-normalization).
    """
    variances = []
    for _ in range(n):
        # Generate 10 log-normal price moves
        log_returns = np.random.normal(0, per_swap_price_std, BUFFER_SIZE - 1)
        price_ratios = np.exp(log_returns)  # consecutive price ratios
        sqrt_ratios  = np.sqrt(price_ratios)  # consecutive sqrtPrice ratios

        # Squared deviations from 1.0 (no-change reference), averaged over 9
        sq_devs = (sqrt_ratios - 1.0) ** 2
        variance = sq_devs.mean()  # mean of 9 squared deviations

        # Multiply by 4 (sqrtPrice -> price conversion, matches on-chain step 3)
        variance *= 4

        variances.append(variance)

    return float(np.mean(variances))


def compute_scale_factor(target_vol: float) -> dict:
    per_swap_price_std = target_vol / math.sqrt(SWAPS_PER_YEAR)
    raw_variance       = simulate_ring_buffer_variance(per_swap_price_std)

    # SCALE_FACTOR such that raw_variance * SCALE_FACTOR / WAD = 1.0 WAD
    # => SCALE_FACTOR = WAD / raw_variance  (raw_variance is float 0..1)
    if raw_variance == 0:
        scale_factor = None
    else:
        scale_factor = WAD / raw_variance

    # Theoretical (closed-form) cross-check
    per_swap_sqrt_std  = per_swap_price_std / 2
    theoretical_var    = 4 * per_swap_sqrt_std**2
    theoretical_sf     = WAD / theoretical_var if theoretical_var > 0 else None

    return {
        "annualized_vol":       target_vol,
        "per_swap_price_std":   per_swap_price_std,
        "simulated_variance":   raw_variance,
        "scale_factor_sim":     scale_factor,
        "theoretical_variance": theoretical_var,
        "scale_factor_theory":  theoretical_sf,
        "vf_at_1wad_check":     raw_variance * scale_factor if scale_factor else None,
    }


def main():
    print("Holdfast SCALE_FACTOR Calibration")
    print(f"Swaps/year: {SWAPS_PER_YEAR:,}  |  N sequences: {N_SEQUENCES:,}")
    print(f"Target: 20% annualized vol -> volatilityFactor = 1.0 WAD")
    print()

    results = []
    for vol in VOL_TARGETS:
        r = compute_scale_factor(vol)
        results.append(r)
        sf_sim = r["scale_factor_sim"]
        sf_sci = f"{sf_sim:.4e}" if sf_sim else "N/A"
        sf_wad = f"{sf_sim/WAD:.4f}" if sf_sim else "N/A"
        print(f"  vol={vol*100:5.1f}%  per_swap_std={r['per_swap_price_std']:.6f}"
              f"  raw_var={r['simulated_variance']:.4e}"
              f"  SCALE_FACTOR={sf_sci}  ({sf_wad} * WAD)")

    # The calibration target is 20% -> 1.0 WAD
    target = next(r for r in results if r["annualized_vol"] == 0.20)
    recommended_sf = int(target["scale_factor_sim"])

    print()
    print(f"Recommended SCALE_FACTOR (20% -> 1.0 WAD): {recommended_sf}")
    print(f"  = {recommended_sf:.4e}")
    print(f"  = {recommended_sf/WAD:.4f} * WAD")
    print()

    # Verify: what does each vol level produce with the recommended SCALE_FACTOR?
    print("Verification: volatilityFactor at recommended SCALE_FACTOR")
    print(f"  {'Vol':>8}  {'vF (WAD units)':>16}  {'capped at 2.0?':>14}")
    for r in results:
        vf = r["simulated_variance"] * recommended_sf / WAD
        capped = vf > 2.0
        print(f"  {r['annualized_vol']*100:7.1f}%  {vf:16.4f}  {'YES' if capped else 'no':>14}")

    # Save results
    out_dir = Path(__file__).parent / "results" / "scale_factor_calibration"
    out_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    # JSON summary
    summary = {
        "generated_at":       ts,
        "swaps_per_year":     SWAPS_PER_YEAR,
        "n_sequences":        N_SEQUENCES,
        "recommended_scale_factor": recommended_sf,
        "recommended_scale_factor_hex": hex(recommended_sf),
        "results":            results,
    }
    json_path = out_dir / f"calibration_{ts}.json"
    with open(json_path, "w") as f:
        json.dump(summary, f, indent=2)

    # Latest symlink-style copy
    latest_path = out_dir / "latest.json"
    with open(latest_path, "w") as f:
        json.dump(summary, f, indent=2)

    print()
    print(f"Results saved to {out_dir}/")
    print(f"  latest.json  |  {json_path.name}")

    return recommended_sf


if __name__ == "__main__":
    main()
