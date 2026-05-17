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

The formula has been verified against the constant-product impermanent loss reference values (Uniswap research, Bancor documentation), and the Q64.96 integer implementation that will be used in `ScoreAccumulator.sol` agrees with the float reference to zero rounding error across 11 price scenarios. See `scripts/sim/results/realized_il_check/` for the reference table used by `test/unit/ScoreAccumulator.t.sol`.

### Tier Thresholds

Tiers require both a cumulative score threshold AND a minimum active block count. Both conditions must be satisfied for tier qualification. Score values are WAD-scaled (multiplied by 1e18) to match Solidity fixed-point conventions.

| Tier | Score threshold (WAD) | Minimum active blocks |
|---|---|---|
| Bronze | 10 × 1e18 | 1,000 (~33 min on Base) |
| Silver | 100 × 1e18 | 10,000 (~5.6 hours) |
| Gold | 1,000 × 1e18 | 100,000 (~2.3 days) |

The dual-criterion design prevents whales from instantly reaching Gold through high liquidity (a high-liquidity position could otherwise accumulate the score threshold in minutes), while linear `liquidityShare` in the score formula prevents sybil split attacks.

Threshold values were calibrated via Python simulations under `scripts/sim/`, with results committed under `scripts/sim/results/`. Calibration summary:

- **Tier accumulation timing** across 6 LP profiles (`tier_calibration/`): medium LP reaches Bronze in 33 min (blocks-gated), whale reaches Gold in 2.3 days (blocks-gated), small LPs are score-gated at higher tiers by design.
- **Whale-instant-Gold mitigation sweep** across 48 whale configurations (`whale_instant_gold/`): all configurations blocks-gated at Gold, 79.6x slowdown for the worst-case whale (99% liquidity share, 2.0x volatility, 10-tick range).
- **Net LP returns** across three parameter regimes (`net_lp_returns/`): mechanism is volatility-sensitive; Gold premium ranges from +0.14% (low-vol baseline) to +10.23% (high-vol pool). See Net LP Returns section.
- **Realized IL formula sanity check** (`realized_il_check/`): formula matches constant-product reference values; Q64.96 integer path agrees with float reference to zero rounding error across 11 price scenarios.

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

A 48-configuration whale parameter sweep (liquidity share 50 to 99%, volatility 0.5 to 2.0, tick width 10 to 200) confirms that all whale configurations are blocks-gated under the dual criterion. The worst-case whale (99% liquidity share, 2.0x volatility, 10-tick range) reaches the score threshold in approximately 1,256 blocks (~42 minutes), but the 100,000-block minimum enforces 2.31 days, a 79.6x slowdown. See `scripts/sim/results/whale_instant_gold/`.

### Redistribution Rate at 15%

Bonus pool funding draws 15% of pool fees. Lower rates (5 to 10%) weaken the bonus pool's effective size; higher rates (20 to 30%) penalize early-stage LPs before they qualify for any tier. 15% positions loyal LPs at marginal positive net return, mercenary LPs at marginal negative, and new LPs at reasonable time-to-breakeven. The rate is configurable per pool and subject to per-pool calibration based on the observed volatility regime; see Net LP Returns for the calibration sweep.

## Net LP Returns

The following table summarizes net LP returns across three calibration scenarios. All scenarios share: $1M monthly swap volume, 0.30% pool fee, 3% Aave V3 USDC supply APY (testnet estimate), LP holds 10% of pool liquidity, 70% tier-weighted arm fraction (the realized-IL arm at 30% is excluded since it is path-dependent and is sanity-checked separately). Source: `scripts/sim/net_lp_returns.py`; full reports in `scripts/sim/results/net_lp_returns/`.

**Scenarios:**

- **Baseline (low-vol pool):** redistribution rate 15%, volatility multiplier 1.2x. DESIGN.md defaults under a low-volatility regime.
- **High-volatility pool:** redistribution rate 15%, volatility multiplier 2.0x. Same redistribution rate, volatile pair (e.g. ETH/BTC during stress).
- **Adjusted redistribution:** redistribution rate 20%, volatility multiplier 1.5x. Stronger bonus pool funding, tighter mercenary penalty.

**Cross-scenario delta vs standard pool (in %, for an LP holding 10% of pool liquidity):**

| LP profile | Baseline (low-vol) | High-volatility | Adjusted redistribution |
|---|---|---|---|
| Mercenary (no tier) | -15.00% | -15.00% | -20.00% |
| Bronze (1 of 50, 2% intra-tier share) | -14.37% | -13.95% | -18.95% |
| Silver (1 of 10, 10% intra-tier share) | -10.58% | -7.64% | -12.64% |
| Silver (1 of 3, 30% intra-tier share) | -1.75% | +7.08% | +2.08% |
| Gold (1 of 3, 30% intra-tier share) | +0.14% | +10.23% | +5.23% |

**Calibration findings:**

- The baseline (low-vol) scenario produces a marginal Gold premium near zero. This is consistent with the Limitations section: Holdfast provides minimal LP benefit on low-volatility pools.
- The mechanism scales with pool volatility. The high-volatility scenario restores a meaningful loyal-LP premium (+10.23% at Gold) without changing the redistribution rate.
- Raising redistribution to 20% with a moderate volatility multiplier (1.5x) produces a more uniform premium and sharpens the mercenary penalty to -20%.
- The realized-IL arm (30% of bonus pool) is excluded from these figures; it applies only to positions that incurred IL and depends on the actual price path.
- The Aave V3 supply yield on the bonus pool contributes a small positive offset in all scenarios (sub-cent at the monthly scale of this example); contribution scales with TVL and APY and is included in the underlying CSV.

**Recommended deployment:** target pools with >20% annualized volatility. Per-pool calibration of `redistributionRate` should account for the observed volatility regime; the parameter is set at initialization and is not modifiable after the pool is configured.

## Limitations

Holdfast is designed for a specific pool segment. It is not suitable for:

- **Low-volume pools** (< ~100 swaps/day): the 10-observation volatility buffer retains stale data, degrading the volatility signal
- **Low-volatility pools** (< 20% annualized): the volatility multiplier remains near 1.0x, and fee redistribution provides minimal LP benefit (the baseline calibration scenario in Net LP Returns confirms this); stablecoin pools (USDC/USDT etc.) fall into this category
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
| Whale-instant-Gold | Minimum active block requirement at each tier; 48-config sweep confirms all whale profiles blocks-gated (79.6x slowdown for worst case) |
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
├── scripts/
│   └── sim/
│       ├── tier_calibration.py
│       ├── whale_instant_gold.py
│       ├── net_lp_returns.py
│       ├── realized_il_check.py
│       └── results/
├── frontend/
│   └── index.html
├── foundry.toml
├── README.md
└── DESIGN.md
```

## Deployment Target

- **Network:** Base Sepolia (chainId 84532)
- **Reasoning:** Mature Uniswap v4 deployment, stable Aave V3 testnet integration, 2-second block time for responsive demo, OP Stack architecture (portable to Unichain with minimal modification)
