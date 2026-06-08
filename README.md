# Holdfast

A Uniswap v4 hook that measures IL exposure, partially compensates realized impermanent loss, and compounds rewards through Aave V3.

**UHI9 Capstone** · Base Sepolia · Solidity 0.8.26

## Overview

Holdfast is a Uniswap v4 hook designed for volatile pair pools. It addresses the mercenary capital problem in concentrated liquidity provisioning by combining four mechanisms:

1. **Risk-weighted scoring:** each LP position accumulates a score based on liquidity share, range narrowness, and pool volatility
2. **Partial IL compensation:** realized impermanent loss is computed at claim time, and a portion of the bonus pool is distributed proportionally to IL incurred
3. **Tier-based retention rewards:** Bronze, Silver, and Gold tiers gate access to bonus pool shares
4. **Yield compounding via Aave V3:** bonus pool funds are supplied to Aave V3 while idle, generating additional yield

**Honest positioning.** Holdfast is not a full IL hedge. It measures IL exposure, partially compensates realized IL from a bonus pool, and provides retention incentives for LPs who stay through high-volatility periods.

**Fee model.** Holdfast does not charge swappers any additional fee. A fixed portion (`redistributionRate`, default 15%) of the existing pool fee is designed to be redirected to the bonus pool. Swap costs remain unchanged. (See the capture-path note under Deployed Contracts for the current implementation status.)

For the complete specification (identity model, mechanics, formulas, attack vectors, design decisions), see [`docs/DESIGN.md`](docs/DESIGN.md).

## Identity Model

Holdfast is a subscriber-native hook. The contract is simultaneously a Uniswap v4 `BaseHook` and a canonical PositionManager `ISubscriber`, and per-position state is keyed by the PositionManager ERC-721 `tokenId`. Position ownership is read from the canonical PositionManager and cached at subscription; there is no caller-asserted `hookData` owner and no hook-computed position key. One identity (the `tokenId`), one ownership source (the ERC-721), so a hook-side key can never diverge from the canonical position.

LPs interact in two steps: mint a position in the PositionManager, then `posm.subscribe(tokenId, holdfast, "")` to begin accruing.

## Architecture

Four contracts:

- `src/HoldfastHook.sol` a single contract that is both a v4 `BaseHook` (afterInitialize, beforeSwap, afterSwap) and an `ISubscriber` (notifySubscribe, notifyModifyLiquidity, notifyBurn, notifyUnsubscribe); holds the score/tier/claim logic
- `src/HoldfastNFT.sol` ERC-721 tier badge (Bronze/Silver/Gold) with IPFS-hosted tier images
- `src/libraries/ScoreAccumulator.sol` pure library for block score, range narrowness, volatility factor, and realized IL math
- `src/YieldRouter.sol` Aave V3 supply/withdraw with try/catch fallback

## Partner Integrations

**Aave V3** is integrated as a real protocol dependency, not a mock:

- `src/YieldRouter.sol` wraps Aave V3 Pool supply/withdraw; the bonus pool is held as aUSDC
- `src/interfaces/IAaveV3Pool.sol` minimal interface (supply, withdraw, getReserveData)
- aUSDC yield is reflected in the bonus pool balance and distributed at claim time
- Integration is fork-tested against Base mainnet Aave V3 state in `test/fork/`
- Withdrawal failure is handled with try/catch and a `pendingUsdc` fallback path in the claim flow

## Tests

Run the suite:

```bash
forge test
```

Run fork tests (requires a Base mainnet RPC for the pinned Aave V3 fork):

```bash
export BASE_RPC_URL=https://your-base-rpc-endpoint
forge test --match-path "test/fork/**" --fork-url $BASE_RPC_URL
```

Test summary:

- 138 tests across unit, integration, and fork suites
- Unit coverage includes the score/volatility/realized-IL math and attack vectors (whale-instant-Gold, sybil split, IL baseline immutability, reentrancy guards)
- Integration coverage includes natural-flow subscriber tests: owner-transfer reconciliation, multi-LP tier isolation, partial liquidity removal settle-ordering, and dropped-unsubscribe handling
- Fork tests exercise the Aave V3 supply/withdraw paths against a pinned Base mainnet block
- 5 Python simulations under `scripts/sim/` calibrate tier thresholds, whale mitigation, net LP returns across volatility regimes, the realized IL formula, and the volatility scale factor

## Frontend

A minimal vanilla JS frontend with viem is included in `frontend/`:

- Single HTML page, no build step required
- Wallet connect with Base Sepolia network add
- Position display with tier badges and dual-criterion progress bars
- Two-step flow: mint a position in the PositionManager, then subscribe to Holdfast
- Bonus pool overview (YieldRouter aUSDC balance)
- Claim button per qualified position

Live demo (Base Sepolia): https://frontend-delta-six-49.vercel.app

## Setup

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation)

```bash
git clone https://github.com/eylulbalcilar/holdfast-hook.git
cd holdfast-hook
forge install
forge build
forge test
```

## Environment

Copy `.env.example` to `.env` and fill in:

- `BASE_SEPOLIA_RPC_URL` Base Sepolia RPC endpoint (for deployment)
- `BASE_RPC_URL` Base mainnet RPC endpoint (for fork tests)
- `PRIVATE_KEY` deployer key (testnet only)
- `BASESCAN_API_KEY` for contract verification

## Deployment

The hook is deployed via `script/DeployV2.s.sol`, which mines a CREATE2 salt so the hook address encodes the exact permission flags (`afterInitialize`, `beforeSwap`, `afterSwap`, `afterSwapReturnsDelta`), deploys the NFT and YieldRouter, deploys the hook at the mined address, and binds them via `setHook`.

```bash
forge script script/DeployV2.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

## Deployed Contracts (Base Sepolia, chainId 84532)

- HoldfastHook: `0xC7B5f55C6a1EaB55EDbe72cA7e3c4cA1Bd9b90c4`
- HoldfastNFT: `0x3caA1d58c469390cE301c05C5b0c545EAF21903a`
- YieldRouter: `0x1de3015754e615d31aCA1FF474c74640886c3Eff`
- Demo pool (WETH/USDC, 0.3%): poolId `0x34398458184a32104fd796e49297df6992988b18ed4336f221ba9a221c5cbc51`

**On-chain demonstration.** The full subscriber-native cycle has been exercised on Base Sepolia with real funds: a position was minted through the canonical PositionManager (tokenId 24715), subscribed to Holdfast, accrued score through swap activity, crossed the Bronze tier (badge minted) after meeting the dual criterion, and `claim` paid out the Bronze tier-weighted share (17.5 USDC) of a 100 USDC bonus pool, resetting the position's score and decrementing the tier denominator at the payment boundary.

**Capture-path status.** The automatic `afterSwap` fee-capture wiring (moving the carved-out fee into the bonus pool) is not yet wired in this submission. The score, tier, IL, and claim/distribution paths are complete and proven on-chain; the bonus pool is funded by supplying USDC to the router directly. The distribution mathematics is unchanged by this. Wiring the automatic capture is the next step.

## Status

Deployed and live on Base Sepolia, with the end-to-end LP cycle demonstrated on-chain. Frontend live on Vercel.

## License

MITgitt
