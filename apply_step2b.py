#!/usr/bin/env python3
"""Step 2b: fix stack-too-deep from the Step 2 _readStreak body. Revert to a
forwarding return and widen the signature to 11 fields; extend its callers."""

import sys

PATH = "test/unit/HoldfastHookAddLiquidity.t.sol"

EDITS = [
    ("        (\n            accumulatedScore,\n            lastUpdateBlock,\n            lastGlobalScoreSnapshot,\n            firstActiveBlock,\n            entrySqrtPriceX96,\n            currentTier,\n            nftTokenId,\n            frozenAt,\n            isActive,\n            realizedIL,\n        ) = harness.streaks(key);\n",
     "        return harness.streaks(key);\n", 1),
    ("            bool isActive,\n            int256 realizedIL\n        )",
     "            bool isActive,\n            int256 realizedIL,\n            uint128 liquidity\n        )", 1),
    ("            bool isActive,\n            \n        ) = _readStreak(key);",
     "            bool isActive,\n            ,\n            \n        ) = _readStreak(key);", 2),
    ("(,,, uint256 firstActiveBlockBefore, uint160 entryBefore,,,,,) = _readStreak(key);",
     "(,,, uint256 firstActiveBlockBefore, uint160 entryBefore,,,,,,) = _readStreak(key);", 1),
    ("(,,, uint256 fab1,,,,,,) = _readStreak(k1);",
     "(,,, uint256 fab1,,,,,,,) = _readStreak(k1);", 2),
    ("(,,, uint256 fab2,,,,,,) = _readStreak(k2);",
     "(,,, uint256 fab2,,,,,,,) = _readStreak(k2);", 2),
]

def main():
    with open(PATH, "r", encoding="utf-8") as fh:
        content = fh.read()
    failures = []
    for old, new, expected in EDITS:
        count = content.count(old)
        if count != expected:
            failures.append(f"expected {expected}, found {count}: {old[:60]!r}")
            continue
        content = content.replace(old, new)
        print(f"patched ({expected}): {old[:60]!r}")
    if failures:
        print("\nFAILED, file not written:")
        for f in failures:
            print(f"  - {f}")
        return 1
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(content)
    print("\nStep 2b applied successfully.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
