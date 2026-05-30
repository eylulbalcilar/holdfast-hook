// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Base mainnet addresses used by fork tests.
/// @dev Fork tests target Base mainnet (not Base Sepolia) for Aave V3
///      integration; see DESIGN.md "Fork test target". These addresses are
///      test-only and must not be imported from `src/`.
library BaseMainnet {
    address internal constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    // Uniswap v4 (Base mainnet) - verified on docs.uniswap.org/contracts/v4/deployments
    // PoolSwapTest and PoolModifyLiquidityTest are NOT deployed on Base mainnet;
    // fork tests deploy them locally against the canonical PoolManager.
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
}
