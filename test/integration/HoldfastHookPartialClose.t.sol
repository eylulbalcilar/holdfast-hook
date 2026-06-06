// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

/// @title HoldfastHookPartialClose
/// @notice Natural flow: add, accrue, partial remove, accrue more, full remove.
///         Verifies score keeps accruing after a partial close and tracked
///         liquidity follows the partial decrement down to zero on full close.
contract HoldfastHookPartialCloseTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;

    address internal lp;

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        lp = makeAddr("lp");
        vm.roll(1);
    }

    function _open() internal returns (bytes32 key) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQ_DELTA, salt: bytes32(0)}),
            abi.encode(lp)
        );
        key = Position.calculatePositionKey(lp, TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _remove(int256 negDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: negDelta, salt: bytes32(0)}),
            abi.encode(lp)
        );
    }

    function _swap(int256 amt, bool zfo) internal {
        uint160 limit = zfo ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zfo, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _churn(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
    }

    function test_partialClose_scoreKeepsAccruing() public {
        bytes32 key = _open();

        // First accrual window, then settle via a 50% partial remove.
        _churn(6);
        _remove(-LIQ_DELTA / 2);

        HoldfastHook.PositionStreak memory s1 = harness.getStreak(key);
        assertGt(s1.accumulatedScore, 0, "score must accrue before partial close");
        assertTrue(s1.isActive, "partial close must keep the streak active");
        assertEq(uint256(s1.liquidity), uint256(uint128(uint256(LIQ_DELTA / 2))), "tracked liquidity halved");

        // Second accrual window on the reduced position, then settle via another remove.
        _churn(6);
        _remove(-LIQ_DELTA / 4);

        HoldfastHook.PositionStreak memory s2 = harness.getStreak(key);
        assertGt(s2.accumulatedScore, s1.accumulatedScore, "score must keep accruing after partial close");
        assertTrue(s2.isActive, "still active after second partial remove");

        // Full close of the remaining quarter freezes the streak and zeroes liquidity.
        _remove(-LIQ_DELTA / 4);
        HoldfastHook.PositionStreak memory s3 = harness.getStreak(key);
        assertEq(uint256(s3.liquidity), 0, "tracked liquidity zero on full close");
        assertTrue(!s3.isActive, "streak frozen on full close");
        assertGe(s3.accumulatedScore, s2.accumulatedScore, "score preserved on full close");
    }
}
