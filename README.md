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

- `HoldfastHook.sol` — v4 lifecycle integration
- `HoldfastNFT.sol` — ERC-721 tier representation with mutable metadata
- `ScoreAccumulator.sol` — pure library for score and realized IL math
- `YieldRouter.sol` — Aave V3 supply/withdraw

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

- `BASE_SEPOLIA_RPC_URL` — RPC endpoint
- `PRIVATE_KEY` — deployer key (testnet only)
- `BASESCAN_API_KEY` — for contract verification

## Status

Preparation phase, day 1 of 28. Submission: June 11, 2026.

## License

MIT
EOF
