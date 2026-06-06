#!/usr/bin/env python3
"""Steps 3-6: track streak.liquidity in add/remove and settle against it
instead of PoolManager.getPositionLiquidity (which is keyed by msg.sender)."""

import sys

PATH = "src/HoldfastHook.sol"

EDITS = [
    # Step 5: settle in beforeRemoveLiquidity uses internal tracked liquidity.
    ("""        {
            uint128 liq = poolManager.getPositionLiquidity(key.toId(), positionKey);
            uint256 narrowness = ScoreAccumulator.calculateRangeNarrowness(params.tickLower, params.tickUpper);
            _settlePositionScore(positionKey, key.toId(), liq, narrowness);
        }""",
     """        {
            uint256 narrowness = ScoreAccumulator.calculateRangeNarrowness(params.tickLower, params.tickUpper);
            _settlePositionScore(positionKey, key.toId(), s.liquidity, narrowness);
        }""",
     1),
    # Step 3: cold-init path tracks initial liquidity.
    ("""            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;

            emit PositionOpened(
                positionKey,
                owner,
                key.toId(),
                params.tickLower,
                params.tickUpper,
                sqrtPriceX96,
                block.number
            );
        } else if (!s.isActive && s.frozenAt > 0) {""",
     """            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;
            s.liquidity += uint128(uint256(params.liquidityDelta));

            emit PositionOpened(
                positionKey,
                owner,
                key.toId(),
                params.tickLower,
                params.tickUpper,
                sqrtPriceX96,
                block.number
            );
        } else if (!s.isActive && s.frozenAt > 0) {""",
     1),
    # Step 3: re-entry path tracks liquidity.
    ("""            s.frozenAt = 0;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;

            emit PositionOpened(""",
     """            s.frozenAt = 0;
            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.isActive = true;
            s.liquidity += uint128(uint256(params.liquidityDelta));

            emit PositionOpened(""",
     1),
    # Step 3: increase-on-active path tracks added liquidity.
    ("""            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.lastUpdateBlock = block.number;
        }

        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));""",
     """            s.lastGlobalScoreSnapshot = globalScorePerLiquidity[key.toId()];
            s.lastUpdateBlock = block.number;
            s.liquidity += uint128(uint256(params.liquidityDelta));
        }

        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));""",
     1),
    # Step 4: decrement tracked liquidity in afterRemoveLiquidity (clamp to avoid
    # underflow when the tracked value lags PoolManager's view), then use the
    # internal value for full-closure detection instead of getPositionLiquidity.
    ("""        // Authoritative residual liquidity read from PoolManager.
        uint128 remaining = poolManager.getPositionLiquidity(key.toId(), positionKey);

        if (remaining == 0) {""",
     """        // Decrement internal tracked liquidity (clamped) and use it for closure
        // detection. PoolManager's view is keyed by msg.sender (the router), not by
        // the hookData owner, so it cannot be relied on here.
        uint128 removed = uint128(uint256(-params.liquidityDelta));
        s.liquidity = removed >= s.liquidity ? 0 : s.liquidity - removed;
        uint128 remaining = s.liquidity;

        if (remaining == 0) {""",
     1),
]

def main():
    with open(PATH, "r", encoding="utf-8") as fh:
        content = fh.read()
    failures = []
    for old, new, expected in EDITS:
        count = content.count(old)
        if count != expected:
            failures.append(f"expected {expected}, found {count}: {old[:70]!r}")
            continue
        content = content.replace(old, new)
        print(f"patched ({expected}): {old[:55]!r}")
    if failures:
        print("\nFAILED, file not written:")
        for f in failures:
            print(f"  - {f}")
        return 1
    with open(PATH, "w", encoding="utf-8") as fh:
        fh.write(content)
    print("\nStep 3-6 applied.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
