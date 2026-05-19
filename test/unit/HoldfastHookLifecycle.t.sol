// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoldfastHookHarness} from "../harness/HoldfastHookHarness.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Lifecycle tests for HoldfastHook. Currently covers _afterInitialize
///         (volatility ring buffer cold-start). Additional lifecycle entry points
///         are added as they are implemented.
contract HoldfastHookLifecycleTest is Test {
    using PoolIdLibrary for PoolKey;

    HoldfastHookHarness internal harness;
    HoldfastNFT internal nft;

    // A representative pool key. The hook field is set in setUp once the mined
    // hook address is known.
    PoolKey internal key;

    address internal constant TOKEN0 = address(0x1111);
    address internal constant TOKEN1 = address(0x2222);
    uint160 internal constant INIT_SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1 price

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    function setUp() public {
        nft = new HoldfastNFT(address(this));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(address(0xDEAD)), nft);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(HoldfastHookHarness).creationCode,
            constructorArgs
        );
        harness = new HoldfastHookHarness{salt: salt}(IPoolManager(address(0xDEAD)), nft);
        require(address(harness) == hookAddr, "harness mined address mismatch");

        key = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
    }

    function test_afterInitialize_seedsRingBufferWithInitialPrice() public {
        harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 0);

        PoolId poolId = key.toId();
        uint8 bufLen = harness.VOL_BUFFER_LEN_();
        for (uint8 i = 0; i < bufLen; i++) {
            assertEq(
                harness.getVolatilityObservation(poolId, i),
                uint256(INIT_SQRT_PRICE_X96),
                "ring buffer slot not seeded"
            );
        }
    }

    function test_afterInitialize_resetsCursorAndCachedVolatility() public {
        harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 0);

        PoolId poolId = key.toId();
        (uint8 cursor, uint256 cachedVolatility,) = harness.getVolatilityMeta(poolId);
        assertEq(cursor, 0, "cursor not zero");
        assertEq(cachedVolatility, 0, "cached volatility not zero");
    }

    function test_afterInitialize_recordsLastVolUpdateBlock() public {
        vm.roll(12345);
        harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 0);

        PoolId poolId = key.toId();
        (,, uint256 lastVolUpdate) = harness.getVolatilityMeta(poolId);
        assertEq(lastVolUpdate, 12345);
    }

    function test_afterInitialize_emitsPoolInitialized() public {
        PoolId poolId = key.toId();
        vm.expectEmit(true, false, false, true, address(harness));
        emit PoolInitialized(poolId, INIT_SQRT_PRICE_X96, 100);

        harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 100);
    }

    function test_afterInitialize_returnsCorrectSelector() public {
        bytes4 selector = harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 0);
        assertEq(selector, IHooks.afterInitialize.selector);
    }

    /// @dev Different pool keys initialize independent buffers without cross-contamination.
    function test_afterInitialize_independentBuffersPerPool() public {
        harness.exposed_afterInitialize(key, INIT_SQRT_PRICE_X96, 0);

        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0x3333)),
            currency1: Currency.wrap(address(0x4444)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(harness))
        });
        uint160 otherPrice = INIT_SQRT_PRICE_X96 * 2;
        harness.exposed_afterInitialize(key2, otherPrice, 0);

        PoolId id1 = key.toId();
        PoolId id2 = key2.toId();
        assertEq(harness.getVolatilityObservation(id1, 0), uint256(INIT_SQRT_PRICE_X96));
        assertEq(harness.getVolatilityObservation(id2, 0), uint256(otherPrice));
    }
}
