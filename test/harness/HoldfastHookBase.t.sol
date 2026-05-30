// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoldfastHookHarness} from "./HoldfastHookHarness.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {MockYieldRouter} from "../mocks/MockYieldRouter.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title HoldfastHookBase
/// @notice Minimal v4 test harness. Deploys a PoolManager, two MockERC20 tokens
///         (sorted into currency0/currency1), the modify-liquidity and swap test
///         routers, the HoldfastNFT, and the HoldfastHookHarness via HookMiner +
///         CREATE2 at a permission-valid address. Avoids inheriting v4-core's
///         Deployers to keep type identities in a single remapping namespace.
abstract contract HoldfastHookBase is Test {
    PoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    HoldfastHookHarness internal harness;
    HoldfastNFT internal nft;

    using PoolIdLibrary for PoolKey;

    uint256 internal constant TOKEN_SUPPLY = 1e30;

    function _deployHook() internal {
        // 1. PoolManager + standard routers
        manager = new PoolManager(address(this));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // 2. Two mock tokens, sorted, approved to routers
        MockERC20 a = new MockERC20("TokenA", "A", 18);
        MockERC20 b = new MockERC20("TokenB", "B", 18);
        a.mint(address(this), TOKEN_SUPPLY);
        b.mint(address(this), TOKEN_SUPPLY);

        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // 3. NFT
        nft = new HoldfastNFT(address(this));

        // 4. Mine + deploy harness at a permission-valid hook address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        MockYieldRouter mockRouter = new MockYieldRouter();
        bytes memory constructorArgs = abi.encode(IPoolManager(address(manager)), nft, YieldRouter(address(mockRouter)), address(token0));
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(HoldfastHookHarness).creationCode,
            constructorArgs
        );
        harness = new HoldfastHookHarness{salt: salt}(IPoolManager(address(manager)), nft, YieldRouter(address(mockRouter)), address(token0));
        require(address(harness) == hookAddr, "harness mined address mismatch");

        // 5. Bind NFT to the hook so transfer-time settlement callback resolves
        nft.setHook(address(harness));
    }

    function _initHookPool(uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(harness))
        });
        id = k.toId();
        manager.initialize(k, sqrtPriceX96);
    }

    function _expectedPoolId(uint24 fee, int24 tickSpacing) internal view returns (PoolId) {
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(harness))
        });
        return k.toId();
    }
}
