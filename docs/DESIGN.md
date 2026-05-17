# Holdfast

A Uniswap v4 hook that measures IL exposure, partially compensates realized impermanent loss, and compounds rewards through Aave V3.

UHI9 Capstone Project · Base Sepolia

## Overview

Holdfast is a Uniswap v4 hook designed for volatile pair pools. It addresses the mercenary capital problem in concentrated liquidity provisioning by combining four mechanisms:

1. **Risk-weighted scoring:** each LP position accumulates a score based on liquidity share, range narrowness, and pool volatility
2. **Partial IL compensation:** realized impermanent loss is computed at claim time, and a portion of the bonus pool is distributed proportionally to IL incurred
3. **Tier-based retention rewards:** Bronze, Silver, and Gold tiers gate access to bonus pool shares
4. **Yield compounding via Aave V3:** bonus pool funds are supplied to Aave V3 while idle, generating additional yield

**Honest positioning.** Holdfast is not a full IL hedge. It does not eliminate impermanent loss. It measures IL exposure, partially compensates realized IL from a bonus pool, and provides retention incentives for LPs who stay through high-volatility periods. Full IL hedging requires options primitives or external hedging infrastructure, which is out of scope.

**Fee model.** Holdfast does not charge swappers any additional fee. A fixed portion (`redistributionRate`, default 15%) of the existing pool fee is redirected to the bonus pool. Swap costs remain unchanged. Tier-qualified LPs recover the redistributed amount through bonus pool shares; non-qualified (mercenary) LPs experience reduced direct fee income, which functions as a structural retention incentive.

## UHI9 Theme Alignment

UHI9 theme: "Impermanent Loss and Yield Systems"

| Theme criterion | Holdfast mechanism |
|---|---|
| Impermanent Loss measurement | Score formula incorporates IL proxy (volatility × range narrowness × liquidity share) |
| IL compensation | Realized-IL arm distributes 30% of bonus pool proportional to actual IL incurred |
| Yield Systems | Fee redistribution + Aave V3 supply yield (genuine composability) |
| Protection mechanism | Risk-weighted retention through tier system and volatility-aware multipliers |

## Architecture

```
            ┌──────────────────┐
            │  HoldfastHook    │
            │  (v4 lifecycle)  │
            └────────┬─────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
┌──────────────┐ ┌─────────┐ ┌────────────┐
│ScoreAccumul. │ │HoldfastNFT│ │YieldRouter │
│  (library)   │ │ (ERC-721) │ │ (Aave V3)  │
└──────────────┘ └─────────┘ └─────┬──────┘
                                   │
                                   ▼
                          ┌─────────────────┐
                          │  Aave V3 Pool   │
                          │ (Base Sepolia)  │
                          └─────────────────┘
```

### Contracts

1. **HoldfastHook.sol**: v4 lifecycle integration (beforeInitialize, afterAddLiquidity, beforeSwap, afterSwap, afterRemoveLiquidity)
2. **HoldfastNFT.sol**: ERC-721 with mutable metadata, IPFS pointers for three static tier images
3. **ScoreAccumulator.sol**: Pure library for score calculation and realized IL math
4. **YieldRouter.sol**: Aave V3 supply/withdraw operations, aToken accounting

## Mechanics

### Score Formula

Per position, per block:

```
blockScore = liquidityShare × volatilityFactor × rangeNarrowness
```

Where:

- `liquidityShare`: position's share of pool liquidity, linear in range 0 to 1
- `volatilityFactor`: variance of the last 10 swap prices, computed from pool state, no oracle
- `rangeNarrowness`: `1 / log(tickUpper - tickLower + 2)`, narrow ranges receive higher coefficients, logarithmically bounded

If a position is out of range, score accumulation pauses but does not reset. The position retains its accumulated score and resumes when back in range.

### Realized IL Computation

When a position is opened, `entrySqrtPriceX96` is snapshotted. At claim time or position closure, realized IL is computed using the standard formula:

```
priceRatio = (currentSqrtPrice / entrySqrtPrice)²
IL = 2 × sqrt(priceRatio) / (1 + priceRatio) - 1
```

IL is negative (representing loss). The realized-IL arm distributes its allocation proportional to the absolute value of IL incurred, across all active positions that have non-zero IL.

### Tier Thresholds

Tiers require both a cumulative score threshold AND a minimum active block count. Both conditions must be satisfied for tier qualification. Score values are WAD-scaled (multiplied by 1e18) to match Solidity fixed-point conventions.

| Tier | Score threshold (WAD) | Minimum active blocks |
|---|---|---|
| Bronze | 10 × 1e18 | 1,000 (~33 min on Base) |
| Silver | 100 × 1e18 | 10,000 (~5.6 hours) |
| Gold | 1,000 × 1e18 | 100,000 (~2.3 days) |

The dual-criterion design prevents whales from instantly reaching Gold through high liquidity (a high-liquidity position could otherwise accumulate the score threshold in minutes), while linear `liquidityShare` in the score formula prevents sybil split attacks.

Threshold values were calibrated via Python simulation (`scripts/sim/tier_calibration.py`). Calibration results:
- Medium LP (10% pool share, medium volatility, 200-tick range) reaches Bronze in 33 min (blocks-gated)
- Whale (50% pool share, narrow range, high volatility) reaches Gold in 2.3 days (blocks-gated, mitigation working)
- Small LPs (2% pool share) are score-gated at higher tiers (acceptable design: requires consistent participation)

### Bonus Pool Source and Distribution

Bonus pool funding:

```
swapperPays:    poolFee (unchanged from baseline)
lpDirect:       poolFee × (1 - redistributionRate)
bonusPoolAdd:   poolFee × redistributionRate × volatilityMultiplier
```

Where:

- `redistributionRate`: 15% (configurable, set per-pool at initialization)
- `volatilityMultiplier`: 1.0x to 1.5x based on current volatilityFactor

Bonus pool funds are supplied to Aave V3 (USDC denomination), earning aToken yield while idle.

At claim time, the bonus pool (direct redistribution + accrued Aave yield) is distributed in two arms:

**Tier-weighted arm (70%)**

Tier weight allocation:

- Gold: 40%
- Silver: 35%
- Bronze: 25%

Within each tier, distribution is pro-rata based on the user's lifetime accumulated score relative to the sum of all scores within that tier.

```
userTierShare = (tierAllocation) × (userScore / sumOfTierScores)
```

**Realized-IL arm (30%)**

Distributed proportionally to absolute realized IL across all positions that incurred IL. Tier-independent: any qualified LP with non-zero IL participates.

```
userILShare = (ilArmAllocation) × (|userIL| / sumOfAllIL)
```

### NFT Mechanics

When a position first crosses Bronze threshold, an NFT is minted. Subsequent tier upgrades update the same tokenId's metadata pointer; new tokens are not minted on upgrade. The `_beforeTokenTransfer` override settles accrued rewards to the original owner before transfer.

NFT serves as a claim accounting primitive: tier indicator, per-position isolated state, and transfer-time settlement hook. ERC-721 transferability is preserved as a standard property but is not the primary design intent.

### Position Lifecycle

- **Full closure:** streak freezes, NFT tier persists (no downgrade), score accumulation stops, realized IL is computed at closure
- **Partial closure:** liquidityShare recalculated, score accumulation rate adjusts accordingly
- **Re-entry:** if the same owner re-opens a position with matching parameters, the existing NFT's streak resumes, but `entrySqrtPriceX96` is reset to establish a new IL baseline

## State

```solidity
struct PositionStreak {
    uint256 accumulatedScore;       // lifetime, used for tier qualification and pro-rata
    uint256 lastUpdateBlock;
    uint256 firstActiveBlock;       // for tier minimum tenure check
    uint160 entrySqrtPriceX96;      // realized IL baseline
    uint8 currentTier;              // 0=none, 1=bronze, 2=silver, 3=gold
    uint256 nftTokenId;
    uint128 frozenAt;
    bool isActive;
}

mapping(bytes32 => PositionStreak) public streaks;

struct PoolVolatility {
    uint256[10] recentPriceObservations;
    uint8 cursor;
    uint256 cachedVolatility;
    uint256 lastVolUpdate;
}

mapping(PoolId => PoolVolatility) public volatility;
```

Position key derivation:

```solidity
positionKey = keccak256(abi.encode(owner, tickLower, tickUpper, salt))
```

## Gas Optimization: Lazy Update Pattern

The hook uses a Curve gauge-style accumulator. A single pool-level `scorePerLiquidity` variable is incremented on each swap. Per-position scores are computed only on user interaction (add, remove, claim):

```
userScore += liquidity × (globalScore_now - globalScore_atLastUpdate)
```

This avoids iterating over all active positions on each swap. Realized IL is also lazy: computed only at claim or closure, not on every swap.

## Design Decisions

### Oracle-Free Volatility

Volatility is derived from the pool's own swap pattern via a 10-observation ring buffer. No Chainlink, no Pyth.

Rationale:

- Self-contained hook, minimal external dependencies
- The pool's own swap pattern is the most direct volatility signal; oracles provide aggregated or delayed data
- 10-observation buffer + minimum liquidity threshold + 1-block flash loan delay raises manipulation cost above economic viability
- An optional Chainlink TWAP adapter could be added in a future version

### Linear liquidityShare, Not sqrt

Using `sqrt(liquidityShare)` would superficially reward small LPs but enables whale split sybil attacks (split one position into N, gain N × sqrt(1/N) > 1 total reward). Wealth concentration mitigation is handled at the tier distribution layer (Bronze receives 25%, which is substantial relative to LP count). The score formula remains linear and sybil-resistant.

### ERC-721 Over ERC-6909

Uniswap v4's PoolManager uses ERC-6909 for internal accounting, making it the v4-native primitive. ERC-721 was selected for Holdfast for three reasons:

1. Per-position isolated transferability (each NFT is independently transferable)
2. The `_beforeTokenTransfer` override enables automatic accrual settlement, preventing accrual-theft attacks
3. Wallet and infrastructure UX maturity

An ERC-6909 variant could be added in a future version, particularly to optimize batch operations.

### Aave V3, Not a Mock

The composability dimension requires real protocol integration. Aave V3's Base Sepolia deployment is stable. Foundry fork tests validate integration against mainnet state. Withdraw failure paths are handled with try/catch and a fallback mechanism in the test suite.

### IL Compensation Is Partial

The realized-IL arm captures only 30% of the bonus pool. Full IL hedging would require options primitives or external hedging infrastructure (e.g., BELTA, Antonio Furtado's IL Hedge Hook). Holdfast provides partial compensation as a bounded mechanism, and this scope limit is explicit in the protocol's positioning.

### Dual Tier Criteria (Score + Block Count)

A pure score-based tier system is vulnerable to whale-instant-Gold: a high-liquidity position can reach 100,000 score in under an hour. The minimum active block requirement enforces tenure mechanically, ensuring the loyalty narrative is defensible at the protocol level.

### Redistribution Rate at 15%

Bonus pool funding draws 15% of pool fees. Lower rates (5 to 10%) weaken the bonus pool's effective size; higher rates (20 to 30%) penalize early-stage LPs before they qualify for any tier. 15% positions loyal LPs at marginal positive net return, mercenary LPs at marginal negative, and new LPs at reasonable time-to-breakeven. The rate is configurable per pool and subject to calibration.

## Net LP Returns

Illustrative example: $1M monthly swap volume, 0.30% pool fee, 15% redistribution rate, average volatility multiplier 1.2x.

- Total swapper pays: $3,000 (identical with or without Holdfast)
- LP direct fee pool: $3,000 × 0.85 = $2,550
- Bonus pool: $3,000 × 0.15 × 1.2 = $540

For an LP holding 10% of pool liquidity:

| LP type | Standard pool | Holdfast | Net difference |
|---|---|---|---|
| Mercenary (no tier) | $300 | $255 + $0 = **$255** | -15% |
| Bronze (1 of 50, 2% share) | $300 | $255 + $540×0.25×0.02 = **$258** | -14% |
| Silver (1 of 10, 10% share) | $300 | $255 + $540×0.35×0.10 = **$274** | -9% |
| Silver (1 of 3, 30% share) | $300 | $255 + $540×0.35×0.30 = **$312** | +4% |
| Gold (1 of 3, 30% share) | $300 | $255 + $540×0.40×0.30 = **$320** | +7% |

Additional uplift not shown in the table:

- Realized-IL arm: applies only to positions that incurred IL
- Aave V3 supply yield: accrued during bonus pool idle time

Interpretation:

- Loyalty is economically rewarded: high-tier LPs with significant intra-tier share outperform the standard pool
- Mercenary LPs experience structural disadvantage: -15% is the designed retention penalty
- New LPs begin marginally negative and cross to positive as they accumulate score and intra-tier share

These figures are illustrative. Calibration against testnet scenarios is required to finalize parameters.

## Limitations

Holdfast is designed for a specific pool segment. It is not suitable for:

- **Low-volume pools** (< ~100 swaps/day): the 10-observation volatility buffer retains stale data, degrading the volatility signal
- **Low-volatility pools** (< 20% annualized): the volatility multiplier remains near 1.0x, and fee redistribution provides minimal LP benefit; stablecoin pools (USDC/USDT etc.) fall into this category
- **Range-bound pairs:** sideways markets produce low scores, making tier qualification difficult or impossible

Recommended deployment criteria:

- Volatile pairs (>20% annualized historical volatility)
- Active swap volume (~100+ swaps/day minimum)
- Pool deployers should evaluate these criteria before installing the hook

## Related Work

Each component of Holdfast exists independently in the ecosystem. The contribution is in their integrated combination:

| Component | Prior art |
|---|---|
| IL hedge | BELTA, Antonio Furtado's IL Hedge Hook, Makemake, Cork Depeg Swaps |
| Volatility-based dynamic fee | FlexFee (Brevis), Volatility Fee Hook, Realized Volatility Hook |
| Rehypothecation (Aave/Morpho integration) | Flaunch, Bunni, EulerSwap, Uniswap Foundation's Rehypothecation Hook initiative |
| Tenure-based fee adjustment | SuckerPunch, Timelock Loyalty Hook |
| Dynamic LP NFT tiers | Apeful, Unimon, general evolving LP NFT patterns |

Holdfast's contribution is the synthesis: IL-aware scoring + realized-IL compensation arm + tier-based retention + Aave-compounded rewards in a single hook. The project does not claim a novel primitive; it claims a disciplined integration.

## Attack Vectors and Mitigations

| Attack | Mitigation |
|---|---|
| 1-tick range farming | Logarithmic `rangeNarrowness` + minimum liquidity threshold |
| Flash loan transient liquidity | `afterAddLiquidity` enforces a 1-block delay before score accrual |
| NFT transfer accrual theft | `_beforeTokenTransfer` settles to the original owner |
| Volatility manipulation (sandwich) | 10-observation ring buffer dampens single-swap impact |
| Whale split sybil | Linear `liquidityShare` in score formula (formula-level protection) |
| Whale-instant-Gold | Minimum active block requirement at each tier |
| Open/close farming | Streaks freeze rather than reset; no farming benefit |
| Reentrancy on claim | ReentrancyGuard + checks-effects-interactions |
| Aave withdraw failure | Try/catch with fallback path in the claim flow |
| IL baseline manipulation | `entrySqrtPriceX96` is set once in `afterAddLiquidity` and is immutable for the position |

## Scope

**In scope (Hookathon submission):**

- 4 contracts: `HoldfastHook`, `HoldfastNFT`, `ScoreAccumulator`, `YieldRouter`
- Real Aave V3 integration on Base Sepolia
- Realized IL computation and compensation arm
- Dual tier criteria (score + minimum blocks)
- Foundry test suite (unit + fork tests)
- Base Sepolia deployment with verified contracts
- Minimal frontend (single-page dashboard + claim)
- Architecture diagram, README, demo video, pitch deck

**Out of scope (potential future work):**

- On-chain SVG metadata (using IPFS-hosted static images instead)
- ERC-6909 accrual token (direct USDC transfers instead)
- Comprehensive frontend (NFT gallery, advanced analytics)
- Full IL hedging via options primitives
- Multi-protocol yield routing (Morpho, Yearn, etc.)
- Chainlink TWAP volatility adapter
- ERC-6909 variant for batch operations

## Repository Structure

```
holdfast-hook/
├── src/
│   ├── HoldfastHook.sol
│   ├── HoldfastNFT.sol
│   ├── YieldRouter.sol
│   └── libraries/
│       └── ScoreAccumulator.sol
├── test/
│   ├── unit/
│   ├── fork/
│   └── integration/
├── script/
│   └── Deploy.s.sol
├── frontend/
│   └── index.html
├── foundry.toml
├── README.md
└── DESIGN.md
```

## Deployment Target

- **Network:** Base Sepolia (chainId 84532)
- **Reasoning:** Mature Uniswap v4 deployment, stable Aave V3 testnet integration, 2-second block time for responsive demo, OP Stack architecture (portable to Unichain with minimal modification)
