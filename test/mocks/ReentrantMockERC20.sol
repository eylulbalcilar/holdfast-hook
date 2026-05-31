// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-20 stub whose transfer() calls back into a target contract.
/// @dev Used exclusively to test ReentrancyGuard on claim() and withdrawPendingClaim().
contract ReentrantMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name     = "ReentrantUSDC";
    string public symbol   = "rUSDC";
    uint8  public decimals = 6;

    address public reentryTarget;
    bytes   public reentryCalldata;
    bool    private _inTransfer;

    function setReentryTarget(address target, bytes calldata data) external {
        reentryTarget  = target;
        reentryCalldata = data;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;

        // Callback on first transfer only (prevent infinite recursion).
        if (reentryTarget != address(0) && !_inTransfer) {
            _inTransfer = true;
            (bool ok,) = reentryTarget.call(reentryCalldata);
            // Ignore revert from reentry attempt; test asserts on state.
            ok;
            _inTransfer = false;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}
