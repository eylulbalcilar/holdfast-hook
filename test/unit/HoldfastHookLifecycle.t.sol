// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";

contract HoldfastHookLifecycleTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    function setUp() public {
        _deployHook();
    }

    function test_afterInitialize_seedsRingBufferWithInitialPrice() public {
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);

        uint8 bufLen = harness.VOL_BUFFER_LEN_();
        for (uint8 i = 0; i < bufLen; i++) {
            assertEq(
                harness.getVolatilityObservation(poolId, i),
                uint256(Constants.SQRT_PRICE_1_1),
                "ring buffer slot not seeded"
            );
        }
    }

    function test_afterInitialize_resetsCursorAndCachedVolatility() public {
        (, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);

        (uint8 cursor, uint256 cachedVolatility,) = harness.getVolatilityMeta(poolId);
        assertEq(cursor, 0, "cursor not zero");
        assertEq(cachedVolatility, 0, "cached volatility not zero");
    }

    function test_afterInitialize_recordsLastVolUpdateBlock() public {
        vm.roll(12345);
        (, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);

        (,, uint256 lastVolUpdate) = harness.getVolatilityMeta(poolId);
        assertEq(lastVolUpdate, 12345);
    }

    function test_afterInitialize_independentBuffersPerPool() public {
        (, PoolId id1) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        (, PoolId id2) = _initHookPool(500, 10, Constants.SQRT_PRICE_1_1 * 2);

        assertEq(harness.getVolatilityObservation(id1, 0), uint256(Constants.SQRT_PRICE_1_1));
        assertEq(harness.getVolatilityObservation(id2, 0), uint256(Constants.SQRT_PRICE_1_1) * 2);
    }

    function test_afterInitialize_emitsPoolInitialized() public {
        PoolId expectedId = _expectedPoolId(3000, 60);

        vm.expectEmit(true, false, false, true, address(harness));
        emit PoolInitialized(expectedId, Constants.SQRT_PRICE_1_1, 0);

        _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
    }
}
