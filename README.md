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

**Fee model.** Holdfast does not charge swappers any additional fee. A fixed portion (`redistributionRate`, default 15%) of the existing pool fee is redirected to the bonus pool inside `afterSwap`. Swap costs remain unchanged. (See the capture-path note under Deployed Contracts.)

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

## Composability: Aave V3

Holdfast integrates **Aave V3** as a real protocol dependency, not a mock:

- `src/YieldRouter.sol` wraps Aave V3 Pool supply/withdraw; the bonus pool is held as aUSDC
- `src/interfaces/IAaveV3Pool.sol` minimal interface (supply, withdraw, getReserveData)
- aUSDC yield is reflected in the bonus pool balance and distributed at claim time
- Integration is fork-tested against Base mainnet Aave V3 state in `test/fork/`
- Withdrawal failure is handled with try/catch and a `pendingUsdc` fallback path in the claim flow

Note: Aave is integrated for composability and yield, not as an official hookathon partner.

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

- HoldfastHook: `0xAbCada5D4ca9CD87E74F6ED3daA3974ad39d90c4`
- HoldfastNFT: `0x4D54F634Dc5461866d174825fCAaFD8481Fe6EC7`
- YieldRouter: `0xa24cbe3667fCAa4C3a53efB045b7bb5c5C698f57`
- Demo pool (WETH/USDC, 0.3%): poolId `0x066b6b57b4c1cf1031b59355cc6fc7db88cb29efb9258eaa2a3ecc49446c08b7`

**On-chain demonstration.** The full subscriber-native cycle has been exercised on Base Sepolia with real funds: a position was minted through the canonical PositionManager (tokenId 24915), subscribed to Holdfast, and accrued score through swap activity. The same swaps funded the bonus pool automatically through the live `afterSwap` capture path: the YieldRouter's aUSDC balance grew from zero purely from captured swap fees, with no manual seeding. After meeting the dual criterion (score threshold plus minimum tenure), a settle minted a tier badge, and a `claim` pays the position's tier-weighted share of the capture-funded pool, resetting its score and decrementing the tier denominator at the payment boundary.

**Capture-path status.** The automatic `afterSwap` fee-capture wiring (the `poolManager.take` and `YieldRouter.supplyToAave` calls that move the carved-out fee into the bonus pool, netted by the returned hook delta) is wired and live in the deployed contract. The bonus pool is funded from real swap fees, proven on Base Sepolia: the YieldRouter's aUSDC balance grows from swap activity with no manual seeding. The distribution mathematics is unchanged, calibrated against the captured share.

## Status

Deployed and live on Base Sepolia, with the end-to-end LP cycle demonstrated on-chain. Frontend live on Vercel.

## License

MITgitt
