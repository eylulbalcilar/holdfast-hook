# Tier Calibration Results

Generated: 2026-05-17 15:20 UTC

Script: `scripts/sim/tier_calibration.py`

## Parameters

- Block time: 2s (Base Sepolia)
- Bronze threshold: 1.00e+19 WAD-score / min 1,000 blocks (33.3 min)
- Silver threshold: 1.00e+20 WAD-score / min 10,000 blocks (5.6 h)
- Gold threshold:   1.00e+21 WAD-score / min 100,000 blocks (2.3 days)

## Results

| Scenario | Score/block | Bronze | Silver | Gold |
|---|---|---|---|---|
| Small LP (2%), narrow range, low vol | 0.0015 | 3.8 h (score) | 38.2 h (score) | 15.9 days (score) |
| Small LP (2%), narrow range, high vol | 0.0048 | 1.1 h (score) | 11.5 h (score) | 4.8 days (score) |
| Medium LP (10%), medium range, medium vol | 0.0113 | 33.3 min (blocks) | 5.6 h (blocks) | 2.3 days (blocks) |
| Large LP (30%), wide range, low vol | 0.0130 | 33.3 min (blocks) | 5.6 h (blocks) | 2.3 days (blocks) |
| Whale (50%), narrow range, high vol | 0.1211 | 33.3 min (blocks) | 5.6 h (blocks) | 2.3 days (blocks) |
| Baseline (all factors = 1.0) | 0.9102 | 33.3 min (blocks) | 5.6 h (blocks) | 2.3 days (blocks) |

## Gating legend

- **(blocks)**: block minimum is the binding constraint (mitigation against whale-instant-Gold)
- **(score)**: score threshold is the binding constraint (small/inactive LPs)

## Calibration check

- Medium LP (10%, 200-tick range, medium vol) reaches Bronze in ~33 min, blocks-gated
- Whale (50%, narrow range, high vol) reaches Gold in ~2.3 days, blocks-gated (mitigation working)
- Small LPs (2% share) are score-gated at higher tiers, by design
