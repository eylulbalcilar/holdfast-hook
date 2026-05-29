// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";

/// @title YieldRouter
/// @notice Thin Aave V3 adapter that holds the Holdfast bonus pool as real USDC,
///         supplies it to Aave V3's USDC reserve, and withdraws on claim.
/// @dev Access control mirrors `HoldfastNFT`: a single bound hook address is the
///      only privileged caller for `supplyToAave` and `withdrawFromAave`. The
///      hook is bound exactly once via `setHook` (owner-only, one-time). The
///      owner has no withdraw or emergency path; see DESIGN.md for the
///      rationale (minimal trust surface, bonus pool reconstructible from
///      on-chain state). aToken accounting is delegated to Aave (scaled balance
///      pattern); the router does not maintain a parallel yield ledger.
contract YieldRouter is Ownable {
    // -------------------------------------------------------------------------
    // Immutable state
    // -------------------------------------------------------------------------

    /// @notice The Aave V3 Pool contract.
    IAaveV3Pool public immutable aavePool;

    /// @notice The underlying asset supplied to Aave (USDC on the target chain).
    IERC20 public immutable usdc;

    /// @notice The aToken address corresponding to `usdc`, cached at deploy.
    /// @dev Read once from Aave's `getReserveData(usdc).aTokenAddress` in the
    ///      constructor. The aToken address for a reserve does not change in
    ///      Aave V3 once the reserve is initialized, so caching is safe.
    address public immutable aUsdc;

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------

    /// @notice The bound hook contract. Set exactly once via `setHook`.
    address public hook;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted once when the hook is bound.
    event HookSet(address indexed hook);

    /// @notice Emitted on every successful supply to Aave.
    event Supplied(uint256 amount);

    /// @notice Emitted on every successful withdraw from Aave.
    event Withdrawn(uint256 requested, uint256 actual);

    /// @notice Emitted when Aave `withdraw` reverts and the fallback path
    ///         returns zero. The router emits the underlying revert reason.
    event WithdrawFailed(uint256 requested, bytes reason);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotHook();
    error HookAlreadySet();
    error ZeroAddress();
    error ZeroAmount();
    error AaveReserveInactive();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _aavePool Aave V3 Pool address.
    /// @param _usdc USDC underlying asset address.
    /// @param _owner Owner address (used only for `setHook` binding).
    constructor(address _aavePool, address _usdc, address _owner) Ownable(_owner) {
        if (_aavePool == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();

        aavePool = IAaveV3Pool(_aavePool);
        usdc = IERC20(_usdc);

        // Cache the aToken address for the USDC reserve. Reverts implicitly if
        // the reserve is not configured (Aave returns the zero address, which
        // we explicitly check below).
        address _aUsdc = IAaveV3Pool(_aavePool).getReserveData(_usdc).aTokenAddress;
        if (_aUsdc == address(0)) revert AaveReserveInactive();
        aUsdc = _aUsdc;

        // Infinite approval to Aave Pool. Decision 3/A: blast radius is bounded
        // to the router's USDC balance (which equals the bonus pool flow), and
        // the per-supply approval alternative does not actually shrink that
        // surface. See DESIGN.md "Approve flow" subsection.
        IERC20(_usdc).approve(_aavePool, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Hook binding (one-time, owner-only)
    // -------------------------------------------------------------------------

    /// @notice Binds the hook address. Callable exactly once by the owner.
    /// @param _hook The HoldfastHook contract address.
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (_hook == address(0)) revert ZeroAddress();
        hook = _hook;
        emit HookSet(_hook);
    }

    // -------------------------------------------------------------------------
    // Supply / withdraw
    // -------------------------------------------------------------------------

    /// @notice Supplies `amount` of USDC from the router's balance to Aave V3.
    /// @dev The hook is expected to transfer `amount` USDC to the router before
    ///      calling this function. The router does not pull from the hook; it
    ///      supplies whatever USDC it holds, up to `amount`. If the router's
    ///      balance is insufficient, Aave's underlying transferFrom reverts and
    ///      the whole transaction is reverted (no silent partial supply).
    /// @param amount The amount of USDC to supply.
    function supplyToAave(uint256 amount) external onlyHook {
        if (amount == 0) revert ZeroAmount();

        aavePool.supply(address(usdc), amount, address(this), 0);

        emit Supplied(amount);
    }

    /// @notice Withdraws `amount` of USDC from Aave V3 directly to the bound
    ///         hook. On Aave failure, returns 0 and emits `WithdrawFailed`; the
    ///         caller is expected to reconcile a zero-fill.
    /// @dev Aave V3's `withdraw` accepts `type(uint256).max` as a sentinel for
    ///      the full aToken balance; callers may pass that value through.
    /// @param amount The amount of USDC to withdraw, or `type(uint256).max`.
    /// @return actual The amount actually transferred to the hook; 0 on failure.
    function withdrawFromAave(uint256 amount) external onlyHook returns (uint256 actual) {
        if (amount == 0) revert ZeroAmount();

        try aavePool.withdraw(address(usdc), amount, hook) returns (uint256 returned) {
            actual = returned;
            emit Withdrawn(amount, returned);
        } catch (bytes memory reason) {
            actual = 0;
            emit WithdrawFailed(amount, reason);
        }
    }
}
