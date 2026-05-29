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
        │   HoldfastHook   │
        │  (v4 lifecycle)  │
        └────────┬─────────┘
                 │
     ┌───────────┼───────────┐
     │           │           │
     ▼           ▼           ▼
┌─────────┐ ┌─────────┐ ┌─────────┐
│  Score  │ │Holdfast │ │ Yield   │
│ Accumul.│ │  NFT    │ │ Router  │
│(library)│ │(ERC-721)│ │(Aave V3)│
└─────────┘ └─────────┘ └────┬────┘
                             │
                             ▼
                       ┌───────────┐
                       │  Aave V3  │
                       │   Pool    │
                       │(Base Sep.)│
                       └───────────┘
```

### Contracts

1. **HoldfastHook.sol**: v4 lifecycle integration (afterInitialize, afterAddLiquidity, beforeRemoveLiquidity, afterRemoveLiquidity, beforeSwap, afterSwap)
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

The formula has been verified against the constant-product impermanent loss reference values (Uniswap research, Bancor documentation), and is implemented in `ScoreAccumulator.sol` with 23 unit and fuzz tests; the Q64.96 integer implementation agrees with the float reference to zero rounding error across 11 price scenarios. See `scripts/sim/results/realized_il_check/` for the reference table used by `test/unit/ScoreAccumulator.t.sol`.

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

### Swap Hook Mechanics

The score accumulator and bonus pool are updated on every swap. Three design parameters govern this path.

**Fee mechanism: manual carve-out in `afterSwap`.**

Holdfast does not modify the swapper-facing fee. The pool charges its native fee tier unchanged. In `afterSwap`, the hook reads the LP fee component from `BalanceDelta` and routes `redistributionRate × volatilityMultiplier × poolFee` to the bonus pool by returning an `AFTER_SWAP_RETURNS_DELTA`. The remaining `(1 - redistributionRate × volatilityMultiplier)` of the fee is distributed natively by the PoolManager to in-range LPs. This requires the `AFTER_SWAP_RETURNS_DELTA` permission flag and is compatible with any static fee tier (500, 3000, 10000 bps); the pool is not required to be initialized in dynamic-fee mode.

Rejected alternative: setting a dynamic fee via `LPFeeLibrary` in `beforeSwap`. Rejected because it would either inflate the swapper-facing fee (violating the "swap costs remain unchanged" positioning) or require pools to be initialized in dynamic-fee mode (restricting deployment surface). The carve-out path keeps the hook composable with arbitrary existing pools.

**Volatility factor: mean squared deviation of `sqrtPrice` ratios from no-change.**

The 10-observation ring buffer is consumed in `ScoreAccumulator.calculateVolatilityFactor` (pure):

1. Compute 9 consecutive ratios `ratio_i = sqrtPrice[i+1] / sqrtPrice[i]` in WAD scale.
2. For each ratio compute its deviation from `WAD` (the no-change point, ratio = 1.0), square it, and normalize back to WAD scale by dividing by `WAD`. Average the 9 normalized squared deviations.
3. Multiply by 4 to convert sqrtPrice deviation to price deviation (`d(p)/p approx 2 * d(sqrtP)/sqrtP`).
4. Multiply by `SCALE_FACTOR` (calibration constant); the value is already WAD-scaled.
5. Cap at `2 * WAD` (200%).

The deviation is measured from `WAD` rather than the sample mean so that a steady price trend still registers as volatility: a classic mean-relative variance would report zero for a constant per-swap drift, but such drift still drives impermanent loss, so the no-change reference is the IL-consistent choice.

`SCALE_FACTOR` is initialized at `1e18` and calibrated in a follow-up Python sim such that ~20% annualized historical volatility maps to `~1.0 × WAD`.

Rejected alternative: variance of log returns. Rejected on gas grounds; `lnWad` costs 500-800 gas per call, and `afterSwap` invokes 9 of them per swap (~5-7k gas overhead on every trade). Per-swap movements in concentrated-liquidity pools are typically below 5%, where `ln(1+x) ≈ x` and the ratio-variance proxy tracks log-variance to within tolerance acceptable for a score weighting.

Rejected alternative: max-min range over the buffer. Rejected because a single outlier observation dominates the window, exposing a manipulation surface; also violates the DESIGN.md semantic ("variance of the last 10 swap prices").

Edge cases:

- Identical observations across the buffer (a freshly seeded pool or a dormant pool): variance = 0, `volatilityFactor` = 0, block score contribution = 0. Correct behavior.
- Buffer is pre-seeded with the initial `sqrtPriceX96` across all 10 slots in `afterInitialize` (Day 5-6, lifecycle tests passing), so the first swap produces low-variance output rather than a cold-start error.

**Volatility multiplier: piecewise linear, capped band.**

The bonus pool funding multiplier is a piecewise function of `volatilityFactor` (WAD-scaled):

| volatilityFactor band | volatilityMultiplier |
|---|---|
| `≤ 0.5 × WAD` | `1.0 × WAD` (flat) |
| `0.5 × WAD < x < 1.5 × WAD` | linear interpolation between `1.0 × WAD` and `1.5 × WAD` |
| `≥ 1.5 × WAD` | `1.5 × WAD` (cap) |

Closed form for the linear band:

```
multiplier = WAD + ((volatilityFactor - 0.5 × WAD) × 0.5 × WAD) / WAD
```

Rejected alternative: pure linear from `0` upwards. Rejected because it would push `multiplier > 1.0×` in low-volatility regimes, inflating fee redistribution on stable-pair-like flow where the mechanism is not intended to be active. The flat 1.0× floor below `0.5 × WAD` keeps the hook a no-op on low-volatility pools (consistent with the Limitations section).

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

### YieldRouter (Aave V3 Integration)

The bonus pool is held as real USDC and supplied to Aave V3 between funding and claim. `YieldRouter` is a thin adapter contract that owns the USDC balance, supplies it to Aave V3's USDC reserve, and withdraws on claim. aToken accounting is delegated to Aave (scaled balance pattern), so the router does not maintain a separate yield ledger.

**Access control: only the bound hook.**


`YieldRouter.supplyToAave` and `YieldRouter.withdrawFromAave` are gated by an `onlyHook` modifier. The hook address is set exactly once via `setHook` (owner-only, one-time bind), mirroring the `HoldfastNFT` trust boundary. The owner has no withdraw or emergency path in this version: the router holds no idle USDC outside the bonus pool flow, so the blast radius of a router-only compromise is bounded by the bonus pool balance.

Rejected alternative: owner-emergency withdraw path. Rejected for hookathon scope because (1) it expands the attack surface without a corresponding threat model (the owner key is not multisig-guarded in this submission), (2) the bonus pool is reconstructible from on-chain state if the router is redeployed, and (3) the minimal-trust framing is easier to defend than a partial-emergency framing. A future mainnet variant under a multisig owner can revisit this.

**Approve flow: infinite approval on deploy.**

`YieldRouter` issues `type(uint256).max` USDC approval to the Aave V3 Pool once in the constructor. Subsequent `supplyToAave` calls do not re-approve. Lower per-supply gas cost, and Aave V3 Pool is a widely-audited single counterparty whose blast radius is bounded to the router's USDC balance (which equals the bonus pool balance plus in-flight swap captures).

Rejected alternative: per-supply approval (approve exact amount before each supply). Rejected on gas grounds (one extra storage write per swap that funds the bonus pool, ~5k gas) and because the risk reduction is illusory (the router holds no USDC outside the bonus pool flow, so per-supply approval does not actually shrink the realistic loss surface).

**Fee capture mechanism: `afterSwapReturnDelta`.**

This ratifies the Swap Hook Mechanics decision: the `AFTER_SWAP_RETURNS_DELTA` permission flag is enabled, and `afterSwap` returns a delta equal to `redistributionRate × volatilityMultiplier × poolFee`. The hook contract receives the captured USDC in the same transaction, then calls `YieldRouter.supplyToAave(capturedAmount)`. The IOU accounting introduced in earlier work is retired: `bonusPoolUSDC` becomes a real balance, not a uint256 ledger.

**Fork test target: Base mainnet Aave V3 at a pinned block.**

Integration tests for the Aave V3 supply and withdraw paths fork Base mainnet rather than Base Sepolia, despite the deployment target being Base Sepolia. Rationale: Base Sepolia's Aave deployment has sporadic reserve state and thin testnet liquidity, which produces flaky fork tests and non-meaningful yield accrual measurements. Base mainnet's USDC reserve is high-TVL and stable, so the fork test produces a deterministic yield signal under a real interest rate model.

The fork block is pinned per test invocation via `--fork-block-number`, not in `foundry.toml`, so the pin can be advanced without a config change. The test reports the block number in its setup log to keep CI runs auditable. Deployment to Base Sepolia is unaffected by this choice; only the integration test environment differs.

**Withdraw failure fallback.**

`YieldRouter.withdrawFromAave` wraps the Aave `withdraw` call in a try/catch. On failure, the router does not revert the claim transaction; it returns 0 and emits a `WithdrawFailed` event carrying the Aave revert reason. The claim flow consumes the zero-fill and reconciles via the IOU accounting. This matches the "Aave withdraw failure: try/catch with fallback path" entry in the Attack Vectors table.

**Hook wiring scope.**

`HoldfastHook` holds an immutable reference to `YieldRouter`, set at construction. The hook does not yet route real USDC through the router: `afterSwap` continues to maintain an in-memory `bonusPoolUSDC` IOU counter, and `AFTER_SWAP_RETURNS_DELTA` remains disabled. The real-USDC capture path, the `afterSwapReturnDelta` flip, and the corresponding `take`/`settle` accounting are scoped to the claim-flow milestone that follows. Sequencing rationale: the delta-accounting change to `afterSwap` is the highest-risk modification to the swap path and is best validated alongside the claim flow that consumes the captured USDC, rather than as an isolated change with no downstream consumer.

### NFT Mechanics

When a position first crosses the Bronze threshold, an NFT is minted. Subsequent tier upgrades update the same tokenId's metadata pointer; new tokens are not minted on upgrade. The `_update` override (OpenZeppelin v5 pattern) settles accrued rewards to the original owner during transfer.

NFT serves as a claim accounting primitive: tier indicator, per-position isolated state, and transfer-time settlement hook. ERC-721 transferability is preserved as a standard property but is not the primary design intent.

**Mint timing.** `HoldfastHook` calls `HoldfastNFT.mint(to, positionKey)` only when both `accumulatedScore >= BRONZE_THRESHOLD` AND `block.number - firstActiveBlock >= BRONZE_BLOCKS` are satisfied. Subsequent `upgradeTier(tokenId, newTier)` calls follow the same dual-criterion check at the Silver and Gold thresholds. The NFT contract itself does not enforce the dual criterion; see the Trust Boundary design decision.

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
    int256 realizedIL;              // computed at closure (beforeRemoveLiquidity), consumed by the realized-IL arm
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

`HoldfastNFT` maintains the per-token and inverse mappings used during mint, tier upgrade, and transfer settlement:

```solidity
mapping(uint256 => uint8) public tokenIdToTier;
mapping(bytes32 => uint256) public positionKeyToTokenId;
mapping(uint256 => bytes32) public tokenIdToPositionKey;
```

`tokenIdToPositionKey` is the reverse lookup consumed by `_update` to call `hook.settleOnTransfer(positionKey, from, to)` without requiring the hook to maintain a parallel index.

Position key derivation:

```solidity
positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt)
//          = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
```

`salt` is passed through from Uniswap v4's `ModifyLiquidityParams.salt`, enabling the same owner to maintain multiple positions with the same tick range. The key layout is byte-identical to v4-core's `Position.calculatePositionKey`, so the same value indexes both the hook's streak mapping and Uniswap's internal position state (consumed via `StateLibrary.getPositionLiquidity` in `afterRemoveLiquidity`).

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
2. The `_update` override (OpenZeppelin v5) enables automatic accrual settlement, preventing accrual-theft attacks
3. Wallet and infrastructure UX maturity

An ERC-6909 variant could be added in a future version, particularly to optimize batch operations.

### Solady FixedPointMathLib over Solmate

The Uniswap v4-core dependency tree ships a minimal version of Solmate's FixedPointMathLib (only `mulWadDown`, `sqrt`, `rpow`). Holdfast's `ScoreAccumulator.calculateRangeNarrowness` requires natural logarithm (`lnWad`), which is not exposed in that minimal version.

Solady was added as a top-level dependency (`forge install vectorized/solady`) and remapped via `solady/=lib/solady/src/`. Solady's `FixedPointMathLib.lnWad` provides the needed primitive with WAD-precision signed-fixed-point arithmetic, and Solady's `fullMulDiv` is also used in the Q64.96 integer path of `calculateRealizedIL`.

Trade-off: an additional dependency, but the natural-log primitive is essential for the score formula and is not available in the v4-bundled Solmate. Solady is well-maintained, gas-optimized, and widely used in production Solidity codebases.

### OpenZeppelin v5 and `_update` Migration

`HoldfastNFT` extends OpenZeppelin Contracts v5.6.1 (`ERC721`, `Ownable`). In v5, the legacy `_beforeTokenTransfer` and `_afterTokenTransfer` hooks were removed and consolidated into a single `_update(address to, uint256 tokenId, address auth)` override that returns the previous owner.

Holdfast uses `_update` to invoke `IHoldfastHook.settleOnTransfer(positionKey, from, to)` on every non-mint transfer (including burns), preventing accrual-theft attacks. Mint is detected via `from == address(0)` after the `super._update` call and is intentionally skipped to avoid calling `settleOnTransfer` on a position that has no accrued state yet.

OZ v5 also changed `Ownable` to require an `initialOwner` constructor parameter and replaced string revert reasons with custom errors (`OwnableUnauthorizedAccount`, `ERC721NonexistentToken`, etc.), which are used directly in `HoldfastNFT` tests.

Trade-off: v5 is not API-compatible with v4-bundled OZ (which v4-hooks-public ships). The top-level `lib/openzeppelin-contracts` install at v5.6.1 supersedes the bundled version via remapping, ensuring a single OZ version is resolved at compile time.

### Trust Boundary: Hook Authoritative, NFT Accounting Primitive

`HoldfastNFT` is a passive accounting primitive. Tier eligibility (the dual criterion: `accumulatedScore >= threshold` AND `block.number - firstActiveBlock >= minBlocks`) is validated exclusively in `HoldfastHook`. The NFT contract trusts its bound hook to enforce these constraints before calling `mint` or `upgradeTier`.

`HoldfastNFT` enforces the following invariants on its own:

- Only the bound hook address can call `mint` and `upgradeTier` (`onlyHook` modifier)
- The hook address can be set exactly once via `setHook` (only-owner, one-time bind)
- `upgradeTier` rejects downgrades and any tier value outside `{TIER_SILVER, TIER_GOLD}` (Bronze is set only on mint)
- A given `positionKey` can be minted at most once
- `_update` calls `settleOnTransfer` on every non-mint transfer

The NFT does not check the dual-criterion thresholds. If the hook is buggy and calls `upgradeTier(tokenId, TIER_GOLD)` before the block minimum is met, the NFT will accept the upgrade.

Rationale:

- **Single source of truth.** Tier logic exists in one place (`HoldfastHook`), simplifying audit surface and avoiding two diverging implementations of the dual criterion.
- **Authorized caller.** The hook is already the only privileged caller; redundant checks in the NFT would duplicate logic without strengthening security against a non-hook attacker.
- **Test compensation.** The hook test suite (Day 5+) is responsible for asserting the dual criterion: a whale-instant-Gold attempt test, a mint-timing test (no mint before Bronze threshold), and a dual-criterion test (neither criterion alone triggers mint or upgrade) are mandatory.

If the hook implementation ever becomes shared across multiple NFT deployments or unauthorized callers, this trust assumption should be revisited and the NFT should accept and verify `firstActiveBlock` as a parameter.

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
| NFT transfer accrual theft | `_update` (OZ v5) callback settles to the original owner |
| Volatility manipulation (sandwich) | 10-observation ring buffer dampens single-swap impact |
| Whale split sybil | Linear `liquidityShare` in score formula (formula-level protection) |
| Whale-instant-Gold | Minimum active block requirement at each tier; 48-config sweep confirms all whale profiles blocks-gated (79.6x slowdown for worst case); enforced in `HoldfastHook` before calling `mint` / `upgradeTier` (see Trust Boundary) |
| Open/close farming | Streaks freeze rather than reset; no farming benefit |
| Reentrancy on claim | ReentrancyGuard + checks-effects-interactions |
| Aave withdraw failure | Try/catch with fallback path in the claim flow |
| Aave Pool approval scope abuse | Infinite approval but router holds no USDC outside bonus pool flow; blast radius bounded to bonus pool balance |
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
│   ├── interfaces/
│   │   └── IHoldfastHook.sol
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
