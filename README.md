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

**Fee model.** Holdfast does not charge swappers any additional fee. A fixed portion (`redistributionRate`, default 15%) of the existing pool fee is redirected to the bonus pool. Swap costs remain unchanged.

For the complete specification (mechanics, formulas, attack vectors, design decisions, anticipated mentor Q&A), see [`docs/DESIGN.md`](docs/DESIGN.md).

## Architecture

Four contracts:

- `src/HoldfastHook.sol` v4 lifecycle integration: afterInitialize, afterAddLiquidity, beforeSwap, afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity, claim, settleOnTransfer
- `src/HoldfastNFT.sol` ERC-721 tier representation with mutable metadata, OpenZeppelin v5 `_update` callback for accrual-theft prevention
- `src/libraries/ScoreAccumulator.sol` pure library for block score, range narrowness, volatility factor, and realized IL math
- `src/YieldRouter.sol` Aave V3 supply/withdraw with try/catch fallback

## Partner Integrations

**Aave V3** is integrated as a real protocol dependency, not a mock:

- `src/YieldRouter.sol` wraps Aave V3 Pool supply/withdraw
- `src/interfaces/IAaveV3Pool.sol` minimal interface (supply, withdraw, getReserveData)
- Bonus pool USDC is supplied to Aave V3 USDC reserve when funds accrue
- aUSDC yield is reflected in the bonus pool balance and distributed at claim time
- Integration is fork-tested against Base mainnet Aave V3 state in `test/fork/YieldRouter.fork.t.sol`
- Withdrawal failure is handled with try/catch and a `pendingClaim` fallback path in `HoldfastHook.settleOnTransfer` and `HoldfastHook.claim`

## Tests

Run the unit suite:

```bash
forge test
```

Run fork tests (requires `BASE_RPC_URL` for Base mainnet):

```bash
export BASE_RPC_URL=https://your-base-rpc-endpoint
forge test --match-path "test/fork/**" --fork-url $BASE_RPC_URL
```

Test summary:

- 121 unit tests across `test/unit/` (10 test files)
- 7 fork tests against Base mainnet Aave V3 (`test/fork/`)
- Coverage includes attack vectors (whale-instant-Gold, sybil split, IL baseline immutability, reentrancy guards) and edge cases (USDC denomination requirement, hookData validation, pendingClaim retry, tier-of-one math precision)
- 4 Python simulations under `scripts/sim/` calibrate tier thresholds, whale mitigation, net LP returns across volatility regimes, and the realized IL formula

## Frontend

A minimal vanilla JS frontend with viem is included in `frontend/`:

- Single HTML page, no build step required
- MetaMask wallet connect with Base Sepolia network add
- User position display with tier badges and dual-criterion progress bars
- Bonus pool overview (USDC tracker + Aave aUSDC balance)
- Claim button per qualified position
- Block polling for state refresh

Run locally against Anvil:

```bash
anvil --fork-url $BASE_RPC_URL
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
cd frontend && python3 -m http.server 8000
```

Open `http://localhost:8000` in a browser with MetaMask configured.

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

## Deployed Contracts (Base Sepolia, chainId 84532)

All contracts verified on Basescan.

- HoldfastHook: `0xE793eaf666ED37ef8573784f8c5fc33920dF57c4`
- HoldfastNFT: `0x5a3a19952E6eeAA2f5bF41977ffbF1C106092097`
- YieldRouter: `0x0F77E49237c88242652788dfCC829a61AA250C1A`
- Demo pool (WETH/USDC, 0.3%): poolId `0x10ad9a3049c38eca566db11f305f4663ff7b68a2022a860e97e99d69dddebe9f`

The demo pool is seeded with liquidity and swaps; the bonus pool has captured swap fees and supplied them to Aave V3 (visible as the aUSDC balance in the frontend).

## Status

Deployed and verified on Base Sepolia. Frontend live on Vercel. End-to-end testnet smoke test (Bronze tier claim) pending the dual-criterion block minimum. Submission: June 11. Demo Day: June 19.

## License

MIT
