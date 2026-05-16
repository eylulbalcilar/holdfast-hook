// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Holdfast deployment addresses for Base Sepolia (chainId 84532)
/// @notice Sources verified on May 16, 2026
/// @dev Uniswap v4: docs.uniswap.org/contracts/v4/deployments
/// @dev Aave V3: github.com/bgd-labs/aave-address-book (AaveV3BaseSepolia.sol)
library BaseSepoliaAddresses {
    uint256 internal constant CHAIN_ID = 84532;

    // --- Uniswap v4 ---
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant UNIVERSAL_ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address internal constant STATE_VIEW = 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4;
    address internal constant QUOTER = 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // --- Aave V3 ---
    address internal constant AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address internal constant AAVE_POOL_ADDRESSES_PROVIDER = 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00;

    // --- Aave V3 USDC reserve (Aave testnet mintable USDC, not Circle's USDC) ---
    address internal constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address internal constant A_USDC = 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC;
    address internal constant USDC_ORACLE = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    uint8 internal constant USDC_DECIMALS = 6;

    // --- Aave V3 other tokens (available in testnet faucet, may be useful for demo pools) ---
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant WBTC = 0x54114591963CF60EF3aA63bEfD6eC263D98145a4;
    address internal constant LINK = 0x810D46F9a9027E28F9B01F75E2bdde839dA61115;
}
