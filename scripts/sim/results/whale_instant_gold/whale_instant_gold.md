# Whale-Instant-Gold Mitigation Proof

Generated: 2026-05-17 15:28 UTC

Script: `scripts/sim/whale_instant_gold.py`

## Goal

Prove that the Gold tier block minimum (100,000 blocks = 2.31 days on Base) prevents any high-liquidity LP from reaching Gold faster, regardless of liquidity share, volatility, or range narrowness.

## Parameter sweep

- Liquidity shares: [0.5, 0.7, 0.9, 0.99] (50% to near-monopoly)
- Volatility factors: [0.5, 1.0, 1.5, 2.0] (medium to extreme)
- Tick widths: [10, 60, 200] (very narrow to medium)
- Total configurations tested: 48

## Result

**PASS**: all 48 whale configurations are blocks-gated. The block minimum is the binding constraint for every tested whale profile.

### Worst-case whale (hypothetical, without block minimum cap)

- Configuration: liquidity share = 99%, volatility = 2.0, tick width = 10
- Score per block: 0.7968
- Blocks to Gold threshold (score only): 1,256 (~0.70 hours)
- Effective time under dual criteria: 2.31 days
- Mitigation factor: 79.6x slowdown

## Full results

| Liq share | Vol | Tick width | Score/block | Score-only blocks | Effective time | Gate |
|---|---|---|---|---|---|---|
| 0.50 | 0.5 | 10 | 0.1006 | 9,940 | 2.31 days | blocks |
| 0.50 | 0.5 | 60 | 0.0606 | 16,509 | 2.31 days | blocks |
| 0.50 | 0.5 | 200 | 0.0471 | 21,234 | 2.31 days | blocks |
| 0.50 | 1.0 | 10 | 0.2012 | 4,970 | 2.31 days | blocks |
| 0.50 | 1.0 | 60 | 0.1211 | 8,255 | 2.31 days | blocks |
| 0.50 | 1.0 | 200 | 0.0942 | 10,617 | 2.31 days | blocks |
| 0.50 | 1.5 | 10 | 0.3018 | 3,314 | 2.31 days | blocks |
| 0.50 | 1.5 | 60 | 0.1817 | 5,503 | 2.31 days | blocks |
| 0.50 | 1.5 | 200 | 0.1413 | 7,078 | 2.31 days | blocks |
| 0.50 | 2.0 | 10 | 0.4024 | 2,485 | 2.31 days | blocks |
| 0.50 | 2.0 | 60 | 0.2423 | 4,128 | 2.31 days | blocks |
| 0.50 | 2.0 | 200 | 0.1884 | 5,309 | 2.31 days | blocks |
| 0.70 | 0.5 | 10 | 0.1409 | 7,100 | 2.31 days | blocks |
| 0.70 | 0.5 | 60 | 0.0848 | 11,792 | 2.31 days | blocks |
| 0.70 | 0.5 | 200 | 0.0659 | 15,167 | 2.31 days | blocks |
| 0.70 | 1.0 | 10 | 0.2817 | 3,550 | 2.31 days | blocks |
| 0.70 | 1.0 | 60 | 0.1696 | 5,896 | 2.31 days | blocks |
| 0.70 | 1.0 | 200 | 0.1319 | 7,584 | 2.31 days | blocks |
| 0.70 | 1.5 | 10 | 0.4226 | 2,367 | 2.31 days | blocks |
| 0.70 | 1.5 | 60 | 0.2544 | 3,931 | 2.31 days | blocks |
| 0.70 | 1.5 | 200 | 0.1978 | 5,056 | 2.31 days | blocks |
| 0.70 | 2.0 | 10 | 0.5634 | 1,775 | 2.31 days | blocks |
| 0.70 | 2.0 | 60 | 0.3392 | 2,948 | 2.31 days | blocks |
| 0.70 | 2.0 | 200 | 0.2637 | 3,792 | 2.31 days | blocks |
| 0.90 | 0.5 | 10 | 0.1811 | 5,523 | 2.31 days | blocks |
| 0.90 | 0.5 | 60 | 0.1090 | 9,172 | 2.31 days | blocks |
| 0.90 | 0.5 | 200 | 0.0848 | 11,797 | 2.31 days | blocks |
| 0.90 | 1.0 | 10 | 0.3622 | 2,762 | 2.31 days | blocks |
| 0.90 | 1.0 | 60 | 0.2181 | 4,586 | 2.31 days | blocks |
| 0.90 | 1.0 | 200 | 0.1695 | 5,899 | 2.31 days | blocks |
| 0.90 | 1.5 | 10 | 0.5433 | 1,841 | 2.31 days | blocks |
| 0.90 | 1.5 | 60 | 0.3271 | 3,058 | 2.31 days | blocks |
| 0.90 | 1.5 | 200 | 0.2543 | 3,933 | 2.31 days | blocks |
| 0.90 | 2.0 | 10 | 0.7244 | 1,381 | 2.31 days | blocks |
| 0.90 | 2.0 | 60 | 0.4361 | 2,293 | 2.31 days | blocks |
| 0.90 | 2.0 | 200 | 0.3391 | 2,950 | 2.31 days | blocks |
| 0.99 | 0.5 | 10 | 0.1992 | 5,021 | 2.31 days | blocks |
| 0.99 | 0.5 | 60 | 0.1199 | 8,338 | 2.31 days | blocks |
| 0.99 | 0.5 | 200 | 0.0933 | 10,724 | 2.31 days | blocks |
| 0.99 | 1.0 | 10 | 0.3984 | 2,511 | 2.31 days | blocks |
| 0.99 | 1.0 | 60 | 0.2399 | 4,169 | 2.31 days | blocks |
| 0.99 | 1.0 | 200 | 0.1865 | 5,362 | 2.31 days | blocks |
| 0.99 | 1.5 | 10 | 0.5976 | 1,674 | 2.31 days | blocks |
| 0.99 | 1.5 | 60 | 0.3598 | 2,780 | 2.31 days | blocks |
| 0.99 | 1.5 | 200 | 0.2798 | 3,575 | 2.31 days | blocks |
| 0.99 | 2.0 | 10 | 0.7968 | 1,256 | 2.31 days | blocks |
| 0.99 | 2.0 | 60 | 0.4798 | 2,085 | 2.31 days | blocks |
| 0.99 | 2.0 | 200 | 0.3730 | 2,681 | 2.31 days | blocks |

## Interpretation

Without the block minimum, the worst-case whale could reach Gold in hours. The dual-criterion design (score AND blocks) enforces the 2.3-day tenure floor at the protocol level. This is the structural defense against the whale-instant-Gold attack documented in DESIGN.md.
