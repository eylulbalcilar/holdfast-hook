// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

/// @title HoldfastHookNaturalAccrual
/// @notice Natural-flow integration test exercising the realistic router topology
///         where the liquidity provider (the owner asserted in hookData) is a
///         distinct address from msg.sender of the modifyLiquidity call (the router).
///
///         The existing harness suite never exercises this path: _ownerHookData()
///         encodes address(modifyLiquidityRouter), making hookData_owner == msg.sender,
///         so PoolManager's position key and the hook's position key coincide and
///         getPositionLiquidity returns the real liquidity.
///
///         Here hookData encodes a distinct LP. PoolManager stores the position under
///         the router (msg.sender); the hook derives its key from the LP. The keys
///         diverge, getPositionLiquidity(hookKey) returns 0, _settlePositionScore folds
///         in liquidity == 0, and accumulatedScore never moves off zero.
///
///         EXPECTED ON CURRENT main: this test FAILS at the final assertion
///         (score == 0). Committed RED as the baseline for the internal
///         liquidity-tracking fix. The intermediate assertions confirm the pool-level
///         accumulator advanced, so a zero position score isolates the identity
///         divergence rather than a dead volatility signal.
contract HoldfastHookNaturalAccrualTest is HoldfastHookBase {
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
        // Positional read against the current PositionStreak tuple. When the
        // liquidity field is appended to the struct, extend this by one trailing slot.
        (s,,,,,,,,,) = harness.streaks(key);
    }

    /// @dev RED baseline. Score must accrue for an LP whose address is asserted in
    ///      hookData and is NOT the caller of modifyLiquidity. Fails on current main.
    function test_naturalAccrual_ownerNotCaller() public {
        assertTrue(lp != address(modifyLiquidityRouter), "LP must differ from the router (msg.sender)");

        bytes32 key = _openAs(lp, LIQ_DELTA, bytes32(0));
        assertEq(_score(key), 0, "no score before swaps");

        _churn();

        assertGt(harness.globalScorePerLiquidity(poolId), 0, "global accumulator must advance after churn");
        (, uint256 cachedVol,) = harness.getVolatilityMeta(poolId);
        assertGt(cachedVol, 0, "cached volatility must be non-zero after churn");

        _removeAs(lp, -LIQ_DELTA / 2, bytes32(0));

        assertGt(_score(key), 0, "score must accrue under natural flow (owner != caller)");
    }
}
