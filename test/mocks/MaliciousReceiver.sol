// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Contract that attempts to reenter claim() or withdrawPendingClaim()
///         when it receives a callback from ReentrantMockERC20.transfer().
contract MaliciousReceiver {
    address public hook;
    bytes   public attackCalldata;
    bool    public reentryAttempted;
    bool    public reentryReverted;

    function setAttack(address _hook, bytes calldata data) external {
        hook           = _hook;
        attackCalldata = data;
    }

    /// @notice Called by ReentrantMockERC20 mid-transfer.
    fallback() external {
        _tryReentry();
    }

    receive() external payable {
        _tryReentry();
    }

    /// @notice Direct callback path used by ReentrantMockERC20.
    function onTransfer() external {
        _tryReentry();
    }

    function _tryReentry() internal {
        if (hook == address(0)) return;
        reentryAttempted = true;
        (bool ok,) = hook.call(attackCalldata);
        reentryReverted = !ok;
    }
}
