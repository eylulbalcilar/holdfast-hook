// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract HoldfastHookAddLiquidityTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    int256 internal constant LIQ_DELTA = 1e18;

    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint160 entrySqrtPriceX96,
        uint256 firstActiveBlock
    );

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);
    }

    function _addLiq(int24 tickLower, int24 tickUpper, int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: delta,
                salt: salt
            }),
            _ownerHookData()
        );
    }

    function _streakKey(int24 tickLower, int24 tickUpper, bytes32 salt) internal view returns (bytes32) {
        // The hook uses the router as `sender` since modifyLiquidityRouter is the
        // caller of PoolManager.unlock.
        return Position.calculatePositionKey(address(modifyLiquidityRouter), tickLower, tickUpper, salt);
    }

    function _readStreak(bytes32 key)
        internal
        view
        returns (
            uint256 accumulatedScore,
            uint256 lastUpdateBlock,
            uint256 lastGlobalScoreSnapshot,
            uint256 firstActiveBlock,
            uint160 entrySqrtPriceX96,
            uint8 currentTier,
            uint256 nftTokenId,
            uint128 frozenAt,
            bool isActive,
            int256 realizedIL
        )
    {
        return harness.streaks(key);
    }

    // -----------------------------------------------------------------
    // New position cold init
    // -----------------------------------------------------------------

    function test_addLiquidity_newPosition_setsEntrySnapshot() public {
        vm.roll(100);
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(0));

        bytes32 key = _streakKey(TICK_LOWER, TICK_UPPER, bytes32(0));
        (
            uint256 accumulatedScore,
            uint256 lastUpdateBlock,
            ,
            uint256 firstActiveBlock,
            uint160 entrySqrtPriceX96,
            uint8 currentTier,
            ,
            uint128 frozenAt,
            bool isActive,
            
        ) = _readStreak(key);

        assertEq(accumulatedScore, 0, "score should be zero at open");
        assertEq(entrySqrtPriceX96, Constants.SQRT_PRICE_1_1, "entry sqrtPrice mismatch");
        assertEq(firstActiveBlock, 100, "firstActiveBlock mismatch");
        assertEq(lastUpdateBlock, 100, "lastUpdateBlock mismatch");
        assertEq(currentTier, 0, "should be unminted (tier 0)");
        assertEq(frozenAt, 0, "frozenAt should be zero");
        assertTrue(isActive, "isActive should be true after open");
    }

    function test_addLiquidity_newPosition_emitsPositionOpened() public {
        vm.roll(100);
        bytes32 expectedKey = _streakKey(TICK_LOWER, TICK_UPPER, bytes32(0));

        vm.expectEmit(true, true, true, true, address(harness));
        emit PositionOpened(
            expectedKey,
            address(modifyLiquidityRouter),
            poolId,
            TICK_LOWER,
            TICK_UPPER,
            Constants.SQRT_PRICE_1_1,
            100
        );

        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(0));
    }

    /// @dev Step 5 mandatory check: NFT must NOT be minted at position open,
    ///      even if liquidity is large. Mint waits for the dual-criterion gate.
    function test_addLiquidity_newPosition_doesNotMintNFT() public {
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(0));
        assertEq(nft.nextTokenId() - 1, 0, "NFT should not be minted at open");
    }

    /// @dev Even with an extreme liquidity delta, no NFT is minted at open.
    function test_addLiquidity_whaleNewPosition_doesNotMintNFT() public {
        _addLiq(TICK_LOWER, TICK_UPPER, 1e24, bytes32(0));
        assertEq(nft.nextTokenId() - 1, 0, "NFT should not be minted even for whale");
    }

    // -----------------------------------------------------------------
    // Liquidity increase: entry snapshot and firstActiveBlock are immutable
    // -----------------------------------------------------------------

    function test_addLiquidity_increase_preservesEntrySnapshot() public {
        vm.roll(100);
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(0));

        bytes32 key = _streakKey(TICK_LOWER, TICK_UPPER, bytes32(0));
        (,,, uint256 firstActiveBlockBefore, uint160 entryBefore,,,,,) = _readStreak(key);

        // Advance time and add more liquidity to the SAME position key.
        vm.roll(500);
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(0));

        (
            ,
            uint256 lastUpdateBlock,
            ,
            uint256 firstActiveBlockAfter,
            uint160 entryAfter,
            ,
            ,
            ,
            bool isActive,
            
        ) = _readStreak(key);

        assertEq(entryAfter, entryBefore, "entrySqrtPriceX96 must not change on top-up");
        assertEq(firstActiveBlockAfter, firstActiveBlockBefore, "firstActiveBlock must not change on top-up");
        assertEq(lastUpdateBlock, 500, "lastUpdateBlock should advance to current block");
        assertTrue(isActive);
    }

    // -----------------------------------------------------------------
    // Position key isolation: different ticks / salts yield different streaks
    // -----------------------------------------------------------------

    function test_addLiquidity_differentTickRange_isolatedStreaks() public {
        vm.roll(100);
        _addLiq(-60, 60, LIQ_DELTA, bytes32(0));

        vm.roll(200);
        _addLiq(-120, 120, LIQ_DELTA, bytes32(0));

        bytes32 k1 = _streakKey(-60, 60, bytes32(0));
        bytes32 k2 = _streakKey(-120, 120, bytes32(0));

        (,,, uint256 fab1,,,,,,) = _readStreak(k1);
        (,,, uint256 fab2,,,,,,) = _readStreak(k2);

        assertEq(fab1, 100);
        assertEq(fab2, 200);
    }

    function test_addLiquidity_differentSalt_isolatedStreaks() public {
        vm.roll(100);
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(uint256(1)));

        vm.roll(200);
        _addLiq(TICK_LOWER, TICK_UPPER, LIQ_DELTA, bytes32(uint256(2)));

        bytes32 k1 = _streakKey(TICK_LOWER, TICK_UPPER, bytes32(uint256(1)));
        bytes32 k2 = _streakKey(TICK_LOWER, TICK_UPPER, bytes32(uint256(2)));

        (,,, uint256 fab1,,,,,,) = _readStreak(k1);
        (,,, uint256 fab2,,,,,,) = _readStreak(k2);

        assertEq(fab1, 100);
        assertEq(fab2, 200);
    }
}
