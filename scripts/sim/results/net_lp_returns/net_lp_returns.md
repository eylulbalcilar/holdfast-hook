# Net LP Returns Comparison

Generated: 2026-05-17 15:32 UTC

Script: `scripts/sim/net_lp_returns.py`

## Scenario parameters

- Monthly swap volume: $1,000,000
- Pool fee rate: 0.30%
- Redistribution rate: 15%
- Volatility multiplier: 1.2x
- Aave V3 USDC supply APY (testnet estimate): 3.0%
- LP pool share for comparison: 10%

## Pool-level totals

- Total swapper fees: $3,000.00
- LP direct pool (85% of fees): $2,550.00
- Bonus pool base (15% × 1.2x vol mult): $540.00
- Aave yield on bonus pool (monthly, avg-balance approx): $0.6750
- Bonus pool total: $540.67
- Tier-weighted arm (70% of bonus): $378.47
- Realized-IL arm (30% of bonus): excluded from this sim (path-dependent)

## Per-LP comparison

| Profile | Standard pool | Holdfast direct | Holdfast bonus | Holdfast total | Delta $ | Delta % |
|---|---|---|---|---|---|---|
| Mercenary (no tier) | $300.00 | $255.00 | $0.00 | $255.00 | -45.00 | -15.00% |
| Bronze (1 of 50, 2%) | $300.00 | $255.00 | $1.89 | $256.89 | -43.11 | -14.37% |
| Silver (1 of 10, 10%) | $300.00 | $255.00 | $13.25 | $268.25 | -31.75 | -10.58% |
| Silver (1 of 3, 30%) | $300.00 | $255.00 | $39.74 | $294.74 | -5.26 | -1.75% |
| Gold (1 of 3, 30%) | $300.00 | $255.00 | $45.42 | $300.42 | +0.42 | +0.14% |

## Aave yield contribution (transparency)

| Profile | Bonus total $ | Aave portion $ | Aave % of bonus |
|---|---|---|---|
| Mercenary (no tier) | $0.0000 | $0.0000 | 0.00% |
| Bronze (1 of 50, 2%) | $1.8924 | $0.0024 | 0.13% |
| Silver (1 of 10, 10%) | $13.2465 | $0.0165 | 0.12% |
| Silver (1 of 3, 30%) | $39.7396 | $0.0496 | 0.12% |
| Gold (1 of 3, 30%) | $45.4167 | $0.0567 | 0.12% |

## Interpretation

- Loyal high-tier LPs with significant intra-tier share outperform the standard pool.
- Mercenary LPs experience the designed retention penalty of ~-15%.
- Aave supply yield on the bonus pool is small at testnet APYs but scales with TVL and APY.
- The realized-IL arm (30% of bonus pool) is excluded here because it depends on the actual price path; it is sanity-checked separately in `realized_il_check.py`.
