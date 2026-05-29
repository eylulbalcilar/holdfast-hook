// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal subset of the Aave V3 Pool interface used by `YieldRouter`.
/// @dev Only the three methods Holdfast invokes are declared here: `supply`,
///      `withdraw`, and `getReserveData`. The full Aave interface is much
///      larger; reproducing it would expand the audit surface without benefit.
///      Reference: https://github.com/aave/aave-v3-core
interface IAaveV3Pool {
    /// @notice Supplies an `amount` of `asset` into the reserve, receiving the
    ///         corresponding aTokens in return.
    /// @param asset The address of the underlying asset to supply.
    /// @param amount The amount of asset to supply.
    /// @param onBehalfOf The address that will receive the aTokens; the same
    ///        as `msg.sender` if the supplier wants to receive them.
    /// @param referralCode Inactive in Aave V3; pass 0.
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraws an `amount` of `asset` from the reserve, burning the
    ///         equivalent aTokens.
    /// @param asset The address of the underlying asset to withdraw.
    /// @param amount The underlying amount to withdraw, or `type(uint256).max`
    ///        to withdraw the full aToken balance.
    /// @param to The address that will receive the underlying.
    /// @return The actual amount withdrawn.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    /// @notice Returns the state and configuration of a reserve.
    /// @dev The struct layout matches Aave V3's `DataTypes.ReserveData`. Only
    ///      the `aTokenAddress` field is consumed by `YieldRouter`, but the
    ///      full struct is returned by the ABI and cannot be partially decoded.
    /// @param asset The address of the underlying asset of the reserve.
    /// @return The reserve data.
    function getReserveData(address asset) external view returns (ReserveData memory);

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    struct ReserveConfigurationMap {
        uint256 data;
    }
}
