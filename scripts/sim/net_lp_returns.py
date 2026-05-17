"""
Holdfast - Net LP Returns Comparison

Goal: Validate the "Net LP Returns" table in DESIGN.md with explicit
month-over-month dollar figures, comparing standard pool baseline vs
Holdfast across LP profiles.

Includes Aave V3 supply yield contribution on the bonus pool (idle yield).

Scenario:
  - Monthly swap volume: $1,000,000
  - Pool fee: 0.30%
  - Redistribution rate: 15%
  - Average volatility multiplier: 1.2x
  - Aave V3 USDC supply APY (testnet estimate): 3%
  - LP holds 10% of pool liquidity (baseline comparison)

Tier weights (DESIGN.md):
  - Gold:   40%
  - Silver: 35%
  - Bronze: 25%

Bonus pool split:
  - Tier-weighted arm: 70%
  - Realized-IL arm:   30% (excluded from this sim; IL is path-dependent)

Reference: DESIGN.md "Net LP Returns" section
"""

import csv
from pathlib import Path
from datetime import datetime, timezone


# ---------- Parameters ----------

MONTHLY_VOLUME = 1_000_000
POOL_FEE_RATE = 0.0030
REDISTRIBUTION_RATE = 0.15
VOLATILITY_MULTIPLIER = 1.2
AAVE_APY = 0.03
LP_POOL_SHARE = 0.10

# Bonus pool tier weights
TIER_WEIGHT = {"Bronze": 0.25, "Silver": 0.35, "Gold": 0.40}

# Bonus pool split
TIER_ARM_FRACTION = 0.70   # IL arm gets 0.30, excluded here


# ---------- Derived totals ----------

total_fees = MONTHLY_VOLUME * POOL_FEE_RATE
lp_direct_pool = total_fees * (1 - REDISTRIBUTION_RATE)
bonus_pool_base = total_fees * REDISTRIBUTION_RATE * VOLATILITY_MULTIPLIER

# Aave yield on bonus pool: average idle balance over the month earns APY/12
# Approximation: bonus pool accrues linearly, so average balance is half of final.
aave_yield_on_bonus = bonus_pool_base * 0.5 * (AAVE_APY / 12)
bonus_pool_total = bonus_pool_base + aave_yield_on_bonus

tier_arm = bonus_pool_total * TIER_ARM_FRACTION


# ---------- LP profiles ----------
# intra_tier_share: fraction of this LP's score relative to sum of all scores in its tier

profiles = [
    {"name": "Mercenary (no tier)",       "tier": None,     "intra_tier_share": 0.00},
    {"name": "Bronze (1 of 50, 2%)",      "tier": "Bronze", "intra_tier_share": 0.02},
    {"name": "Silver (1 of 10, 10%)",     "tier": "Silver", "intra_tier_share": 0.10},
    {"name": "Silver (1 of 3, 30%)",      "tier": "Silver", "intra_tier_share": 0.30},
    {"name": "Gold (1 of 3, 30%)",        "tier": "Gold",   "intra_tier_share": 0.30},
]


def compute_row(profile):
    standard = total_fees * LP_POOL_SHARE
    direct = lp_direct_pool * LP_POOL_SHARE

    if profile["tier"] is None:
        bonus = 0.0
        aave_contrib = 0.0
    else:
        tier_w = TIER_WEIGHT[profile["tier"]]
        share = profile["intra_tier_share"]
        # tier allocation = tier_arm * tier_w; user gets share of that
        bonus = tier_arm * tier_w * share
        # Aave portion of that user's bonus (for visibility)
        aave_contrib = (aave_yield_on_bonus * TIER_ARM_FRACTION) * tier_w * share

    holdfast_total = direct + bonus
    delta = holdfast_total - standard
    delta_pct = (delta / standard) * 100 if standard > 0 else 0.0

    return {
        "profile": profile["name"],
        "tier": profile["tier"] or "none",
        "intra_tier_share": profile["intra_tier_share"],
        "standard_pool_usd": round(standard, 2),
        "holdfast_direct_usd": round(direct, 2),
        "holdfast_bonus_usd": round(bonus, 4),
        "aave_contribution_usd": round(aave_contrib, 4),
        "holdfast_total_usd": round(holdfast_total, 2),
        "delta_usd": round(delta, 2),
        "delta_pct": round(delta_pct, 2),
    }


rows = [compute_row(p) for p in profiles]


# ---------- Console output ----------

print("=" * 100)
print("HOLDFAST NET LP RETURNS")
print("=" * 100)
print()
print(f"Monthly volume:        ${MONTHLY_VOLUME:,}")
print(f"Pool fee rate:         {POOL_FEE_RATE*100:.2f}%")
print(f"Redistribution rate:   {REDISTRIBUTION_RATE*100:.0f}%")
print(f"Volatility multiplier: {VOLATILITY_MULTIPLIER}x")
print(f"Aave supply APY:       {AAVE_APY*100:.1f}%")
print(f"LP pool share:         {LP_POOL_SHARE*100:.0f}%")
print()
print(f"Total swapper fees:      ${total_fees:,.2f}")
print(f"LP direct pool (85%):    ${lp_direct_pool:,.2f}")
print(f"Bonus pool (base 15%):   ${bonus_pool_base:,.2f}")
print(f"Aave yield on bonus:     ${aave_yield_on_bonus:,.4f}  (monthly, avg-balance approx)")
print(f"Bonus pool (total):      ${bonus_pool_total:,.2f}")
print(f"Tier-weighted arm (70%): ${tier_arm:,.2f}")
print()
print(f"{'Profile':<28} {'Standard':<12} {'Direct':<10} {'Bonus':<10} {'Total':<10} {'Delta':<10} {'Delta %':<8}")
print("-" * 100)
for r in rows:
    print(f"{r['profile']:<28} "
          f"${r['standard_pool_usd']:<10.2f} "
          f"${r['holdfast_direct_usd']:<8.2f} "
          f"${r['holdfast_bonus_usd']:<8.2f} "
          f"${r['holdfast_total_usd']:<8.2f} "
          f"{r['delta_usd']:+<9.2f} "
          f"{r['delta_pct']:+.2f}%")

print()
print("=" * 100)
print("INTERPRETATION")
print("=" * 100)
print("""
- Standard pool: LP gets full fee share (no Holdfast).
- Holdfast Direct: 85% of fees, distributed pro-rata as in standard pool.
- Holdfast Bonus: pro-rata share of tier-weighted arm of bonus pool (70% of bonus pool).
- Aave contribution: portion of bonus attributable to Aave V3 supply yield while idle.
- Realized-IL arm (30%) is excluded; it depends on actual price path.

Loyal high-tier LPs with significant intra-tier share outperform standard pool.
Mercenary LPs experience designed retention penalty (-15%).
Aave yield contribution is small at testnet APYs but grows linearly with pool TVL and APY.
""")


# ---------- File output ----------

RESULTS_DIR = Path(__file__).parent / "results" / "net_lp_returns"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

csv_path = RESULTS_DIR / "net_lp_returns.csv"
with csv_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

md_path = RESULTS_DIR / "net_lp_returns.md"
generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
with md_path.open("w") as f:
    f.write("# Net LP Returns Comparison\n\n")
    f.write(f"Generated: {generated_at}\n\n")
    f.write("Script: `scripts/sim/net_lp_returns.py`\n\n")

    f.write("## Scenario parameters\n\n")
    f.write(f"- Monthly swap volume: ${MONTHLY_VOLUME:,}\n")
    f.write(f"- Pool fee rate: {POOL_FEE_RATE*100:.2f}%\n")
    f.write(f"- Redistribution rate: {REDISTRIBUTION_RATE*100:.0f}%\n")
    f.write(f"- Volatility multiplier: {VOLATILITY_MULTIPLIER}x\n")
    f.write(f"- Aave V3 USDC supply APY (testnet estimate): {AAVE_APY*100:.1f}%\n")
    f.write(f"- LP pool share for comparison: {LP_POOL_SHARE*100:.0f}%\n\n")

    f.write("## Pool-level totals\n\n")
    f.write(f"- Total swapper fees: ${total_fees:,.2f}\n")
    f.write(f"- LP direct pool (85% of fees): ${lp_direct_pool:,.2f}\n")
    f.write(f"- Bonus pool base (15% × 1.2x vol mult): ${bonus_pool_base:,.2f}\n")
    f.write(f"- Aave yield on bonus pool (monthly, avg-balance approx): ${aave_yield_on_bonus:,.4f}\n")
    f.write(f"- Bonus pool total: ${bonus_pool_total:,.2f}\n")
    f.write(f"- Tier-weighted arm (70% of bonus): ${tier_arm:,.2f}\n")
    f.write(f"- Realized-IL arm (30% of bonus): excluded from this sim (path-dependent)\n\n")

    f.write("## Per-LP comparison\n\n")
    f.write("| Profile | Standard pool | Holdfast direct | Holdfast bonus | Holdfast total | Delta $ | Delta % |\n")
    f.write("|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['profile']} | "
                f"${r['standard_pool_usd']:.2f} | "
                f"${r['holdfast_direct_usd']:.2f} | "
                f"${r['holdfast_bonus_usd']:.2f} | "
                f"${r['holdfast_total_usd']:.2f} | "
                f"{r['delta_usd']:+.2f} | "
                f"{r['delta_pct']:+.2f}% |\n")

    f.write("\n## Aave yield contribution (transparency)\n\n")
    f.write("| Profile | Bonus total $ | Aave portion $ | Aave % of bonus |\n")
    f.write("|---|---|---|---|\n")
    for r in rows:
        if r["holdfast_bonus_usd"] > 0:
            aave_pct = (r["aave_contribution_usd"] / r["holdfast_bonus_usd"]) * 100
        else:
            aave_pct = 0.0
        f.write(f"| {r['profile']} | ${r['holdfast_bonus_usd']:.4f} | ${r['aave_contribution_usd']:.4f} | {aave_pct:.2f}% |\n")

    f.write("\n## Interpretation\n\n")
    f.write("- Loyal high-tier LPs with significant intra-tier share outperform the standard pool.\n")
    f.write("- Mercenary LPs experience the designed retention penalty of ~-15%.\n")
    f.write("- Aave supply yield on the bonus pool is small at testnet APYs but scales with TVL and APY.\n")
    f.write("- The realized-IL arm (30% of bonus pool) is excluded here because it depends on the actual price path; it is sanity-checked separately in `realized_il_check.py`.\n")

print(f"Results written:")
print(f"  {csv_path}")
print(f"  {md_path}")
