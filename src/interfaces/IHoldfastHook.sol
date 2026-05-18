// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IHoldfastHook
/// @notice Callback interface implemented by HoldfastHook, consumed by HoldfastNFT.
/// @dev HoldfastNFT calls settleOnTransfer in its _update override (OZ v5) to settle
///      accrued rewards to the original owner before transfer, preventing accrual theft.
interface IHoldfastHook {
    /// @notice Settle accrued rewards for a position before NFT transfer.
    /// @param positionKey keccak256(abi.encode(owner, tickLower, tickUpper, salt))
    /// @param from current NFT owner (recipient of settlement)
    /// @param to incoming NFT owner
    function settleOnTransfer(bytes32 positionKey, address from, address to) external;
}
