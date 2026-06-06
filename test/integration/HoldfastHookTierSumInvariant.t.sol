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

/// @title HoldfastHookTierSumInvariant
/// @notice Verifies the Step 7 invariant: when settle grows a tiered position's
///         accumulatedScore, sumOfTierScores[tier] grows by the same amount, so
///         claim's tier-weighted share is computed against a fresh denominator.
contract HoldfastHookTierSumInvariantTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;
    uint8 internal constant TIER_BRONZE = 1;

    address internal lp;

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        lp = makeAddr("lp");
        vm.roll(1);
    }

    function _open(address owner, bytes32 salt) internal returns (bytes32 key) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQ_DELTA, salt: salt}),
            abi.encode(owner)
        );
        key = Position.calculatePositionKey(owner, TICK_LOWER, TICK_UPPER, salt);
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

    /// @dev After a position is minted into Bronze, further accrual settled through
    ///      a remove must keep sumOfTierScores[BRONZE] equal to the single tiered
    ///      position's accumulatedScore (no stale-sum drift).
    function test_tierSum_tracksAccumulatedScoreForSoleTierMember() public {
        bytes32 key = _open(lp, bytes32(0));

        // Drive enough churn to cross the Bronze score threshold, and roll past the
        // Bronze tenure window so the dual criterion is met.
        _churn(12);
        vm.roll(block.number + 1_000);

        // Trigger mint via a remove (beforeRemoveLiquidity settles then evaluates).
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQ_DELTA / 4, salt: bytes32(0)}),
            abi.encode(lp)
        );

        HoldfastHook.PositionStreak memory s = harness.getStreak(key);
        assertEq(s.currentTier, TIER_BRONZE, "precondition: position must be Bronze");
        // Sole member: tier sum equals this position's score.
        assertEq(harness.sumOfTierScores(TIER_BRONZE), s.accumulatedScore, "tier sum must equal sole member score after mint");

        // More churn accrues additional score. Settle it via another remove and
        // assert the invariant still holds (sum tracked the accrual atomically).
        _churn(6);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQ_DELTA / 4, salt: bytes32(0)}),
            abi.encode(lp)
        );

        HoldfastHook.PositionStreak memory s2 = harness.getStreak(key);
        assertGt(s2.accumulatedScore, s.accumulatedScore, "score must have grown");
        assertEq(harness.sumOfTierScores(TIER_BRONZE), s2.accumulatedScore, "tier sum must stay in sync with accrued score");
    }
}
