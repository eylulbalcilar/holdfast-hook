"""
Holdfast - Whale-Instant-Gold Mitigation Proof

Goal: Prove that the block minimum requirement at the Gold tier prevents
any high-liquidity LP ("whale") from reaching Gold faster than 2.3 days,
regardless of liquidity share, volatility, or range narrowness.

Method: Sweep whale parameter space (liquidity share, volatility,
range width). For each configuration, compute:
  - score per block
  - blocks needed to reach Gold score threshold (if no block minimum)
  - actual blocks needed under dual criteria (max of score-blocks and block-minimum)
  - which gate is binding

Pass criterion: ALL whale configurations must be blocks-gated.
If any configuration reaches Gold via score in fewer than 100,000 blocks
without the block minimum cap, the mitigation would fail without that cap.
The block minimum is the mechanism that enforces 2.3 days regardless.

Reference: DESIGN.md "Dual Tier Criteria (Score + Block Count)"
"""

import math
import csv
from pathlib import Path
from datetime import datetime, timezone


WAD = 10**18

GOLD_THRESHOLD = 1_000 * WAD
GOLD_BLOCK_MIN = 100_000

BLOCK_TIME_SECONDS = 2
GOLD_MIN_TIME_DAYS = (GOLD_BLOCK_MIN * BLOCK_TIME_SECONDS) / 86400  # 2.31 days


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
        return f"{seconds / 86400:.2f} days"


# Whale parameter sweep: extreme configurations a sophisticated attacker might try.
liquidity_shares = [0.50, 0.70, 0.90, 0.99]   # 50% to near-monopoly
volatilities     = [0.5, 1.0, 1.5, 2.0]        # medium to extreme
tick_widths      = [10, 60, 200]                # very narrow to medium


print("=" * 110)
print("WHALE-INSTANT-GOLD MITIGATION PROOF")
print("=" * 110)
print()
print(f"Gold threshold:  {GOLD_THRESHOLD:.2e} WAD-score")
print(f"Gold block min:  {GOLD_BLOCK_MIN:,} blocks ({GOLD_MIN_TIME_DAYS:.2f} days at {BLOCK_TIME_SECONDS}s/block)")
print()
print(f"{'LiqShare':<10} {'Vol':<6} {'TickW':<7} {'Score/block':<14} {'Score-only blocks':<20} {'Effective time':<18} {'Gate':<8}")
print("-" * 90)

rows = []
all_blocks_gated = True
fastest_score_only_blocks = None
fastest_config = None

for liq in liquidity_shares:
    for vol in volatilities:
        for tw in tick_widths:
            liq_wad = int(liq * WAD)
            vol_wad = int(vol * WAD)
            narrowness = range_narrowness_wad(tw)
            score = block_score_wad(liq_wad, vol_wad, narrowness)

            if score <= 0:
                continue

            score_only_blocks = math.ceil(GOLD_THRESHOLD / score)
            effective_blocks = max(score_only_blocks, GOLD_BLOCK_MIN)
            gate = "score" if score_only_blocks > GOLD_BLOCK_MIN else "blocks"

            if gate == "score":
                all_blocks_gated = False

            if fastest_score_only_blocks is None or score_only_blocks < fastest_score_only_blocks:
                fastest_score_only_blocks = score_only_blocks
                fastest_config = (liq, vol, tw, score / WAD)

            print(f"{liq:<10.2f} {vol:<6.1f} {tw:<7} {score/WAD:<14.4f} {score_only_blocks:<20,} {blocks_to_human(effective_blocks):<18} {gate:<8}")

            rows.append({
                "liquidity_share": liq,
                "volatility": vol,
                "tick_width": tw,
                "score_per_block": score / WAD,
                "score_only_blocks": score_only_blocks,
                "score_only_time": blocks_to_human(score_only_blocks),
                "effective_blocks": effective_blocks,
                "effective_time": blocks_to_human(effective_blocks),
                "gate": gate,
            })

print()
print("=" * 110)
print("RESULT")
print("=" * 110)
print()
if all_blocks_gated:
    print(f"PASS: all {len(rows)} whale configurations are blocks-gated.")
    print(f"      The block minimum ({GOLD_BLOCK_MIN:,} blocks = {GOLD_MIN_TIME_DAYS:.2f} days) is the binding")
    print(f"      constraint for every tested whale profile. Mitigation is effective.")
else:
    fail_count = sum(1 for r in rows if r["gate"] == "score")
    print(f"FAIL: {fail_count} of {len(rows)} whale configurations are score-gated.")
    print(f"      The block minimum is NOT the binding constraint for these profiles.")

print()
print("Fastest score-only path (hypothetical, without block minimum cap):")
liq, vol, tw, score_per_block = fastest_config
fastest_time_h = (fastest_score_only_blocks * BLOCK_TIME_SECONDS) / 3600
print(f"  Config: liq={liq*100:.0f}%, vol={vol}, tick_width={tw}")
print(f"  Score per block: {score_per_block:.4f}")
print(f"  Blocks to Gold threshold: {fastest_score_only_blocks:,} ({fastest_time_h:.2f} h)")
print(f"  This would reach Gold in {fastest_time_h:.2f} hours without the block minimum.")
print(f"  With the block minimum, it takes {GOLD_MIN_TIME_DAYS:.2f} days instead.")

speedup = GOLD_BLOCK_MIN / fastest_score_only_blocks
print(f"  Mitigation factor: {speedup:.1f}x slowdown for the worst-case whale.")


# ---------- File output: CSV + Markdown ----------

RESULTS_DIR = Path(__file__).parent / "results" / "whale_instant_gold"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

csv_path = RESULTS_DIR / "whale_instant_gold.csv"
with csv_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

md_path = RESULTS_DIR / "whale_instant_gold.md"
generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
with md_path.open("w") as f:
    f.write("# Whale-Instant-Gold Mitigation Proof\n\n")
    f.write(f"Generated: {generated_at}\n\n")
    f.write("Script: `scripts/sim/whale_instant_gold.py`\n\n")

    f.write("## Goal\n\n")
    f.write("Prove that the Gold tier block minimum (100,000 blocks = 2.31 days on Base) ")
    f.write("prevents any high-liquidity LP from reaching Gold faster, regardless of ")
    f.write("liquidity share, volatility, or range narrowness.\n\n")

    f.write("## Parameter sweep\n\n")
    f.write(f"- Liquidity shares: {liquidity_shares} (50% to near-monopoly)\n")
    f.write(f"- Volatility factors: {volatilities} (medium to extreme)\n")
    f.write(f"- Tick widths: {tick_widths} (very narrow to medium)\n")
    f.write(f"- Total configurations tested: {len(rows)}\n\n")

    f.write("## Result\n\n")
    if all_blocks_gated:
        f.write(f"**PASS**: all {len(rows)} whale configurations are blocks-gated. ")
        f.write("The block minimum is the binding constraint for every tested whale profile.\n\n")
    else:
        fail_count = sum(1 for r in rows if r["gate"] == "score")
        f.write(f"**FAIL**: {fail_count} of {len(rows)} whale configurations are score-gated.\n\n")

    f.write("### Worst-case whale (hypothetical, without block minimum cap)\n\n")
    liq, vol, tw, score_per_block = fastest_config
    fastest_time_h = (fastest_score_only_blocks * BLOCK_TIME_SECONDS) / 3600
    f.write(f"- Configuration: liquidity share = {liq*100:.0f}%, volatility = {vol}, tick width = {tw}\n")
    f.write(f"- Score per block: {score_per_block:.4f}\n")
    f.write(f"- Blocks to Gold threshold (score only): {fastest_score_only_blocks:,} (~{fastest_time_h:.2f} hours)\n")
    f.write(f"- Effective time under dual criteria: {GOLD_MIN_TIME_DAYS:.2f} days\n")
    f.write(f"- Mitigation factor: {GOLD_BLOCK_MIN / fastest_score_only_blocks:.1f}x slowdown\n\n")

    f.write("## Full results\n\n")
    f.write("| Liq share | Vol | Tick width | Score/block | Score-only blocks | Effective time | Gate |\n")
    f.write("|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['liquidity_share']:.2f} | {r['volatility']:.1f} | {r['tick_width']} | "
                f"{r['score_per_block']:.4f} | {r['score_only_blocks']:,} | {r['effective_time']} | {r['gate']} |\n")

    f.write("\n## Interpretation\n\n")
    f.write("Without the block minimum, the worst-case whale could reach Gold in hours. ")
    f.write("The dual-criterion design (score AND blocks) enforces the 2.3-day tenure floor ")
    f.write("at the protocol level. This is the structural defense against the whale-instant-Gold ")
    f.write("attack documented in DESIGN.md.\n")

print()
print(f"Results written:")
print(f"  {csv_path}")
print(f"  {md_path}")
