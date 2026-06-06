// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BaseMainnet} from "../test/fork/constants/BaseMainnet.sol";
import {BaseSepoliaConstants} from "./constants/BaseSepolia.sol";

contract DemoSeed is Script, StdCheats {
    using PoolIdLibrary for PoolKey;

    int24  internal constant TICK_SPACING   = 60;
    int24  internal constant TICK_LOWER     = -196860;
    int24  internal constant TICK_UPPER     = -195660;
    uint24 internal constant FEE            = 3000;
    uint160 internal constant SQRT_PRICE_X96 = 4339505179874779662909440;
    uint256 internal constant BRONZE_BLOCKS  = 1_000;

    // State shared across helpers (avoids stack depth in run())
    PoolKey     internal _key;
    address     internal _usdc;
    address     internal _weth;
    address     internal _deployer;
    PoolModifyLiquidityTest internal _modifyRouter;
    PoolSwapTest            internal _swapRouter;

    function run() external {
        uint256 deployerPk = vm.envOr("PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        _deployer = vm.addr(deployerPk);

        address hookAddr = vm.envAddress("HOOK");
        uint256 nSwaps   = vm.envOr("N_SWAPS", uint256(12));
        uint256 lpUsdc   = vm.envOr("LP_USDC", uint256(1_000e6));
        uint256 lpWeth   = vm.envOr("LP_WETH", uint256(5e17));
        uint256 liqDelta = vm.envOr("LIQ_DELTA", uint256(50_000e18));
        uint256 swapAmt  = vm.envOr("SWAP_AMT", uint256(10e6));
        bool    isAnvil  = (block.chainid == 31337);

        _loadAddresses();

        console2.log("=== Holdfast DemoSeed ===");
        console2.log("Chain:", block.chainid);
        console2.log("Hook:", hookAddr);

        vm.startBroadcast(deployerPk);

        _modifyRouter = new PoolModifyLiquidityTest(IPoolManager(_poolManagerAddr()));
        _swapRouter   = new PoolSwapTest(IPoolManager(_poolManagerAddr()));

        if (isAnvil) {
            deal(_usdc, _deployer, lpUsdc * 10);
            deal(_weth, _deployer, lpWeth * 10);
        }

        IERC20(_usdc).approve(address(_modifyRouter), type(uint256).max);
        IERC20(_weth).approve(address(_modifyRouter), type(uint256).max);
        IERC20(_usdc).approve(address(_swapRouter),   type(uint256).max);
        IERC20(_weth).approve(address(_swapRouter),   type(uint256).max);

        _buildPoolKey(hookAddr);
        _initPool();
        _addLiquidity(liqDelta);
        _runSwaps(nSwaps, swapAmt);

        if (isAnvil) {
            vm.roll(block.number + BRONZE_BLOCKS + 10);
            console2.log("Blocks advanced to:", block.number);
        } else {
            console2.log("Testnet: wait", BRONZE_BLOCKS - (block.number), "more blocks for Bronze");
        }

        vm.stopBroadcast();
        console2.log("=== Seed complete. Swaps:", nSwaps, "===");
    }

    function _loadAddresses() internal {
        if (block.chainid == 31337 || block.chainid == 8453) {
            _usdc = BaseMainnet.USDC;
            _weth = BaseMainnet.WETH;
        } else {
            _usdc = BaseSepoliaConstants.USDC;
            _weth = BaseSepoliaConstants.WETH;
        }
    }

    function _poolManagerAddr() internal view returns (address) {
        if (block.chainid == 31337 || block.chainid == 8453) {
            return BaseMainnet.POOL_MANAGER;
        }
        return BaseSepoliaConstants.POOL_MANAGER;
    }

    function _buildPoolKey(address hookAddr) internal {
        Currency c0;
        Currency c1;
        if (_usdc < _weth) {
            c0 = Currency.wrap(_usdc);
            c1 = Currency.wrap(_weth);
        } else {
            c0 = Currency.wrap(_weth);
            c1 = Currency.wrap(_usdc);
        }
        _key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
    }

    function _initPool() internal {
        IPoolManager(_poolManagerAddr()).initialize(_key, SQRT_PRICE_X96);
        console2.log("Pool initialized");
    }

    function _addLiquidity(uint256 liqDelta) internal {
        bytes memory hookData = abi.encode(_deployer);
        _modifyRouter.modifyLiquidity(
            _key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(liqDelta),
                salt: bytes32(0)
            }),
            hookData
        );
        console2.log("Liquidity added");
    }

    function _runSwaps(uint256 n, uint256 swapAmt) internal {
        bytes memory hookData = abi.encode(_deployer);
        for (uint256 i = 0; i < n; i++) {
            bool zeroForOne = (i % 2 == 0);
            _swapRouter.swap(
                _key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(swapAmt),
                    sqrtPriceLimitX96: zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                hookData
            );
        }
        console2.log("Swaps done:", n);
    }
}
