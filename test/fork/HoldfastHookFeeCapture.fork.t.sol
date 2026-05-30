// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";

import {BaseMainnet} from "./constants/BaseMainnet.sol";

/// @notice End-to-end fork test for the afterSwap real-USDC capture path.
/// @dev    Run with:
///         forge test --match-path test/fork/HoldfastHookFeeCapture.fork.t.sol \
///         --fork-url $BASE_RPC_URL --fork-block-number 30900000
///
///         Verifies that a swap on a USDC/WETH pool with the HoldfastHook bound
///         captures the redistribution share into YieldRouter and supplies it to
///         Aave V3, growing the router's aUSDC balance.
contract HoldfastHookFeeCaptureForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    HoldfastHook internal hook;
    HoldfastNFT internal nft;
    YieldRouter internal yieldRouter;

    IERC20 internal usdc;
    IERC20 internal weth;
    IERC20 internal aUsdc;

    PoolKey internal poolKey;
    Currency internal currency0;
    Currency internal currency1;
    bool internal usdcIsToken0;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    uint24 internal constant LP_FEE = 3000;          // 0.30%
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint256 internal constant USDC_LIQUIDITY = 1_000_000 * 1e6;  // 1M USDC
    uint256 internal constant WETH_LIQUIDITY = 500 * 1e18;       // 500 WETH
    uint256 internal constant SWAP_AMOUNT_WETH = 1 * 1e18;       // 1 WETH in

    function setUp() public {
        vm.skip(block.chainid != 8453);

        // 1. Canonical PoolManager from Base mainnet
        manager = IPoolManager(BaseMainnet.POOL_MANAGER);

        // 2. Test routers deployed locally (Base mainnet has no canonical deployment)
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // 3. Currencies sorted; USDC < WETH on Base, so currency0 = USDC
        usdc = IERC20(BaseMainnet.USDC);
        weth = IERC20(BaseMainnet.WETH);
        if (BaseMainnet.USDC < BaseMainnet.WETH) {
            currency0 = Currency.wrap(BaseMainnet.USDC);
            currency1 = Currency.wrap(BaseMainnet.WETH);
            usdcIsToken0 = true;
        } else {
            currency0 = Currency.wrap(BaseMainnet.WETH);
            currency1 = Currency.wrap(BaseMainnet.USDC);
            usdcIsToken0 = false;
        }

        // 4. NFT, YieldRouter, then hook (mined at a permission-valid address)
        nft = new HoldfastNFT(address(this));
        yieldRouter = new YieldRouter(BaseMainnet.AAVE_V3_POOL, BaseMainnet.USDC, owner);
        aUsdc = IERC20(yieldRouter.aUsdc());

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager, nft, yieldRouter, BaseMainnet.USDC);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(HoldfastHook).creationCode, constructorArgs
        );
        hook = new HoldfastHook{salt: salt}(manager, nft, yieldRouter, BaseMainnet.USDC);
        require(address(hook) == hookAddr, "hook mined address mismatch");
        nft.setHook(address(hook));

        vm.prank(owner);
        yieldRouter.setHook(address(hook));

        // 5. Build PoolKey and initialize
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // 6. Fund LP and trader with USDC and WETH using foundry deal()
        deal(BaseMainnet.USDC, lp, USDC_LIQUIDITY);
        deal(BaseMainnet.WETH, lp, WETH_LIQUIDITY);
        deal(BaseMainnet.WETH, trader, SWAP_AMOUNT_WETH * 10);

        vm.startPrank(lp);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.prank(trader);
        weth.approve(address(swapRouter), type(uint256).max);
    }

    function test_fork_swap_capturesUsdcAndSuppliesToAave() public {
        // 1. LP adds a wide-range full-band position
        int24 tickLower = -887220; // min usable tick at tickSpacing 60
        int24 tickUpper =  887220;
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 1_000_000 * 1e6, // arbitrary L units
                salt: bytes32(0)
            }),
            ""
        );

        uint256 aUsdcBefore = aUsdc.balanceOf(address(yieldRouter));
        uint256 routerUsdcBefore = usdc.balanceOf(address(yieldRouter));

        // 2. Trader swaps WETH -> USDC (exact-in WETH).
        //    With usdcIsToken0 = true (USDC < WETH on Base): zeroForOne = false (token1 -> token0).
        //    USDC is the output -> unspecified currency -> capture path active.
        bool zeroForOne = !usdcIsToken0;

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(SWAP_AMOUNT_WETH), // exact-in
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 aUsdcAfter = aUsdc.balanceOf(address(yieldRouter));
        uint256 routerUsdcAfter = usdc.balanceOf(address(yieldRouter));

        // 3. Capture path assertions:
        //    - aUSDC must have grown (capture was supplied to Aave V3)
        //    - router idle USDC balance must be ~0 (everything supplied)
        assertGt(aUsdcAfter, aUsdcBefore, "no capture supplied to Aave");
        assertEq(routerUsdcAfter, routerUsdcBefore, "idle USDC leaked into router");
    }
}
