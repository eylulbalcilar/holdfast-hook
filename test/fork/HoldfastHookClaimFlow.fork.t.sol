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
import {Position} from "v4-core/libraries/Position.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {HoldfastHookHarness} from "../harness/HoldfastHookHarness.sol";

import {BaseMainnet} from "./constants/BaseMainnet.sol";

/// @notice End-to-end fork tests for the claim and transfer-settlement flows against
///         a real Aave V3 USDC reserve. Verifies tier-share payout, NFT transfer
///         settlement, and realized-IL accrual.
/// @dev    Run with:
///         forge test --match-path test/fork/HoldfastHookClaimFlow.fork.t.sol \
///           --fork-url $BASE_RPC_URL --fork-block-number 30900000
contract HoldfastHookClaimFlowForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    HoldfastHookHarness internal harness;
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
    address internal lp2 = makeAddr("lp2");
    address internal trader = makeAddr("trader");

    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;

    uint256 internal constant USDC_LIQUIDITY = 1_000_000 * 1e6;
    uint256 internal constant WETH_LIQUIDITY = 500 * 1e18;
    uint256 internal constant SWAP_AMOUNT_WETH = 1 * 1e18;

    // Mirror of hook tier constants for assertions.
    uint8 internal constant TIER_BRONZE = 1;

    function setUp() public {
        vm.skip(block.chainid != 8453);

        manager = IPoolManager(BaseMainnet.POOL_MANAGER);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

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
            address(this), flags, type(HoldfastHookHarness).creationCode, constructorArgs
        );
        harness = new HoldfastHookHarness{salt: salt}(manager, nft, yieldRouter, BaseMainnet.USDC);
        require(address(harness) == hookAddr, "harness mined address mismatch");
        nft.setHook(address(harness));

        vm.prank(owner);
        yieldRouter.setHook(address(harness));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(harness))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

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

    /// @notice LP opens position, accrues Bronze tier via test helper, runs a swap to
    ///         seed the bonus pool, then claim() pays out USDC and zeros sums.
    function test_fork_claim_paysTierShare() public {
        // 1. LP opens position
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1_000_000 * 1e6, salt: bytes32(0)}),
            abi.encode(lp)
        );

        bytes32 positionKey = Position.calculatePositionKey(lp, TICK_LOWER, TICK_UPPER, bytes32(0));

        // 2. Seed Bronze-qualifying state via harness helper, mint NFT
        harness.exposed_setStreakForTest(positionKey, 100e18, block.number - 5_000);
        harness.exposed_evaluateAndMaybeMint(positionKey, lp);
        uint256 tokenId = nft.positionKeyToTokenId(positionKey);
        assertGt(tokenId, 0, "NFT not minted");
        assertEq(nft.ownerOf(tokenId), lp, "lp must own NFT");

        // 3. Trader swap to seed the bonus pool
        bool zeroForOne = !usdcIsToken0;
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(SWAP_AMOUNT_WETH),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 bonusPoolBefore = aUsdc.balanceOf(address(yieldRouter));
        assertGt(bonusPoolBefore, 0, "bonus pool empty before claim");

        // 4. LP claims
        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        vm.prank(lp);
        harness.claim(tokenId);
        uint256 lpUsdcAfter = usdc.balanceOf(lp);

        // 5. Assertions: LP received USDC, accumulatedScore zeroed, tier sum zeroed
        assertGt(lpUsdcAfter, lpUsdcBefore, "lp did not receive USDC");
        uint256 accScore = harness.getStreak(positionKey).accumulatedScore;
        assertEq(accScore, 0, "accumulatedScore not zeroed");
        assertEq(harness.sumOfTierScores(TIER_BRONZE), 0, "Bronze sum not zeroed");
    }

    /// @notice After NFT transfer, settleOnTransfer pays the original owner the accrued
    ///         tier share. New owner takes a clean slate.
    function test_fork_settleOnTransfer_paysOriginalOwner() public {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1_000_000 * 1e6, salt: bytes32(0)}),
            abi.encode(lp)
        );
        bytes32 positionKey = Position.calculatePositionKey(lp, TICK_LOWER, TICK_UPPER, bytes32(0));

        harness.exposed_setStreakForTest(positionKey, 100e18, block.number - 5_000);
        harness.exposed_evaluateAndMaybeMint(positionKey, lp);
        uint256 tokenId = nft.positionKeyToTokenId(positionKey);

        // Seed bonus pool via a trader swap
        bool zeroForOne = !usdcIsToken0;
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(SWAP_AMOUNT_WETH),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 lpUsdcBefore = usdc.balanceOf(lp);

        // Transfer NFT from lp to lp2 - settleOnTransfer fires, lp paid out
        vm.prank(lp);
        nft.transferFrom(lp, lp2, tokenId);

        uint256 lpUsdcAfter = usdc.balanceOf(lp);
        assertGt(lpUsdcAfter, lpUsdcBefore, "original owner did not receive settle payout");
        assertEq(nft.ownerOf(tokenId), lp2, "transfer did not complete");

        // lp2 should have nothing claimable yet (clean slate)
        uint256 accScore = harness.getStreak(positionKey).accumulatedScore;
        assertEq(accScore, 0, "new owner inherited stale score");
    }

    /// @notice Position close computes realized IL and adds |IL| to sumOfAbsoluteIL.
    function test_fork_realizedIL_accruesOnClose() public {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1_000_000 * 1e6, salt: bytes32(0)}),
            abi.encode(lp)
        );

        // Push the pool price by running a large swap so realized IL is non-zero
        bool zeroForOne = !usdcIsToken0;
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(SWAP_AMOUNT_WETH * 5),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ilSumBefore = harness.sumOfAbsoluteIL();

        // Full close
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(1_000_000 * 1e6), salt: bytes32(0)}),
            abi.encode(lp)
        );

        uint256 ilSumAfter = harness.sumOfAbsoluteIL();
        assertGt(ilSumAfter, ilSumBefore, "sumOfAbsoluteIL did not grow on close");
    }
}
