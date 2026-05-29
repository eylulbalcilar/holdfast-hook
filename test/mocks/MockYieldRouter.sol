// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice No-op mock of `YieldRouter` for unit tests.
/// @dev `HoldfastHook` holds a reference to a YieldRouter but does not yet
///      route real USDC through it (see DESIGN.md "YieldRouter wiring scope").
///      Unit tests use this mock to satisfy the constructor signature without
///      pulling in Aave V3 dependencies. The mock matches the public surface
///      of `YieldRouter` that the hook touches; expand as that surface grows.
contract MockYieldRouter {
    event SupplyCalled(uint256 amount);
    event WithdrawCalled(uint256 amount);

    function supplyToAave(uint256 amount) external {
        emit SupplyCalled(amount);
    }

    function withdrawFromAave(uint256 amount) external returns (uint256) {
        emit WithdrawCalled(amount);
        return amount;
    }
}
