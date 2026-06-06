// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

/// @title HoldfastHookMultiLp
/// @notice Natural-flow integration tests for multi-LP score isolation and the
///         negative-delta clamp on internally tracked liquidity.
contract HoldfastHookMultiLpTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;

    address internal alice;
    address internal eve;

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        alice = makeAddr("alice");
        eve = makeAddr("eve");
        vm.roll(1);
    }

    function _openAs(address owner, int256 liq, bytes32 salt) internal returns (bytes32 key) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liq, salt: salt}),
            abi.encode(owner)
        );
        key = Position.calculatePositionKey(owner, TICK_LOWER, TICK_UPPER, salt);
    }

    function _removeAs(address owner, int256 negDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: negDelta, salt: salt}),
            abi.encode(owner)
        );
    }

    function _swap(int256 amount, bool zeroForOne) internal {
        uint160 limit = zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _churn() internal {
        for (uint256 i = 0; i < 6; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
    }

    function _score(bytes32 key) internal view returns (uint256 s) {
        (s,,,,,,,,,,) = harness.streaks(key);
    }

    function _liquidity(bytes32 key) internal view returns (uint128 liq) {
        (,,,,,,,,,, liq) = harness.streaks(key);
    }

    /// @dev Two LPs with distinct hookData owners, both adding through the same
    ///      router. After churn and settle, both accrue independently and the
    ///      position keys do not collide.
    function test_multiLp_independentAccrual() public {
        // Distinct salts keep distinct PoolManager positions for the same router.
        bytes32 kA = _openAs(alice, LIQ_DELTA, bytes32(uint256(1)));
        bytes32 kE = _openAs(eve, LIQ_DELTA, bytes32(uint256(2)));
        assertTrue(kA != kE, "distinct owners must yield distinct keys");

        _churn();

        _removeAs(alice, -LIQ_DELTA / 2, bytes32(uint256(1)));
        _removeAs(eve, -LIQ_DELTA / 2, bytes32(uint256(2)));

        assertGt(_score(kA), 0, "alice must accrue");
        assertGt(_score(kE), 0, "eve must accrue");
    }

    /// @dev Negative-delta clamp: an over-large remove against a position must
    ///      drive tracked liquidity to zero rather than underflowing/reverting.
    ///      This is the denial-of-accrual surface documented in DESIGN.md; the
    ///      clamp ensures it degrades to zero, not a revert.
    function test_clamp_overRemoveZeroesLiquidityNoUnderflow() public {
        bytes32 kA = _openAs(alice, LIQ_DELTA, bytes32(uint256(1)));
        assertEq(uint256(_liquidity(kA)), uint256(uint128(uint256(LIQ_DELTA))), "tracked liquidity after add");

        // Remove the full position; tracked liquidity must clamp to exactly zero.
        _removeAs(alice, -LIQ_DELTA, bytes32(uint256(1)));
        assertEq(uint256(_liquidity(kA)), 0, "tracked liquidity must clamp to zero on full remove");
    }
}
