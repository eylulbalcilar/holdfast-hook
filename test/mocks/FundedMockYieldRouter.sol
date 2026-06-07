// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice YieldRouter mock that holds a real USDC balance so the claim / withdraw payout path
///         is observable in tests.
/// @dev aUsdc points at the USDC token itself, so the hook's
///      `IERC20(yieldRouter.aUsdc()).balanceOf(address(yieldRouter))` reads this router's USDC
///      balance as the bonus pool. withdrawFromAave transfers up to the requested amount to the
///      caller (the hook), mirroring the real router which withdraws to the bound hook, and
///      returns the actual amount paid (partial-fill safe). The bound-hook check is omitted; the
///      caller is always the hook in these tests.
contract FundedMockYieldRouter {
    IERC20 internal immutable _usdc;

    constructor(address usdc_) {
        _usdc = IERC20(usdc_);
    }

    function aUsdc() external view returns (address) {
        return address(_usdc);
    }

    function supplyToAave(uint256) external {}

    function withdrawFromAave(uint256 amount) external returns (uint256) {
        uint256 bal = _usdc.balanceOf(address(this));
        uint256 pay = amount <= bal ? amount : bal;
        if (pay > 0) {
            require(_usdc.transfer(msg.sender, pay), "FundedMockYieldRouter: transfer failed");
        }
        return pay;
    }
}
