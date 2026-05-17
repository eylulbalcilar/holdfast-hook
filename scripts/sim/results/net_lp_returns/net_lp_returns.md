# Net LP Returns - Multi-Scenario Calibration

Generated: 2026-05-17 15:36 UTC

Script: `scripts/sim/net_lp_returns.py`

## Shared parameters

- Monthly swap volume: $1,000,000
- Pool fee rate: 0.30%
- Aave V3 USDC supply APY (testnet estimate): 3.0%
- LP pool share: 10%
- Tier-weighted arm fraction: 70% (realized-IL arm 30% excluded)

## Scenario: Baseline (low-vol pool)

- Redistribution rate: 15%
- Volatility multiplier: 1.2x
- Notes: Default parameters from DESIGN.md; low-volatility regime.

### Pool-level totals

- Total swapper fees: $3000.00
- LP direct pool: $2550.00
- Bonus pool base: $540.00
- Aave yield on bonus: $0.6750
- Bonus pool total: $540.67
- Tier-weighted arm: $378.47

### Per-LP comparison

| Profile | Standard pool | Holdfast total | Delta $ | Delta % |
|---|---|---|---|---|
| Mercenary (no tier) | $300.00 | $255.00 | -45.00 | -15.00% |
| Bronze (1 of 50, 2%) | $300.00 | $256.89 | -43.11 | -14.37% |
| Silver (1 of 10, 10%) | $300.00 | $268.25 | -31.75 | -10.58% |
| Silver (1 of 3, 30%) | $300.00 | $294.74 | -5.26 | -1.75% |
| Gold (1 of 3, 30%) | $300.00 | $300.42 | +0.42 | +0.14% |

## Scenario: High-volatility pool

- Redistribution rate: 15%
- Volatility multiplier: 2.0x
- Notes: Same redistribution rate, volatile pair (e.g. ETH/BTC during stress).

### Pool-level totals

- Total swapper fees: $3000.00
- LP direct pool: $2550.00
- Bonus pool base: $900.00
- Aave yield on bonus: $1.1250
- Bonus pool total: $901.12
- Tier-weighted arm: $630.79

### Per-LP comparison

| Profile | Standard pool | Holdfast total | Delta $ | Delta % |
|---|---|---|---|---|
| Mercenary (no tier) | $300.00 | $255.00 | -45.00 | -15.00% |
| Bronze (1 of 50, 2%) | $300.00 | $258.15 | -41.85 | -13.95% |
| Silver (1 of 10, 10%) | $300.00 | $277.08 | -22.92 | -7.64% |
| Silver (1 of 3, 30%) | $300.00 | $321.23 | +21.23 | +7.08% |
| Gold (1 of 3, 30%) | $300.00 | $330.69 | +30.69 | +10.23% |

## Scenario: Adjusted redistribution

- Redistribution rate: 20%
- Volatility multiplier: 1.5x
- Notes: Stronger bonus pool funding; tighter mercenary penalty.

### Pool-level totals

- Total swapper fees: $3000.00
- LP direct pool: $2400.00
- Bonus pool base: $900.00
- Aave yield on bonus: $1.1250
- Bonus pool total: $901.12
- Tier-weighted arm: $630.79

### Per-LP comparison

| Profile | Standard pool | Holdfast total | Delta $ | Delta % |
|---|---|---|---|---|
| Mercenary (no tier) | $300.00 | $240.00 | -60.00 | -20.00% |
| Bronze (1 of 50, 2%) | $300.00 | $243.15 | -56.85 | -18.95% |
| Silver (1 of 10, 10%) | $300.00 | $262.08 | -37.92 | -12.64% |
| Silver (1 of 3, 30%) | $300.00 | $306.23 | +6.23 | +2.08% |
| Gold (1 of 3, 30%) | $300.00 | $315.69 | +15.69 | +5.23% |

## Cross-scenario summary (Delta %)

| Profile | Baseline (low-vol pool) | High-volatility pool | Adjusted redistribution |
|---|---|---|---|
| Mercenary (no tier) | -15.00% | -15.00% | -20.00% |
| Bronze (1 of 50, 2%) | -14.37% | -13.95% | -18.95% |
| Silver (1 of 10, 10%) | -10.58% | -7.64% | -12.64% |
| Silver (1 of 3, 30%) | -1.75% | +7.08% | +2.08% |
| Gold (1 of 3, 30%) | +0.14% | +10.23% | +5.23% |

## Calibration findings

- The baseline scenario (15% redistribution, 1.2x vol multiplier) produces a marginal Gold premium near zero. This is consistent with DESIGN.md Limitations: low-volatility pools provide minimal LP benefit.
- Holdfast's mechanism scales with pool volatility. The high-volatility scenario (2.0x multiplier) restores a meaningful loyal-LP premium without changing redistribution rate.
- Raising redistribution to 20% with moderate vol multiplier (1.5x) produces a similar premium but increases mercenary penalty, sharpening retention pressure.
- Recommended deployment: target pools with annualized volatility > 20% (per DESIGN.md). Final redistribution rate to be set per-pool at initialization based on observed volatility regime.
