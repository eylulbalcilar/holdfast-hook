// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract AccumulatorTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        vm.roll(1);
    }

    function _open(int256 liq, bytes32 salt) internal returns (bytes32 key) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liq, salt: salt}),
            _ownerHookData()
        );
        key = Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, salt);
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

    function _remove(int256 negDelta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: negDelta, salt: salt}),
            _ownerHookData()
        );
    }

    function _score(bytes32 key) internal view returns (uint256 s) {
        s = harness.getStreak(key).accumulatedScore;
    }

    function _churn() internal {
        for (uint256 i = 0; i < 6; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
    }

    function test_acc_scoreAccruesAfterChurn() public {
        bytes32 k1 = _open(LIQ_DELTA, bytes32(0));
        assertEq(_score(k1), 0, "no score before swaps");
        _churn();
        _remove(-LIQ_DELTA / 2, bytes32(0));
        assertGt(_score(k1), 0, "score accrues after churn + settle");
    }

    function test_acc_noSettleNoChurnStaysZero() public {
        bytes32 k1 = _open(LIQ_DELTA, bytes32(0));
        _remove(-LIQ_DELTA / 2, bytes32(0));
        assertEq(_score(k1), 0, "no global movement means no score");
    }

    function test_acc_pathIndependentSettle() public {
        bytes32 kA = _open(LIQ_DELTA, bytes32(uint256(1)));
        bytes32 kB = _open(LIQ_DELTA, bytes32(uint256(2)));

        for (uint256 i = 0; i < 3; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
        _remove(-1, bytes32(uint256(2)));

        for (uint256 i = 0; i < 3; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
        _remove(-1, bytes32(uint256(1)));
        _remove(-1, bytes32(uint256(2)));

        uint256 sA = _score(kA);
        uint256 sB = _score(kB);
        assertApproxEqAbs(sA, sB, 1e6, "split settle must match single settle");
    }

    function test_acc_linearInLiquidity() public {
        bytes32 k1 = _open(LIQ_DELTA, bytes32(uint256(10)));
        bytes32 k2 = _open(2 * LIQ_DELTA, bytes32(uint256(20)));
        _churn();
        _remove(-1, bytes32(uint256(10)));
        _remove(-1, bytes32(uint256(20)));

        uint256 s1 = _score(k1);
        uint256 s2 = _score(k2);
        assertGt(s1, 0, "base position accrues");
        assertApproxEqRel(s2, 2 * s1, 0.02e18, "double liquidity yields ~double score");
    }
}
