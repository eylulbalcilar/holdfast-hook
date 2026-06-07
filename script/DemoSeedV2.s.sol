// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {HoldfastHookV2} from "../src/HoldfastHookV2.sol";
import {BaseSepoliaAddresses} from "../src/constants/Addresses.sol";

/// @notice Seeds a HoldfastHookV2 demo on Base Sepolia using the subscriber-native flow: optional
///         ETH wrap, init the demo pool (seeds the volatility buffer in afterInitialize), mint a
///         position through the canonical PositionManager, posm.subscribe it to the hook to start
///         accrual, run swap churn to drive globalScorePerLiquidity, then a tiny posm liquidity
///         change to settle the score off zero. Separate from the V1 DemoSeed (left untouched).
/// @dev Env: HOOK (required, the deployed HoldfastHookV2), PRIVATE_KEY, and tunables WETH_AMT,
///      USDC_AMT, WRAP_ETH_WEI, N_SWAPS, SWAP_AMT, INIT_POOL, SETTLE_LIQ. Liquidity is sized to fit
///      within the desired token amounts at the current price/range, so the WETH side (the scarce
///      one) bounds the position.
contract DemoSeedV2 is Script {
    // Demo pool params: USDC/WETH around ~3000 USDC/WETH, reused from the V1 demo.
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -196860;
    int24 internal constant TICK_UPPER = -195660;
    uint160 internal constant SQRT_PRICE_X96 = 4339505179874779662909440;

    // Shared state (avoids stack-too-deep in run()).
    address internal _deployer;
    address internal _hook;
    address internal _usdc;
    address internal _weth;
    IPositionManager internal _posm;
    IAllowanceTransfer internal _permit2;
    IPoolManager internal _pm;
    PoolSwapTest internal _swapRouter;
    PoolKey internal _key;
    uint128 internal _mintedLiq;

    function run() external {
        uint256 pk = vm.envOr(
            "PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        _deployer = vm.addr(pk);
        _hook = vm.envAddress("HOOK");

        uint256 wethAmt = vm.envOr("WETH_AMT", uint256(1e14)); // 0.0001 WETH desired
        uint256 usdcAmt = vm.envOr("USDC_AMT", uint256(100e6)); // 100 USDC cap
        uint256 wrapEth = vm.envOr("WRAP_ETH_WEI", uint256(0)); // optional ETH -> WETH
        uint256 nSwaps = vm.envOr("N_SWAPS", uint256(8));
        uint256 swapAmt = vm.envOr("SWAP_AMT", uint256(2e5)); // 0.2 USDC per swap (shallow pool)
        bool doInit = vm.envOr("INIT_POOL", true);

        _usdc = BaseSepoliaAddresses.USDC;
        _weth = BaseSepoliaAddresses.WETH;
        _posm = IPositionManager(BaseSepoliaAddresses.POSITION_MANAGER);
        _permit2 = IAllowanceTransfer(BaseSepoliaAddresses.PERMIT2);
        _pm = IPoolManager(BaseSepoliaAddresses.POOL_MANAGER);
        _swapRouter = PoolSwapTest(BaseSepoliaAddresses.POOL_SWAP_TEST);

        console2.log("Deployer:", _deployer);
        console2.log("Hook:", _hook);
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(pk);

        if (wrapEth > 0) {
            (bool ok,) = _weth.call{value: wrapEth}(abi.encodeWithSignature("deposit()"));
            require(ok, "WETH wrap failed");
            console2.log("Wrapped ETH to WETH (wei):", wrapEth);
        }

        _buildPoolKey();

        if (doInit) {
            _pm.initialize(_key, SQRT_PRICE_X96);
            console2.log("Pool initialized");
        }

        // Permit2 two-step approvals (token -> Permit2, then Permit2 -> PositionManager) per token.
        _approvePermit2(_usdc);
        _approvePermit2(_weth);

        // Mint a position through the canonical PositionManager, then subscribe it to the hook.
        uint256 tokenId = _posm.nextTokenId();
        _mint(wethAmt, usdcAmt);
        console2.log("Minted tokenId:", tokenId);

        _posm.subscribe(tokenId, _hook, "");
        console2.log("Subscribed to hook");

        // Swap churn drives globalScorePerLiquidity via afterSwap.
        IERC20(_usdc).approve(address(_swapRouter), type(uint256).max);
        IERC20(_weth).approve(address(_swapRouter), type(uint256).max);
        _runSwaps(nSwaps, swapAmt);

        // Tiny liquidity decrease fires notifyModifyLiquidity -> _settleScore, moving the score off
        // zero. A decrease (not an increase) is used so it needs no leftover token balance after the
        // swaps; it only returns dust via CLOSE_CURRENCY.
        uint256 settleLiq = vm.envOr("SETTLE_LIQ", uint256(_mintedLiq / 1000));
        if (settleLiq == 0) settleLiq = 1;
        _settle(tokenId, settleLiq);
        console2.log("Settled via tiny liquidity decrease");

        vm.stopBroadcast();

        // Read back the per-position score to confirm accrual moved off zero (view, no tx).
        uint256 score = HoldfastHookV2(_hook).getStreak(tokenId).accumulatedScore;
        console2.log("accumulatedScore for tokenId after settle:", score);
        console2.log("=== DemoSeedV2 complete ===");
    }

    function _buildPoolKey() internal {
        (Currency c0, Currency c1) = _usdc < _weth
            ? (Currency.wrap(_usdc), Currency.wrap(_weth))
            : (Currency.wrap(_weth), Currency.wrap(_usdc));
        _key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(_hook)});
    }

    function _approvePermit2(address token) internal {
        IERC20(token).approve(address(_permit2), type(uint256).max);
        _permit2.approve(token, address(_posm), type(uint160).max, type(uint48).max);
    }

    function _mint(uint256 wethAmt, uint256 usdcAmt) internal {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        // Map desired amounts to the sorted currency0/currency1 amounts.
        (uint256 amt0, uint256 amt1) = _usdc < _weth ? (usdcAmt, wethAmt) : (wethAmt, usdcAmt);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(SQRT_PRICE_X96, sqrtA, sqrtB, amt0, amt1);
        require(liq > 0, "computed zero liquidity");
        _mintedLiq = liq;

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _key, TICK_LOWER, TICK_UPPER, uint256(liq), uint128(amt0), uint128(amt1), _deployer, bytes("")
        );
        params[1] = abi.encode(_key.currency0, _key.currency1);
        _posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1200);
    }

    function _settle(uint256 tokenId, uint256 liquidity) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(_key.currency0);
        params[2] = abi.encode(_key.currency1);
        _posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1200);
    }

    /// @dev USDC-input swaps only (exact-in). USDC is currency1 (its address sorts above WETH), so
    ///      these are oneForZero (zeroForOne = false), funded by the plentiful USDC rather than the
    ///      scarce WETH, and a single SWAP_AMT is well-defined (no 6/18 decimal mismatch). They
    ///      drift the price toward the upper tick; with enough pool depth the position stays in
    ///      range across the churn, which is what drives globalScorePerLiquidity in afterSwap.
    function _runSwaps(uint256 n, uint256 swapAmt) internal {
        for (uint256 i = 0; i < n; i++) {
            _swapRouter.swap(
                _key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(swapAmt),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        console2.log("Swaps done:", n);
    }
}
