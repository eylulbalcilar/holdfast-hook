# Holdfast

A Uniswap v4 hook that measures IL exposure, partially compensates realized impermanent loss, and compounds rewards through Aave V3.

UHI9 Capstone Project · Base Sepolia

> **Status.** Holdfast is deployed and live on Base Sepolia. It is a subscriber-native hook: position ownership and liquidity are anchored to the canonical Uniswap PositionManager via the `ISubscriber` interface, and per-position state is keyed by the PositionManager ERC-721 `tokenId`. The full lifecycle (mint → subscribe → swap-driven accrual → tier + badge → claim) has been demonstrated end-to-end on Base Sepolia with real funds. See Live Deployment.

## Overview

Holdfast is a Uniswap v4 hook designed for volatile pair pools. It addresses the mercenary capital problem in concentrated liquidity provisioning by combining four mechanisms:

1. **Risk-weighted scoring:** each LP position accumulates a score based on liquidity share, range narrowness, and pool volatility
2. **Partial IL compensation:** realized impermanent loss is computed at claim time, and a portion of the bonus pool is distributed proportionally to IL incurred
3. **Tier-based retention rewards:** Bronze, Silver, and Gold tiers gate access to bonus pool shares
4. **Yield compounding via Aave V3:** bonus pool funds are supplied to Aave V3 while idle, generating additional yield

**Honest positioning.** Holdfast is not a full IL hedge. It does not eliminate impermanent loss. It measures IL exposure, partially compensates realized IL from a bonus pool, and provides retention incentives for LPs who stay through high-volatility periods. Full IL hedging requires options primitives or external hedging infrastructure, which is out of scope.

**Fee model.** Holdfast does not charge swappers any additional fee. A fixed portion (`redistributionRate`, default 15%) of the existing pool fee is designed to be redirected to the bonus pool. Swap costs remain unchanged. Tier-qualified LPs recover the redistributed amount through bonus pool shares; non-qualified (mercenary) LPs experience reduced direct fee income, which functions as a structural retention incentive. (See Bonus Pool Funding for the current implementation status of the capture path.)

## UHI9 Theme Alignment

UHI9 theme: "Impermanent Loss and Yield Systems"

| Theme criterion | Holdfast mechanism |
|---|---|
| Impermanent Loss measurement | Score formula incorporates IL proxy (volatility, range narrowness, liquidity share); realized IL computed at closure |
| IL compensation | Realized-IL arm distributes 30% of bonus pool proportional to actual IL incurred |
| Yield Systems | Fee redistribution and Aave V3 supply yield (genuine composability) |
| Protection mechanism | Risk-weighted retention through tier system and volatility-aware multipliers |

## Live Deployment

Holdfast is deployed and verified-working on Base Sepolia (chainId 84532).

| Contract | Address |
|---|---|
| HoldfastHook | `0xC7B5f55C6a1EaB55EDbe72cA7e3c4cA1Bd9b90c4` |
| HoldfastNFT | `0x3caA1d58c469390cE301c05C5b0c545EAF21903a` |
| YieldRouter | `0x1de3015754e615d31aCA1FF474c74640886c3Eff` |

The hook address encodes its permission flags in its low bits (`address & 0x3FFF == 0x10C4`): `afterInitialize`, `beforeSwap`, `afterSwap`, and `afterSwapReturnsDelta`. The contract was deployed at a CREATE2 address mined to match exactly this permission set; `BaseHook`'s constructor re-validates the encoded flags on construction.

Canonical Base Sepolia dependencies the deployment binds to:

| Dependency | Address |
|---|---|
| Uniswap v4 PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Uniswap v4 PositionManager | `0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80` |
| USDC (Aave testnet, 6 decimals) | `0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f` |
| aUSDC | `0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC` |

### End-to-end on-chain demonstration

The complete subscriber-native cycle has been exercised on Base Sepolia with real funds:

1. A position was minted through the canonical PositionManager (tokenId 24715) in a WETH/USDC pool (fee 3000, tick spacing 60).
2. The owner called `posm.subscribe(tokenId, holdfast, "")`, which fired `notifySubscribe` and began accrual.
3. Swap activity drove the pool-level score accumulator; after the Bronze tenure requirement (≥1000 blocks) was met and the score threshold crossed, a settle minted a Bronze badge (NFT tokenId 1) for the position.
4. The owner called `claim(24715)` and received the Bronze tier-weighted share of a 100 USDC bonus pool (17.5 USDC = 100 × 70% tier arm × 25% Bronze weight, sole LP in tier). The position's score was reset and removed from the tier denominator at the payment boundary; the router's aUSDC balance dropped by the paid amount.

This validates the full design on-chain: subscriber-native identity, tier-indexed accounting, the decrement-at-payment model, the WAD→USDC boundary conversion, and the Aave withdraw path.

The contract logic is additionally covered by a Foundry suite of 138 passing tests (unit, integration, and fork), including end-to-end natural-flow integration tests for owner transfer, multi-LP isolation, partial liquidity removal, and dropped-unsubscribe reconciliation.

## Architecture

```
                    +------------------+
                    |   HoldfastHook   |
                    | BaseHook +       |
                    | ISubscriber      |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
              v              v              v
        +-----------+  +-----------+  +-----------+
        |   Score   |  | Holdfast  |  |   Yield   |
        |  Accumul. |  |    NFT    |  |  Router   |
        | (library) |  | (ERC-721) |  | (Aave V3) |
        +-----------+  +-----------+  +-----+-----+
                                            |
                                            v
                                      +-----------+
                                      |  Aave V3  |
                                      |   Pool    |
                                      |(Base Sep) |
                                      +-----------+
```

### Contracts

1. **HoldfastHook.sol**: a single contract that is simultaneously a Uniswap v4 `BaseHook` and a canonical PositionManager `ISubscriber`. It integrates the v4 lifecycle (`afterInitialize`, `beforeSwap`, `afterSwap`) using the `AFTER_SWAP_RETURNS_DELTA` permission flag, and implements the subscriber notifications (`notifySubscribe`, `notifyModifyLiquidity`, `notifyBurn`, `notifyUnsubscribe`).
2. **HoldfastNFT.sol**: ERC-721 tier badge (Bronze/Silver/Gold), with IPFS pointers for three static tier images.
3. **ScoreAccumulator.sol**: Pure library for score calculation, volatility factor, and realized IL math.
4. **YieldRouter.sol**: Aave V3 supply and withdraw operations, aToken accounting.

## Identity Model

The identity model is the foundational design constraint, so it is documented first.

Holdfast anchors every position's identity to the canonical Uniswap PositionManager (PosM). The hook is a registered `ISubscriber` on PosM, and per-position state is keyed by the PositionManager ERC-721 `tokenId`. There is no `hookData`-decoded owner, no `msg.sender`-derived owner, and no hook-computed position key. There is exactly one identity (the `tokenId`) and exactly one ownership source (the ERC-721), so the class of bug where a hook-side key diverges from a PoolManager-side key does not exist by construction.

### What is read, and when

- **Owner** is read from `posm.ownerOf(tokenId)` and cached into the position's `streak.owner` at `notifySubscribe`. Claim authorization is bound to this cached owner.
- **Liquidity** has its absolute baseline read once at subscription via `posm.getPositionLiquidity(tokenId)`, then tracked from the authoritative signed `liquidityChange` delivered to `notifyModifyLiquidity`.
- **Range and pool** are read at subscription via `posm.getPoolAndPositionInfo(tokenId)`. The live entry price (`entrySqrtPriceX96`, the realized-IL baseline) is read from `poolManager.getSlot0(poolId)` at subscription.

### Rejected alternative: caller-asserted identity via `hookData`

An earlier design resolved ownership by decoding an owner address from `hookData` (`abi.decode(hookData, (address))`) inside the liquidity callbacks. This was rejected because the owner field is asserted by the caller, not anchored to a canonical source:

- There is no cryptographic binding between the address in `hookData` and the entity that actually controls the underlying PoolManager position.
- It creates a denial-of-accrual spoofing surface: an adversary calling `modifyLiquidity` with `hookData = abi.encode(victim_address)` could write streak state under a victim's key, interfering with the victim's score accounting (injecting score, distorting the tier-sum invariant, or pre-minting a badge under the victim's key). Claim authorization being bound to the NFT owner prevents value theft, but the accrual interference is real.

The subscriber model removes this surface entirely: identity is the canonical `tokenId`, ownership is the canonical ERC-721, and a caller cannot assert another party's identity.

### Rejected alternative: Holdfast as custodial liquidity entrypoint

Another way to unify identity would be for Holdfast to become the liquidity entrypoint and own positions in PoolManager itself (`msg.sender == holdfast`). This is rejected. Holdfast is a non-custodial reward layer. Taking custody would introduce a funds-holding surface (settle/take/sync flows, approval management, reentrancy on principal), invalidate the bounded-blast-radius argument for the YieldRouter, and move the LP experience away from standard Uniswap tooling. The subscriber model achieves authoritative identity without custody, which is the correct minimum authority for this product.

## Subscriber Notifications

The hook implements the four `ISubscriber` callbacks. Two hard invariants from the v4-periphery source shape these implementations.

**Invariant 1: `notifyModifyLiquidity` and `notifyBurn` must never revert.** They bubble up through PosM and would revert the LP's own `modifyLiquidity` transaction. So these handlers perform no external calls (no Aave supply/withdraw), no unbounded loops, and contain no checks that can fail. All external interaction is deferred to `claim` and `withdrawPendingClaim`, which run in the LP's own frame where a revert is safe.

**Invariant 2: `notifyUnsubscribe` is gas-capped and its result is swallowed.** Correctness must not depend on it executing. The authoritative reconciliation point is `notifySubscribe` (which is not gas-capped). If `notifyUnsubscribe` is dropped, no value is lost.

### notifySubscribe

- Reads `posm.ownerOf(tokenId)`, `getPoolAndPositionInfo(tokenId)`, `getPositionLiquidity(tokenId)`, and `poolManager.getSlot0(poolId)`.
- **Cold init** (no existing streak): caches owner, poolId, ticks, and the liquidity baseline; sets `firstActiveBlock = block.number`; snapshots `lastGlobalScoreSnapshot` from `globalScorePerLiquidity[poolId]`; sets `entrySqrtPriceX96`.
- **Owner change** (a re-subscribe under a different cached owner): finalizes the prior owner's accrued tiered score into `pendingScoreByTier[oldOwner][tier]`, then resets the streak for the new owner with a fresh baseline (new `entrySqrtPriceX96`, `firstActiveBlock`, zeroed `accumulatedScore`, reset tier and badge reference). The finalize happens **before** the reset, so the old owner's score is never lost.
- Storage-only. No external calls.

### notifyModifyLiquidity

- Settles accrued score using the **old** cached liquidity (before applying the change), then advances `lastGlobalScoreSnapshot`.
- Applies the signed `liquidityChange`. A defensive clamp-to-zero guards against any underflow without reverting.
- Lazily evaluates tier; if the dual criterion is met, mints or upgrades the NFT badge through a revert-safe `try/catch` so a badge-side revert can never poison this never-revert handler.

### notifyBurn

- Settles the final score, computes realized IL against the `entrySqrtPriceX96` baseline (via `ScoreAccumulator.calculateRealizedIL`), freezes the streak, and adds the absolute IL to `sumOfAbsoluteIL`.
- A burned position's score **stays** in `sumOfTierScores` (see Tier Accounting Model); it is removed only when paid.
- An idempotency guard early-returns (no revert) if the streak is already inactive.

### notifyUnsubscribe

- Sets a best-effort `isFrozen` flag and nothing else. The flag is never read by any reconciliation path, so dropping this callback changes no outcome.

## Tier Accounting Model

A single invariant governs the tier denominator `sumOfTierScores[tier]`:

> A position's score stays in `sumOfTierScores[tier]` until it is actually **paid**. It is never decremented at burn or at owner change. The decrement happens only at the payment boundary (`claim` or `withdrawPendingClaim`), against the live denominator.

This keeps pro-rata distribution exact: a position's score is in both the numerator and the denominator until the moment it is paid out. Score enters the denominator on tier entry (mint) and on incremental accrual (settle); it moves between buckets on tier upgrade (a paired decrement+increment that is net-zero across tiers); and it leaves the denominator only via a payment.

### Pending entitlements vs pending debts

Two distinct kinds of pending balance are kept in separate, unambiguous mappings:

- `pendingScoreByTier[address][tier]` (WAD score): an **entitlement** parked when an owner change finalizes a prior owner's tiered score. It is still owed and stays in `sumOfTierScores` until drained. It is converted to USDC pro-rata against the live denominator at `withdrawPendingClaim`.
- `pendingUsdc[address]` (USDC): a **debt** recorded when an Aave withdraw partially fills during a claim. It is already a fixed USDC amount and is added after the WAD→USDC conversion.

## Mechanics

### Score Formula

Per position, per block:

```
blockScore = liquidityShare * volatilityFactor * rangeNarrowness
```

Where:

- `liquidityShare`: position's share of pool liquidity, linear in range 0 to 1
- `volatilityFactor`: variance of the last 10 swap prices, computed from pool state, no oracle
- `rangeNarrowness`: `1 / log(tickUpper - tickLower + 2)`, narrow ranges receive higher coefficients, logarithmically bounded

If a position is out of range, score accumulation pauses but does not reset. The position retains its accumulated score and resumes when back in range.

Per-position score is accumulated via a Curve gauge-style lazy update pattern. The pool-level `globalScorePerLiquidity` increments based on swap-driven activity. Per-position score is settled lazily through a shared internal helper, invoked from `notifyModifyLiquidity`, `notifyBurn`, and `claim`. The shared helper keeps `accumulatedScore` and `sumOfTierScores[tier]` in step in one place, so every caller maintains the denominator identically.

### Realized IL Computation

When a position subscribes, `entrySqrtPriceX96` is snapshotted from the pool's slot0. At claim time or position closure, realized IL is computed using the standard constant-product formula:

```
priceRatio = (currentSqrtPrice / entrySqrtPrice)^2
IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1
```

IL is negative (representing loss). The realized-IL arm distributes its allocation proportional to the absolute value of IL incurred, across all positions that have non-zero closed IL.

The formula has been verified against the constant-product impermanent loss reference values (Uniswap research, Bancor documentation), and is implemented in `ScoreAccumulator.sol` with unit and fuzz tests. The Q64.96 integer implementation agrees with the float reference to zero rounding error across 11 price scenarios. See `scripts/sim/results/realized_il_check/` for the reference table.

### Tier Thresholds

Tiers require both a cumulative score threshold AND a minimum active block count. Both conditions must be satisfied for tier qualification. Score values are WAD-scaled (multiplied by 1e18) to match Solidity fixed-point conventions.

| Tier | Score threshold (WAD) | Minimum active blocks |
|---|---|---|
| Bronze | 10 * 1e18 | 1,000 (~33 min on Base) |
| Silver | 100 * 1e18 | 10,000 (~5.6 hours) |
| Gold | 1,000 * 1e18 | 100,000 (~2.3 days) |

The dual-criterion design prevents whales from instantly reaching Gold through high liquidity (a high-liquidity position could otherwise accumulate the score threshold in minutes), while linear `liquidityShare` in the score formula prevents sybil split attacks.

Threshold values were calibrated via Python simulations under `scripts/sim/`, with results committed under `scripts/sim/results/`. Calibration summary:

- **Tier accumulation timing** across 6 LP profiles (`tier_calibration/`): medium LP reaches Bronze in 33 min (blocks-gated), whale reaches Gold in 2.3 days (blocks-gated), small LPs are score-gated at higher tiers by design.
- **Whale-instant-Gold mitigation sweep** across 48 whale configurations (`whale_instant_gold/`): all configurations blocks-gated at Gold, 79.6x slowdown for the worst-case whale (99% liquidity share, 2.0x volatility, 10-tick range).
- **Net LP returns** across three parameter regimes (`net_lp_returns/`): mechanism is volatility-sensitive; Gold premium ranges from +0.14% (low-vol baseline) to +10.23% (high-vol pool). See Net LP Returns section.
- **Realized IL formula sanity check** (`realized_il_check/`): formula matches constant-product reference values; Q64.96 integer path agrees with float reference to zero rounding error across 11 price scenarios.

### Swap Hook Mechanics

The score accumulator is updated on swap activity. Three design parameters govern this path.

**Volatility factor: mean squared deviation of `sqrtPrice` ratios from no-change.**

The 10-observation ring buffer is consumed in `ScoreAccumulator.calculateVolatilityFactor` (pure):

1. Compute 9 consecutive ratios `ratio_i = sqrtPrice[i+1] / sqrtPrice[i]` in WAD scale.
2. For each ratio compute its deviation from `WAD` (the no-change point, ratio = 1.0), square it via `FixedPointMathLib.fullMulDiv(diff, diff, WAD)`, and average the 9 normalized squared deviations. `fullMulDiv` uses a 512-bit intermediate product, so an extreme single-swap sqrtPrice jump toward the tick limit cannot overflow before the value is downscaled and later capped at `MAX_VOLATILITY_FACTOR`.
3. Multiply by 4 to convert sqrtPrice deviation to price deviation (`d(p)/p ~= 2 * d(sqrtP)/sqrtP`).
4. Multiply by `SCALE_FACTOR` (calibration constant); the value is already WAD-scaled.
5. Cap at `2 * WAD` (200%).

The deviation is measured from `WAD` rather than the sample mean so that a steady price trend still registers as volatility: a classic mean-relative variance would report zero for a constant per-swap drift, but such drift still drives impermanent loss, so the no-change reference is the IL-consistent choice.

`SCALE_FACTOR` is calibrated via Monte Carlo simulation (`scripts/sim/scale_factor_calibration.py`) such that ~40% annualized historical volatility maps to ~1.0 WAD volatility factor. Below this, the multiplier floor at 1.0x kicks in; above, the multiplier scales toward 1.5x.

Rejected alternative: variance of log returns. Rejected on gas grounds; `lnWad` costs 500-800 gas per call, and a per-swap path would invoke several of them on every trade. Per-swap movements in concentrated-liquidity pools are typically below 5%, where `ln(1+x) ~= x` and the ratio-variance proxy tracks log-variance to within tolerance acceptable for a score weighting.

Rejected alternative: max-min range over the buffer. Rejected because a single outlier observation dominates the window, exposing a manipulation surface; also violates the semantic "variance of the last 10 swap prices".

Edge cases:

- Identical observations across the buffer (a freshly seeded pool or a dormant pool): variance = 0, `volatilityFactor` = 0, block score contribution = 0. Correct behavior.
- The buffer is pre-seeded with the initial `sqrtPriceX96` across all 10 slots in `afterInitialize`, so the first swap produces low-variance output rather than a cold-start error.

**Volatility multiplier: piecewise linear, capped band.**

The bonus pool funding multiplier is a piecewise function of `volatilityFactor` (WAD-scaled):

| volatilityFactor band | volatilityMultiplier |
|---|---|
| `<= 0.5 * WAD` | `1.0 * WAD` (flat) |
| `0.5 * WAD < x < 1.5 * WAD` | linear interpolation between `1.0 * WAD` and `1.5 * WAD` |
| `>= 1.5 * WAD` | `1.5 * WAD` (cap) |

Closed form for the linear band:

```
multiplier = WAD + ((volatilityFactor - 0.5 * WAD) * 0.5 * WAD) / WAD
```

Rejected alternative: pure linear from `0` upwards. Rejected because it would push `multiplier > 1.0x` in low-volatility regimes, inflating fee redistribution on stable-pair-like flow where the mechanism is not intended to be active. The flat 1.0x floor below `0.5 * WAD` keeps the hook a no-op on low-volatility pools (consistent with the Limitations section).

### Bonus Pool Funding

By design, the bonus pool is funded by a carve-out of the existing pool fee, routed through the `afterSwap` hook delta:

```
swapperPays:    poolFee (unchanged from baseline)
lpDirect:       poolFee * (1 - redistributionRate)
bonusPoolAdd:   poolFee * redistributionRate * volatilityMultiplier
```

Where `redistributionRate` defaults to 15% (configurable per pool), and `volatilityMultiplier` ranges 1.0x to 1.5x. The hook holds the `AFTER_SWAP_RETURNS_DELTA` permission flag for this carve-out, which keeps the swapper-facing fee unchanged and is compatible with any static fee tier.

Rejected alternative: a dynamic fee via `LPFeeLibrary` in `beforeSwap`. Rejected because it would either inflate the swapper-facing fee (violating the "swap costs remain unchanged" positioning) or require pools to be initialized in dynamic-fee mode (restricting deployment surface).

**Implementation status of the capture path.** The fee-capture wiring inside `afterSwap` (the `poolManager.take(...)` → `YieldRouter.supplyToAave(...)` step that moves the carved-out fee into the bonus pool) is **not wired in the current submission**. The score, tier, IL, and claim/distribution paths are complete and proven on-chain; the bonus pool is funded by supplying USDC to the router directly (the router holds aUSDC as a plain ERC-20 balance, which `claim`/`withdrawPendingClaim` read as the pool). For the on-chain demonstration, the router was funded with 100 USDC this way. Wiring the automatic `afterSwap` capture is the next implementation step and does not change any of the distribution mathematics, which is calibrated against the captured share.

### Bonus Pool Distribution

Bonus pool funds are held as aUSDC in the YieldRouter (supplied to Aave V3's USDC reserve, earning yield while idle). At claim time, the bonus pool (router aUSDC balance, which includes accrued Aave yield) is distributed in two arms:

**Tier-weighted arm (70%)**

Tier weight allocation: Gold 40%, Silver 35%, Bronze 25%. Within each tier, distribution is pro-rata based on the user's accumulated score relative to the live sum of all scores within that tier:

```
userTierShare = bonusPool * tierArm * tierAllocation * (userScore / sumOfTierScores[tier])
```

**Realized-IL arm (30%)**

Distributed proportionally to absolute realized IL across all positions that incurred IL. Tier-independent: any LP with non-zero closed IL participates:

```
userILShare = bonusPool * ilArm * (|userIL| / sumOfAbsoluteIL)
```

### Bonus Pool Accounting Unit

Internal accounting (`sumOfTierScores`, `sumOfAbsoluteIL`, `pendingScoreByTier`, per-position shares) is maintained in WAD scale (1e18). USDC is a 6-decimal token; the conversion to USDC-native units happens exactly once, at the transfer boundary in the payment flow:

```
usdcAmount = wadAmount * 1e6 / 1e18
```

Integer division truncates toward zero (Solidity default), rounding down in favor of the protocol rather than the claimant. A pending USDC debt (`pendingUsdc`, already USDC) is added after this conversion, never run through it.

Rejected alternative: store bonus pool in USDC-native (6 decimals), compute tier shares in WAD then scale down. Rejected because mixed-unit state increases the risk of decimal-mismatch bugs across the score formula (WAD), tier accounting, and IL math (WAD). A single WAD-internal convention with one boundary conversion is easier to audit.

### Claim Flow

Claims are initiated by the cached position owner:

```solidity
function claim(uint256 tokenId) external nonReentrant
```

Authorization is `msg.sender == streak.owner` (the owner cached at `notifySubscribe`), **not** a live `posm.ownerOf` read. A new owner of a transferred position arrives unsubscribed and must re-subscribe to accrue; they cannot claim a balance accrued under the previous owner. This is the one place a revert-on-bad-input is correct (the claim runs in the LP's own frame, not a notify bubble-up).

Claim flow (order is invariant):

1. If the streak is still active, settle the position's pending score and re-evaluate tier (a frozen/burned streak already had its final settle in `notifyBurn`, so it is not re-settled).
2. Compute the tier-weighted share against the live `sumOfTierScores[tier]`. Division is guarded against a zero denominator (zero share, no revert).
3. Compute the realized-IL share against the live `sumOfAbsoluteIL` (only positions with closed non-zero IL participate). Guarded the same way.
4. Sum the WAD shares and convert to USDC once at the transfer boundary.
5. **Effects before interactions:** decrement `sumOfTierScores[tier]` / `sumOfAbsoluteIL` by this position's contribution and zero its claimable state, before any external call.
6. Withdraw the total from Aave V3 via `YieldRouter.withdrawFromAave` (partial-fill safe; see Withdraw Failure Fallback). On a shortfall, the unpaid USDC is re-credited to `pendingUsdc[msg.sender]`.
7. Transfer the available USDC to the claimant.

`withdrawPendingClaim()` is the drain path for parked entitlements: for each tier it converts `pendingScoreByTier[msg.sender][tier]` to USDC against the live denominator, decrements `sumOfTierScores[tier]`, adds any `pendingUsdc` debt, and pays out under the same `nonReentrant` + CEI + Aave-fallback pattern as `claim`.

### YieldRouter (Aave V3 Integration)

The bonus pool is held as aUSDC in the `YieldRouter` and redeemed to USDC on payout. `YieldRouter` is a thin adapter that supplies USDC to Aave V3's USDC reserve and withdraws on claim. aToken accounting is delegated to Aave (scaled balance pattern), so the router maintains no separate yield ledger; the bonus pool is simply `IERC20(aUsdc).balanceOf(router)`.

**Access control: only the bound hook.** `YieldRouter.supplyToAave` and `withdrawFromAave` are gated by an `onlyHook` modifier. The hook address is set exactly once via `setHook` (owner-only, one-time bind), mirroring the `HoldfastNFT` trust boundary. The owner has no withdraw or emergency path: the router holds no idle USDC outside the bonus pool flow, so the blast radius of a router-only compromise is bounded by the bonus pool balance.

**Approve flow: infinite approval on deploy.** `YieldRouter` issues `type(uint256).max` USDC approval to the Aave V3 Pool once in the constructor. Aave V3 Pool is a widely-audited single counterparty whose blast radius is bounded to the router's balance.

**Withdraw failure fallback.** `YieldRouter.withdrawFromAave` wraps the Aave `withdraw` in a try/catch. On failure it does not revert the claim; it returns a partial-fill amount and emits `WithdrawFailed` with the reason. The payment flow consumes the returned amount and records any shortfall to `pendingUsdc`.

**Fork test target: Base mainnet Aave V3 at a pinned block.** Integration tests for the Aave supply/withdraw paths fork Base mainnet rather than Base Sepolia, because Base Sepolia's Aave deployment has sporadic reserve state that produces flaky fork tests. The fork block is pinned per test invocation via `--fork-block-number`. (The live deployment runs against Base Sepolia's Aave reserve, whose liveness was confirmed before deploy.)

### NFT Mechanics

When a position first crosses the Bronze threshold under the dual criterion, a badge NFT is minted. Subsequent tier upgrades update the same badge; new tokens are not minted on upgrade. The badge is a passive tier record: a tier indicator and per-position state marker.

**Badge key.** The badge is minted under `keccak256(abi.encode(tokenId, badgeEpoch[tokenId]))`. The per-subscription epoch is incremented on each owner change, so a new owner of a transferred position (or a returning owner after a round-trip) always mints a fresh, non-colliding badge and is never permanently blocked from reaching a tier.

**Mint timing.** The hook calls `HoldfastNFT.mint(to, badgeKey)` only when both `accumulatedScore >= BRONZE_THRESHOLD` AND `block.number - firstActiveBlock >= BRONZE_BLOCKS`. Upgrades follow the same dual-criterion check at Silver and Gold. The mint/upgrade calls are wrapped in `try/catch` so a badge-side revert cannot poison the never-revert notify path.

**Transferability.** Badges are non-transferable in the current design. The transferable asset is the canonical PositionManager position NFT; the badge is a tenure record bound to the position's subscription. (`HoldfastNFT` retains a transfer-settlement hook from an earlier design, which is unused on the subscriber path; badges are treated as non-transferable by design.)

### Position Lifecycle

- **Full closure (burn):** the streak freezes, the badge tier persists (no downgrade), score accumulation stops, and realized IL is computed at closure. The score stays in `sumOfTierScores` until the owner claims.
- **Partial closure:** liquidity is decremented by the removed amount; the score for the period before the removal is settled at the pre-removal liquidity, and subsequent accrual uses the reduced liquidity.
- **Transfer:** PositionManager auto-unsubscribes the position on transfer. The position arrives at the new owner unsubscribed; the new owner must re-subscribe to accrue. At re-subscribe, the prior owner's tiered score is finalized into `pendingScoreByTier` and the streak resets for the new owner.

## State

```solidity
struct PositionStreak {
    address owner;                   // cached from posm.ownerOf at notifySubscribe; claim auth source
    uint256 accumulatedScore;
    uint128 liquidity;               // baseline from getPositionLiquidity, tracked via notifyModifyLiquidity
    uint256 lastGlobalScoreSnapshot; // Curve gauge lazy update cursor
    uint256 firstActiveBlock;        // for tier minimum tenure check
    uint160 entrySqrtPriceX96;       // realized IL baseline
    uint8 currentTier;               // 0=none, 1=bronze, 2=silver, 3=gold
    uint256 nftTokenId;
    uint128 frozenAt;
    bool isFrozen;                   // best-effort from notifyUnsubscribe; never read by reconciliation
    bool isActive;
    int256 realizedIL;               // computed at burn, consumed by the realized-IL arm
    PoolId poolId;                   // cached from getPoolAndPositionInfo
    int24 tickLower;
    int24 tickUpper;
}

mapping(uint256 tokenId => PositionStreak) public streaks;

struct PoolVolatility {
    uint256[10] recentPriceObservations;
    uint8 cursor;
    uint256 cachedVolatility;
    uint256 lastVolUpdate;
}

mapping(PoolId => PoolVolatility) public volatility;

// Pool-level lazy update accumulator (Curve gauge style)
mapping(PoolId => uint256) public globalScorePerLiquidity;

// Tier accounting (WAD-scaled)
mapping(uint8 => uint256) public sumOfTierScores;   // tier => sum of accumulatedScore across positions in that tier
uint256 public sumOfAbsoluteIL;                     // sum of |realizedIL| across positions with closed non-zero IL

// Pending balances (separate units, separate semantics)
mapping(address => uint256[4]) public pendingScoreByTier; // WAD entitlement parked on owner change
mapping(address => uint256) public pendingUsdc;           // USDC debt from an Aave shortfall

// Per-subscription badge key epoch
mapping(uint256 tokenId => uint256) public badgeEpoch;

// USDC side resolution
mapping(PoolId => bool) public usdcIsToken0;
```

Position identity is the `tokenId`. There is no `hookData`-derived owner and no hook-computed position key; the position key used for badge minting is derived solely from `(tokenId, badgeEpoch)`.

## Gas Optimization: Lazy Update Pattern

The hook uses a Curve gauge-style accumulator. A single pool-level `globalScorePerLiquidity` variable increments on swap activity. Per-position scores are computed only on interaction (modify, burn, claim):

```
userScore += liquidity * (globalScore_now - globalScore_atLastUpdate)
```

This avoids iterating over all active positions on each swap. Realized IL is also lazy: computed only at claim or burn, not on every swap. Settle is routed through one shared helper invoked from `notifyModifyLiquidity`, `notifyBurn`, and `claim`, so the score and the tier denominator are always maintained in step.

## Design Decisions

### Oracle-Free Volatility

Volatility is derived from the pool's own swap pattern via a 10-observation ring buffer. No Chainlink, no Pyth. The pool's own swap pattern is the most direct volatility signal; oracles provide aggregated or delayed data. The 10-observation buffer plus the `firstActiveBlock` tenure gate raises manipulation cost above economic viability. An optional Chainlink TWAP adapter could be added in a future version.

### Linear liquidityShare, Not sqrt

Using `sqrt(liquidityShare)` would superficially reward small LPs but enables whale split sybil attacks (split one position into N, gain `N * sqrt(1/N) > 1` total reward). Wealth concentration mitigation is handled at the tier distribution layer (Bronze receives 25%, substantial relative to LP count). The score formula remains linear and sybil-resistant.

### ERC-721 Tier Badge

The badge is an ERC-721 for per-position isolated state and wallet/infrastructure UX maturity. It is a passive tier record; tier eligibility is enforced entirely in the hook (see Trust Boundary).

### Solady FixedPointMathLib over Solmate

The Uniswap v4-core dependency tree ships a minimal Solmate `FixedPointMathLib` (only `mulWadDown`, `sqrt`, `rpow`). Holdfast's `ScoreAccumulator.calculateRangeNarrowness` requires `lnWad`, not exposed there. Solady was added as a top-level dependency and remapped; its `lnWad` provides the needed WAD-precision signed-fixed-point primitive, and its `fullMulDiv` is used in the Q64.96 integer path of `calculateRealizedIL` and in `calculateVolatilityFactor`.

### OpenZeppelin v5

`HoldfastNFT` extends OpenZeppelin Contracts v5.6.1 (`ERC721`, `Ownable`). The top-level `lib/openzeppelin-contracts` install at v5.6.1 supersedes the v4-bundled version via remapping, ensuring a single OZ version resolves at compile time. OZ v5's `Ownable` requires an `initialOwner` constructor parameter and uses custom errors, which the NFT tests assert directly.

### Trust Boundary: Hook Authoritative, NFT Accounting Primitive

`HoldfastNFT` is a passive accounting primitive. Tier eligibility (the dual criterion) is validated exclusively in the hook. The NFT enforces its own invariants: only the bound hook can `mint`/`upgradeTier`; the hook address is set once via `setHook`; `upgradeTier` rejects downgrades and out-of-range tiers; a given badge key is minted at most once. The NFT does not re-check the dual-criterion thresholds, keeping tier logic in one place. The hook test suite asserts the dual criterion (whale-instant-Gold attempt, mint-timing, dual-criterion).

### Aave V3, Not a Mock

The composability dimension requires real protocol integration. Aave V3 integration is tested against a pinned Base mainnet fork (Base Sepolia's reserve state is sporadic) and runs live against Base Sepolia's reserve in deployment. Withdraw failure paths use try/catch with a fallback.

### IL Compensation Is Partial

The realized-IL arm captures only 30% of the bonus pool. Full IL hedging would require options primitives or external hedging infrastructure (e.g., BELTA, Antonio Furtado's IL Hedge Hook). Holdfast provides bounded partial compensation, explicit in its positioning.

### Dual Tier Criteria (Score + Block Count)

A pure score-based tier system is vulnerable to whale-instant-Gold: a high-liquidity position can reach the score threshold in under an hour. The minimum active block requirement enforces tenure mechanically. A 48-configuration whale parameter sweep confirms all whale configurations are blocks-gated; the worst-case whale reaches the Gold score threshold in ~1,256 blocks (~42 minutes), but the 100,000-block minimum enforces 2.31 days, a 79.6x slowdown.

### Redistribution Rate at 15%

Bonus pool funding is designed to draw 15% of pool fees. Lower rates (5 to 10%) weaken the bonus pool; higher rates (20 to 30%) penalize early-stage LPs before they qualify for any tier. 15% positions loyal LPs at marginal positive net return, mercenary LPs at marginal negative, and new LPs at reasonable time-to-breakeven. Configurable per pool.

### Tier-of-One Distribution

If a single LP is the only position in a given tier, that LP receives 100% of the tier's allocation. This is intended, consistent with the "rare by design" framing: tier scarcity is the reward signal, and the dual criterion makes a solo tier non-trivial to achieve. The on-chain demonstration exercised exactly this case (sole Bronze, 25% of the tier arm).

## Net LP Returns

The following table summarizes net LP returns across three calibration scenarios. All scenarios share: $1M monthly swap volume, 0.30% pool fee, 3% Aave V3 USDC supply APY (testnet estimate), LP holds 10% of pool liquidity, 70% tier-weighted arm fraction (the realized-IL arm at 30% is excluded as path-dependent and sanity-checked separately). Source: `scripts/sim/net_lp_returns.py`.

**Scenarios:**

- **Baseline (low-vol pool):** redistribution rate 15%, volatility multiplier 1.2x.
- **High-volatility pool:** redistribution rate 15%, volatility multiplier 2.0x.
- **Adjusted redistribution:** redistribution rate 20%, volatility multiplier 1.5x.

**Cross-scenario delta vs standard pool (in %, for an LP holding 10% of pool liquidity):**

| LP profile | Baseline (low-vol) | High-volatility | Adjusted redistribution |
|---|---|---|---|
| Mercenary (no tier) | -15.00% | -15.00% | -20.00% |
| Bronze (1 of 50, 2% intra-tier share) | -14.37% | -13.95% | -18.95% |
| Silver (1 of 10, 10% intra-tier share) | -10.58% | -7.64% | -12.64% |
| Silver (1 of 3, 30% intra-tier share) | -1.75% | +7.08% | +2.08% |
| Gold (1 of 3, 30% intra-tier share) | +0.14% | +10.23% | +5.23% |

**Calibration findings:**

- The baseline (low-vol) scenario produces a marginal Gold premium near zero, consistent with the Limitations section: Holdfast provides minimal LP benefit on low-volatility pools.
- The mechanism scales with pool volatility. The high-volatility scenario restores a meaningful loyal-LP premium (+10.23% at Gold) without changing the redistribution rate.
- Raising redistribution to 20% with a moderate volatility multiplier produces a more uniform premium and sharpens the mercenary penalty to -20%.
- The realized-IL arm (30%) is excluded; it applies only to positions that incurred IL and depends on the actual price path.
- Aave V3 supply yield on the bonus pool contributes a small positive offset in all scenarios.

**Recommended deployment:** target pools with >20% annualized volatility. Per-pool calibration of `redistributionRate` should account for the observed volatility regime; the parameter is set at initialization.

## Limitations

Holdfast is designed for a specific pool segment. It is not suitable for:

- **Low-volume pools** (<~100 swaps/day): the 10-observation volatility buffer retains stale data, degrading the volatility signal.
- **Low-volatility pools** (<20% annualized): the volatility multiplier remains near 1.0x, and fee redistribution provides minimal LP benefit; stablecoin pools fall into this category.
- **Range-bound pairs:** sideways markets produce low scores, making tier qualification difficult or impossible.
- **Non-USDC pools:** the bonus pool is held as USDC/aUSDC. The pool must contain USDC as one of its two tokens. Multi-token-to-USDC swap paths inside the hook are out of scope.

Implementation scope of the current submission:

- **Automatic fee capture is not yet wired** in `afterSwap` (see Bonus Pool Funding). The bonus pool is funded by direct USDC supply for now; the distribution mathematics is unchanged by this. Wiring the capture is the next step.
- **Badges are non-transferable** by design (the transferable asset is the posm position NFT).

Recommended deployment criteria: volatile pairs (>20% annualized historical volatility); active swap volume (~100+ swaps/day); one side of the pair must be USDC.

## Related Work

Each component of Holdfast exists independently in the ecosystem. The contribution is in their integrated combination:

| Component | Prior art |
|---|---|
| IL hedge | BELTA, Antonio Furtado's IL Hedge Hook, Makemake, Cork Depeg Swaps |
| Volatility-based dynamic fee | FlexFee (Brevis), Volatility Fee Hook, Realized Volatility Hook |
| Rehypothecation (Aave/Morpho integration) | Flaunch, Bunni, EulerSwap, Uniswap Foundation's Rehypothecation Hook initiative |
| Tenure-based fee adjustment | SuckerPunch, Timelock Loyalty Hook |
| Dynamic LP NFT tiers | Apeful, Unimon, general evolving LP NFT patterns |

Holdfast's contribution is the synthesis: IL-aware scoring + realized-IL compensation arm + tier-based retention + Aave-compounded rewards in a single subscriber-native hook. The project does not claim a novel primitive; it claims a disciplined integration.

## Attack Vectors and Mitigations

| Attack | Mitigation |
|---|---|
| Caller-asserted identity / score spoofing | Identity is the canonical PositionManager `tokenId`; ownership is read from the ERC-721 at subscribe. A caller cannot assert another party's identity, so the spoofing surface does not exist. |
| 1-tick range farming | Logarithmic `rangeNarrowness` plus minimum liquidity threshold |
| Flash loan transient liquidity | `firstActiveBlock` snapshot at subscribe; dual criterion (score + block count) prevents same-block tier qualification |
| Owner-change accrual theft | Claim auth is the cached `streak.owner`; at re-subscribe the prior owner's score is finalized into `pendingScoreByTier`, segregated by address, drainable only by that owner |
| Volatility manipulation (sandwich) | 10-observation ring buffer dampens single-swap impact; `fullMulDiv` prevents intermediate overflow |
| Whale split sybil | Linear `liquidityShare` in score formula (formula-level protection) |
| Whale-instant-Gold | Minimum active block requirement; 48-config sweep confirms all whale profiles blocks-gated (79.6x slowdown worst case) |
| Open/close farming | Streaks freeze rather than reset; no farming benefit |
| Reentrancy on claim | `ReentrancyGuard.nonReentrant` on `claim` and `withdrawPendingClaim`; checks-effects-interactions on payout |
| Aave withdraw failure | Try/catch with partial-fill fallback in `withdrawFromAave`; shortfall recorded to `pendingUsdc` |
| Aave Pool approval scope abuse | Infinite approval but router holds no USDC outside bonus pool flow; blast radius bounded to bonus pool balance |
| IL baseline manipulation | `entrySqrtPriceX96` is set once at subscribe and is immutable for the subscription |
| Notify-handler revert griefing | `notifyModifyLiquidity` / `notifyBurn` never revert (no external calls, no failing checks); badge mint/upgrade wrapped in try/catch |
| Dropped `notifyUnsubscribe` | Correctness does not depend on it; reconciliation is entirely in `notifySubscribe`, which never reads `isFrozen` |

## Scope

**In scope:**

- 4 contracts: `HoldfastHook` (BaseHook + ISubscriber), `HoldfastNFT`, `ScoreAccumulator`, `YieldRouter`
- Real Aave V3 integration on Base Sepolia
- Realized IL computation and compensation arm
- Dual tier criteria (score + minimum blocks)
- Foundry test suite (138 tests: unit, integration, fork)
- Base Sepolia deployment with on-chain end-to-end demonstration
- Minimal frontend (dashboard + subscribe + claim)
- Architecture diagram, README, demo video, pitch deck

**Out of scope / next steps:**

- Automatic `afterSwap` fee capture wiring (designed; bonus pool currently funded by direct supply)
- On-chain SVG metadata (using IPFS-hosted static images instead)
- ERC-6909 accrual token (direct USDC transfers instead)
- Comprehensive frontend (NFT gallery, advanced analytics)
- Full IL hedging via options primitives
- Multi-protocol yield routing (Morpho, Yearn, etc.)
- Chainlink TWAP volatility adapter
- Multi-token-to-USDC swap path inside the hook (pools must contain USDC)

## Deployment Target

- **Network:** Base Sepolia (chainId 84532)
- **Reasoning:** Mature Uniswap v4 deployment, Aave V3 testnet deployment available, 2-second block time for responsive demo, OP Stack architecture (portable to Unichain with minimal modification).
