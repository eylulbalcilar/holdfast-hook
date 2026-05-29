// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {BaseMainnet} from "./constants/BaseMainnet.sol";
import {FailingAavePool} from "../mocks/FailingAavePool.sol";

/// @notice Fork tests for `YieldRouter` against Base mainnet Aave V3.
/// @dev Run with: `forge test --match-path test/fork/YieldRouter.fork.t.sol \
///      --fork-url $BASE_RPC_URL --fork-block-number 30900000`
///      The block number is pinned per-invocation, not in foundry.toml; see
///      DESIGN.md "Fork test target".
contract YieldRouterForkTest is Test {
    YieldRouter internal router;
    IAaveV3Pool internal aavePool;
    IERC20 internal usdc;
    IERC20 internal aUsdc;

    address internal owner = makeAddr("owner");
    address internal hook = makeAddr("hook");

    uint256 internal constant SUPPLY_AMOUNT = 1_000_000_000; // 1,000 USDC (6 decimals)

    function setUp() public {
        // Skip if not running with --fork-url. block.chainid on Base mainnet = 8453.
        vm.skip(block.chainid != 8453);

        aavePool = IAaveV3Pool(BaseMainnet.AAVE_V3_POOL);
        usdc = IERC20(BaseMainnet.USDC);

        router = new YieldRouter(BaseMainnet.AAVE_V3_POOL, BaseMainnet.USDC, owner);

        vm.prank(owner);
        router.setHook(hook);

        aUsdc = IERC20(router.aUsdc());

        // Fund the router with USDC for supply tests. deal() writes the balance
        // storage slot directly, bypassing transferFrom approval flow.
        deal(address(usdc), address(router), SUPPLY_AMOUNT * 2);
    }

    // -------------------------------------------------------------------------
    // 1. supply -> aToken mint
    // -------------------------------------------------------------------------

    function test_fork_supply_mintsAToken() public {
        uint256 aUsdcBefore = aUsdc.balanceOf(address(router));
        uint256 usdcBefore = usdc.balanceOf(address(router));

        vm.prank(hook);
        router.supplyToAave(SUPPLY_AMOUNT);

        uint256 aUsdcAfter = aUsdc.balanceOf(address(router));
        uint256 usdcAfter = usdc.balanceOf(address(router));

        assertEq(usdcBefore - usdcAfter, SUPPLY_AMOUNT, "usdc not debited");
        assertApproxEqAbs(aUsdcAfter - aUsdcBefore, SUPPLY_AMOUNT, 2, "aUSDC not minted");
    }

    // -------------------------------------------------------------------------
    // 2. yield accrual after time advance
    // -------------------------------------------------------------------------

    function test_fork_yieldAccrues_overTime() public {
        vm.prank(hook);
        router.supplyToAave(SUPPLY_AMOUNT);

        uint256 aUsdcAfterSupply = aUsdc.balanceOf(address(router));

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_300_000);

        aavePool.getReserveData(address(usdc));

        uint256 aUsdcAfterAccrual = aUsdc.balanceOf(address(router));

        assertGt(aUsdcAfterAccrual, aUsdcAfterSupply, "yield did not accrue");
    }

    // -------------------------------------------------------------------------
    // 3. withdraw -> USDC returned to hook
    // -------------------------------------------------------------------------

    function test_fork_withdraw_returnsUsdcToHook() public {
        vm.prank(hook);
        router.supplyToAave(SUPPLY_AMOUNT);

        uint256 hookUsdcBefore = usdc.balanceOf(hook);

        vm.prank(hook);
        uint256 actual = router.withdrawFromAave(SUPPLY_AMOUNT);

        uint256 hookUsdcAfter = usdc.balanceOf(hook);

        assertEq(actual, SUPPLY_AMOUNT, "actual returned mismatch");
        assertEq(hookUsdcAfter - hookUsdcBefore, SUPPLY_AMOUNT, "hook did not receive USDC");
    }

    // -------------------------------------------------------------------------
    // 4. withdraw failure -> fallback returns 0, emits WithdrawFailed
    // -------------------------------------------------------------------------

    function test_fork_withdrawFailure_returnsZero() public {
        FailingAavePool failingPool = new FailingAavePool(IAaveV3Pool(BaseMainnet.AAVE_V3_POOL));

        YieldRouter failingRouter = new YieldRouter(address(failingPool), BaseMainnet.USDC, owner);

        vm.prank(owner);
        failingRouter.setHook(hook);

        vm.expectEmit(false, false, false, true, address(failingRouter));
        emit YieldRouter.WithdrawFailed(SUPPLY_AMOUNT, abi.encodeWithSignature("WithdrawFailedMock()"));

        vm.prank(hook);
        uint256 actual = failingRouter.withdrawFromAave(SUPPLY_AMOUNT);

        assertEq(actual, 0, "actual should be zero on failure");
    }
}
