// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseSepoliaAddresses} from "../../src/constants/Addresses.sol";

/// @notice Base Sepolia deployment addresses consumed by Deploy.s.sol.
/// @dev Thin wrapper around src/constants/Addresses.sol so deploy-side
///      constants live under script/constants/ next to BaseMainnet (test/fork/constants).
library BaseSepoliaConstants {
    uint256 internal constant CHAIN_ID = 84532;

    address internal constant POOL_MANAGER = BaseSepoliaAddresses.POOL_MANAGER;
    address internal constant AAVE_V3_POOL = BaseSepoliaAddresses.AAVE_POOL;
    address internal constant USDC = BaseSepoliaAddresses.USDC;
    address internal constant WETH = BaseSepoliaAddresses.WETH;

    uint8 internal constant USDC_DECIMALS = BaseSepoliaAddresses.USDC_DECIMALS;
}
