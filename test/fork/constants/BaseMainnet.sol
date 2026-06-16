// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Base mainnet addresses for fork tests and deploy scripts.
/// @dev Fork tests target Base mainnet for Aave V3 integration; see DESIGN.md
///      "Fork test target". Deploy.s.sol also consumes these constants when
///      targeting an Anvil fork of Base mainnet (--chain-id 8453).
/// @dev Must not be imported from `src/`: production code targets Base Sepolia
///      (see BaseSepoliaAddresses in src/constants/Addresses.sol).
library BaseMainnet {
    address internal constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    // Uniswap v4 (Base mainnet), verified on docs.uniswap.org/contracts/v4/deployments
    // PoolSwapTest and PoolModifyLiquidityTest are NOT deployed on Base mainnet;
    // fork tests deploy them locally against the canonical PoolManager.
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Canonical PositionManager (the ISubscriber counterparty in V2). Verified on the pinned
    // fork block: its poolManager() returns POOL_MANAGER above. The V2 capture fork test passes
    // it to the HoldfastHookV2 constructor; the capture path itself never calls it.
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
}
