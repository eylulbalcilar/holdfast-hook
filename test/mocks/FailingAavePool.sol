// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";

/// @notice Minimal mock that delegates `getReserveData` and `supply` to a real
///         Aave V3 Pool but forces `withdraw` to revert with a fixed reason.
/// @dev Used in fork tests to exercise the `withdrawFromAave` try/catch
///      fallback path deterministically without needing to drive Aave into a
///      genuine revert condition.
contract FailingAavePool is IAaveV3Pool {
    IAaveV3Pool public immutable realPool;

    error WithdrawFailedMock();

    constructor(IAaveV3Pool _realPool) {
        realPool = _realPool;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        realPool.supply(asset, amount, onBehalfOf, referralCode);
    }

    function withdraw(address, uint256, address) external pure returns (uint256) {
        revert WithdrawFailedMock();
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        return realPool.getReserveData(asset);
    }
}
