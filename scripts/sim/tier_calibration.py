"""
Holdfast - Tier Calibration Simulation (WAD scale, calibrated thresholds)

Score formula (WAD-scaled):
    blockScore = (liquidityShare * volatilityFactor * rangeNarrowness) / WAD^2

Tier thresholds (calibrated so medium LP reaches Bronze in ~33 min):
    Bronze: 10 * 1e18 = 1e19
    Silver: 100 * 1e18 = 1e20
    Gold: 1,000 * 1e18 = 1e21

Minimum active blocks (unchanged, prevents whale-instant-Gold):
    Bronze: 1,000 blocks (~33 min)
    Silver: 10,000 blocks (~5.6 h)
    Gold: 100,000 blocks (~2.3 days)

Base Sepolia: 2 second block time
"""

import math
import csv
from pathlib import Path
from datetime import datetime, timezone


WAD = 10**18

TIER_THRESHOLDS = {
    "Bronze": 10 * WAD,
    "Silver": 100 * WAD,
    "Gold": 1_000 * WAD,
}

TIER_BLOCK_MIN = {
    "Bronze": 1_000,
    "Silver": 10_000,
    "Gold": 100_000,
}

BLOCK_TIME_SECONDS = 2


def range_narrowness_wad(tick_width: int) -> int:
    return int(WAD / math.log(tick_width + 2))


def block_score_wad(liquidity_share_wad: int, volatility_wad: int, narrowness_wad: int) -> int:
    return (liquidity_share_wad * volatility_wad * narrowness_wad) // (WAD * WAD)


def blocks_to_human(blocks: int) -> str:
    seconds = blocks * BLOCK_TIME_SECONDS
    if seconds < 3600:
        return f"{seconds / 60:.1f} min"
    elif seconds < 48 * 3600:
        return f"{seconds / 3600:.1f} h"
    else:
        return f"{seconds / 86400:.1f} days"


def resolve_tier(score_per_block: int, threshold: int, block_min: int):
    if score_per_block <= 0:
        return ("never", "none", 0)
    score_blocks = math.ceil(threshold / score_per_block)
    effective = max(score_blocks, block_min)
    gate = "score" if score_blocks > block_min else "blocks"
    return (blocks_to_human(effective), gate, effective)


scenarios = [
    {
        "name": "Small LP (2%), narrow range, low vol",
        "liquidity_share": int(0.02 * WAD),
        "volatility": int(0.3 * WAD),
        "tick_width": 60,
    },
    {
        "name": "Small LP (2%), narrow range, high vol",
        "liquidity_share": int(0.02 * WAD),
        "volatility": int(1.0 * WAD),
        "tick_width": 60,
    },
    {
        "name": "Medium LP (10%), medium range, medium vol",
        "liquidity_share": int(0.10 * WAD),
        "volatility": int(0.6 * WAD),
        "tick_width": 200,
    },
    {
        "name": "Large LP (30%), wide range, low vol",
        "liquidity_share": int(0.30 * WAD),
        "volatility": int(0.3 * WAD),
        "tick_width": 1000,
    },
    {
        "name": "Whale (50%), narrow range, high vol",
        "liquidity_share": int(0.50 * WAD),
        "volatility": int(1.0 * WAD),
        "tick_width": 60,
    },
    {
        "name": "Baseline (all factors = 1.0)",
        "liquidity_share": WAD,
        "volatility": WAD,
        "tick_width": 1,
    },
]


# ---------- Console output ----------

print("=" * 110)
print("HOLDFAST TIER CALIBRATION (WAD scale, calibrated thresholds)")
print("=" * 110)
print()
print(f"Block time: {BLOCK_TIME_SECONDS}s (Base Sepolia)")
print(f"Bronze: {TIER_THRESHOLDS['Bronze']:.2e} score / min {TIER_BLOCK_MIN['Bronze']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Bronze'])})")
print(f"Silver: {TIER_THRESHOLDS['Silver']:.2e} score / min {TIER_BLOCK_MIN['Silver']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Silver'])})")
print(f"Gold:   {TIER_THRESHOLDS['Gold']:.2e} score / min {TIER_BLOCK_MIN['Gold']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Gold'])})")
print()
print(f"{'Scenario':<50} {'Score/block':<14} {'Bronze':<20} {'Silver':<20} {'Gold':<20}")
print("-" * 124)

rows = []
for s in scenarios:
    narrowness = range_narrowness_wad(s["tick_width"])
    score = block_score_wad(s["liquidity_share"], s["volatility"], narrowness)
    bronze_time, bronze_gate, bronze_blocks = resolve_tier(score, TIER_THRESHOLDS["Bronze"], TIER_BLOCK_MIN["Bronze"])
    silver_time, silver_gate, silver_blocks = resolve_tier(score, TIER_THRESHOLDS["Silver"], TIER_BLOCK_MIN["Silver"])
    gold_time,   gold_gate,   gold_blocks   = resolve_tier(score, TIER_THRESHOLDS["Gold"],   TIER_BLOCK_MIN["Gold"])

    score_display = f"{score / WAD:.4f}"
    bronze_display = f"{bronze_time} ({bronze_gate})"
    silver_display = f"{silver_time} ({silver_gate})"
    gold_display   = f"{gold_time} ({gold_gate})"
    print(f"{s['name']:<50} {score_display:<14} {bronze_display:<20} {silver_display:<20} {gold_display:<20}")

    rows.append({
        "scenario": s["name"],
        "liquidity_share": s["liquidity_share"] / WAD,
        "volatility": s["volatility"] / WAD,
        "tick_width": s["tick_width"],
        "score_per_block": score / WAD,
        "bronze_time": bronze_time, "bronze_gate": bronze_gate, "bronze_blocks": bronze_blocks,
        "silver_time": silver_time, "silver_gate": silver_gate, "silver_blocks": silver_blocks,
        "gold_time":   gold_time,   "gold_gate":   gold_gate,   "gold_blocks":   gold_blocks,
    })

print()
print("=" * 110)
print("INTERPRETATION")
print("=" * 110)
print("""
Tier qualification requires BOTH:
  1. Cumulative accumulated score >= threshold
  2. Active blocks >= minimum

(score)  = score-gated, threshold takes longer than block minimum (typical for small/inactive LPs)
(blocks) = blocks-gated, block minimum takes longer than score (mitigation against whale-instant-Gold)

Calibration check:
  - Medium LP should reach Bronze around 33 min (blocks-gated, baseline retention signal)
  - Whales should be blocks-gated at Gold (cannot bypass tenure with high liquidity)
  - Small LPs may be score-gated at higher tiers (acceptable, they need consistent participation)
""")


# ---------- File output: CSV + Markdown ----------

RESULTS_DIR = Path(__file__).parent / "results" / "tier_calibration"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

csv_path = RESULTS_DIR / "tier_calibration.csv"
with csv_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

md_path = RESULTS_DIR / "tier_calibration.md"
generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
with md_path.open("w") as f:
    f.write("# Tier Calibration Results\n\n")
    f.write(f"Generated: {generated_at}\n\n")
    f.write("Script: `scripts/sim/tier_calibration.py`\n\n")
    f.write("## Parameters\n\n")
    f.write(f"- Block time: {BLOCK_TIME_SECONDS}s (Base Sepolia)\n")
    f.write(f"- Bronze threshold: {TIER_THRESHOLDS['Bronze']:.2e} WAD-score / min {TIER_BLOCK_MIN['Bronze']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Bronze'])})\n")
    f.write(f"- Silver threshold: {TIER_THRESHOLDS['Silver']:.2e} WAD-score / min {TIER_BLOCK_MIN['Silver']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Silver'])})\n")
    f.write(f"- Gold threshold:   {TIER_THRESHOLDS['Gold']:.2e} WAD-score / min {TIER_BLOCK_MIN['Gold']:,} blocks ({blocks_to_human(TIER_BLOCK_MIN['Gold'])})\n\n")
    f.write("## Results\n\n")
    f.write("| Scenario | Score/block | Bronze | Silver | Gold |\n")
    f.write("|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['scenario']} | {r['score_per_block']:.4f} | {r['bronze_time']} ({r['bronze_gate']}) | {r['silver_time']} ({r['silver_gate']}) | {r['gold_time']} ({r['gold_gate']}) |\n")
    f.write("\n## Gating legend\n\n")
    f.write("- **(blocks)**: block minimum is the binding constraint (mitigation against whale-instant-Gold)\n")
    f.write("- **(score)**: score threshold is the binding constraint (small/inactive LPs)\n\n")
    f.write("## Calibration check\n\n")
    f.write("- Medium LP (10%, 200-tick range, medium vol) reaches Bronze in ~33 min, blocks-gated\n")
    f.write("- Whale (50%, narrow range, high vol) reaches Gold in ~2.3 days, blocks-gated (mitigation working)\n")
    f.write("- Small LPs (2% share) are score-gated at higher tiers, by design\n")

print(f"Results written:")
print(f"  {csv_path}")
print(f"  {md_path}")
