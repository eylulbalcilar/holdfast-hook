#!/usr/bin/env python3
"""Step 2: append `liquidity` to PositionStreak and fix every positional
streaks(...) read. The typed _readStreak helper keeps its 10-field signature by
dropping the new 11th value in its body, so its callers do not change."""

import sys

EDITS = [
    ("src/HoldfastHook.sol",
     "        int256 realizedIL;\n    }",
     "        int256 realizedIL;\n        uint128 liquidity; // internally tracked from params.liquidityDelta; settle reads this, not PoolManager's msg.sender-keyed view\n    }",
     1),
    ("test/integration/HoldfastHookNaturalAccrual.t.sol",
     "(s,,,,,,,,,) = harness.streaks(key);",
     "(s,,,,,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/Accumulator.t.sol",
     "(s,,,,,,,,,) = harness.streaks(key);",
     "(s,,,,,,,,,,) = harness.streaks(key);", 1),
    ("test/fork/HoldfastHookClaimFlow.fork.t.sol",
     "(uint256 accScore,,,,,,,,,) = harness.streaks(positionKey);",
     "(uint256 accScore,,,,,,,,,,) = harness.streaks(positionKey);", 2),
    ("test/unit/HoldfastHookSecurity.t.sol",
     "(,,,,, tier,,,,) = harness.streaks(positionKey);",
     "(,,,,, tier,,,,,) = harness.streaks(positionKey);", 1),
    ("test/unit/HoldfastHookSecurity.t.sol",
     "(,,,,,, tokenId,,,) = harness.streaks(positionKey);",
     "(,,,,,, tokenId,,,,) = harness.streaks(positionKey);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,,,,,,,, il) = harness.streaks(key);",
     "(,,,,,,,,, il,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,,,, tier,,,,) = harness.streaks(key);",
     "(,,,,, tier,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,,,,,,, active,) = harness.streaks(key);",
     "(,,,,,,,, active,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,,,,,, frozenAt,,) = harness.streaks(key);",
     "(,,,,,,, frozenAt,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(score,,,,,,,,,) = harness.streaks(key);",
     "(score,,,,,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,,, entry,,,,,) = harness.streaks(key);",
     "(,,,, entry,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(,,, fab,,,,,,) = harness.streaks(key);",
     "(,,, fab,,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookRemoveLiquidity.t.sol",
     "(, lub,,,,,,,,) = harness.streaks(key);",
     "(, lub,,,,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookAttackVectors.t.sol",
     "(score,,,,,,,,,) = harness.streaks(key);",
     "(score,,,,,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookAttackVectors.t.sol",
     "(,,,, entry,,,,,) = harness.streaks(key);",
     "(,,,, entry,,,,,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookAttackVectors.t.sol",
     "(,,,,,,,, active,) = harness.streaks(key);",
     "(,,,,,,,, active,,) = harness.streaks(key);", 1),
    ("test/unit/HoldfastHookAddLiquidity.t.sol",
     "        return harness.streaks(key);\n",
     "        (\n            accumulatedScore,\n            lastUpdateBlock,\n            lastGlobalScoreSnapshot,\n            firstActiveBlock,\n            entrySqrtPriceX96,\n            currentTier,\n            nftTokenId,\n            frozenAt,\n            isActive,\n            realizedIL,\n        ) = harness.streaks(key);\n",
     1),
]

def main():
    failures = []
    for path, old, new, expected in EDITS:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                content = fh.read()
        except FileNotFoundError:
            failures.append(f"{path}: file not found")
            continue
        count = content.count(old)
        if count != expected:
            failures.append(f"{path}: expected {expected}, found {count}")
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content.replace(old, new))
        print(f"patched {path} ({expected})")
    if failures:
        print("\nFAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nAll Step 2 edits applied.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
