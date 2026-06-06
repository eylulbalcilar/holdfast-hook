// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BaseSepoliaConstants} from "./constants/BaseSepolia.sol";

/// @notice One-shot smoke test helper: removes a small slice of liquidity from the
///         existing Base Sepolia demo position to trigger score settle + Bronze mint.
/// @dev    Run with:
///         forge script script/SmokeClose.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///         Requires PRIVATE_KEY, HOOK, MODIFY_ROUTER env vars.
contract SmokeClose is Script {
    int24  internal constant TICK_LOWER = -196860;
    int24  internal constant TICK_UPPER = -195660;
    int24  internal constant TICK_SPACING = 60;
    uint24 internal constant FEE = 3000;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address hookAddr = vm.envAddress("HOOK");
        address routerAddr = vm.envAddress("MODIFY_ROUTER");
        int256 removeDelta = -int256(vm.envOr("REMOVE_DELTA", uint256(1e9)));

        address usdc = BaseSepoliaConstants.USDC;
        address weth = BaseSepoliaConstants.WETH;

        Currency c0;
        Currency c1;
        if (usdc < weth) {
            c0 = Currency.wrap(usdc);
            c1 = Currency.wrap(weth);
        } else {
            c0 = Currency.wrap(weth);
            c1 = Currency.wrap(usdc);
        }

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        PoolModifyLiquidityTest router = PoolModifyLiquidityTest(routerAddr);
        bytes memory hookData = abi.encode(deployer);

        console2.log("=== Holdfast SmokeClose ===");
        console2.log("Deployer:", deployer);
        console2.log("Router:", routerAddr);
        console2.log("Remove delta:", removeDelta);

        vm.startBroadcast(deployerPk);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: removeDelta,
                salt: bytes32(0)
            }),
            hookData
        );
        vm.stopBroadcast();

        console2.log("=== SmokeClose done. Check NFT balanceOf + streak tier. ===");
    }
}
