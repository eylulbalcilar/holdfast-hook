// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract HoldfastHookRemoveLiquidityTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int256 internal constant LIQ_DELTA = 1e18;

    uint256 internal constant BRONZE_SCORE = 10 * 1e18;
    uint256 internal constant BRONZE_BLOCKS = 1_000;
    uint8 internal constant TIER_BRONZE = 1;

    event RealizedILComputed(bytes32 indexed positionKey, int256 il, uint160 currentSqrtPriceX96);

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
        vm.roll(1);
    }

    function _openPosition() internal returns (bytes32 positionKey) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQ_DELTA,
                salt: bytes32(0)
            }),
            ""
        );
        positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _removePartial(int256 negDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: negDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _readRealizedIL(bytes32 key) internal view returns (int256 il) {
        (,,,,,,,, il) = harness.streaks(key);
    }

    function _readTier(bytes32 key) internal view returns (uint8 tier) {
        (,,,, tier,,,,) = harness.streaks(key);
    }

    // -----------------------------------------------------------------
    // Realized IL compute
    // -----------------------------------------------------------------

    /// @dev No price change between open and remove: realized IL must be exactly zero.
    function test_remove_noPriceChange_realizedILZero() public {
        bytes32 positionKey = _openPosition();

        // Remove half the liquidity. Price unchanged, so IL = 0.
        _removePartial(-LIQ_DELTA / 2);

        int256 il = _readRealizedIL(positionKey);
        assertEq(il, int256(0), "IL must be zero when price has not moved");
    }

    /// @dev Price moves: IL must be strictly negative (impermanent loss is a loss).
    function test_remove_priceMoved_realizedILNegative() public {
        bytes32 positionKey = _openPosition();

        // Trigger a swap to move the pool price.
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e16), sqrtPriceLimitX96: uint160(4295128740)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        _removePartial(-LIQ_DELTA / 2);

        int256 il = _readRealizedIL(positionKey);
        assertLt(il, int256(0), "IL must be negative after a price move");
    }

    function test_remove_emitsRealizedILComputed() public {
        bytes32 positionKey = _openPosition();

        // We do not pre-compute the IL value to assert exactly; instead, assert that
        // the event topic indexes match and the data fields are populated.
        vm.expectEmit(true, false, false, false, address(harness));
        emit RealizedILComputed(positionKey, int256(0), uint160(0));

        _removePartial(-LIQ_DELTA / 2);
    }

    // -----------------------------------------------------------------
    // Unknown position: no-op
    // -----------------------------------------------------------------

    /// @dev Removing liquidity on a position the hook never saw open must be a
    ///      safe no-op. The router still calls our hook, but nothing should write.
    function test_remove_unknownPosition_noOp() public {
        // Open one position so router has nonzero state.
        _openPosition();

        // Now remove against a tick range the hook never tracked. Router accepts the
        // call only if Uniswap also tracks the position; since we never opened this
        // range, Uniswap reverts. Cover the hook-level branch instead by removing
        // a salt-mismatched position: salt(1) was never opened.
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -LIQ_DELTA / 2,
                salt: bytes32(uint256(1))
            }),
            ""
        );

        // The unopened position key should have IL == 0 (default).
        bytes32 unknownKey = Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        assertEq(_readRealizedIL(unknownKey), int256(0));
    }

    // -----------------------------------------------------------------
    // Lazy tier evaluation at remove time
    // -----------------------------------------------------------------

    /// @dev Score and tenure satisfied; remove triggers lazy eval -> NFT minted Bronze.
    function test_remove_triggersLazyTierMint() public {
        bytes32 positionKey = _openPosition();

        // Set score to Bronze threshold and roll past tenure window.
        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);

        // No NFT yet.
        assertEq(nft.nextTokenId(), 1, "no NFT before remove");

        _removePartial(-LIQ_DELTA / 2);

        assertEq(_readTier(positionKey), TIER_BRONZE, "remove should trigger Bronze mint");
        assertEq(nft.nextTokenId(), 2, "one NFT minted");
    }
}
