// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {MockYieldRouter} from "../mocks/MockYieldRouter.sol";

/// @dev Minimal ERC-721 read interface; IPositionManager does not expose ownerOf directly.
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title SubscriberNativeAccrualTest
/// @notice V2 subscriber-native baseline. Exercises the intended end-to-end flow:
///         an LP mints a position through the canonical Uniswap PositionManager,
///         subscribes that position to the Holdfast hook via posm.subscribe, swaps
///         churn the pool, blocks advance past the Bronze tenure floor, and the
///         per-position score is asserted to have accrued, keyed by the canonical
///         ERC-721 tokenId (not a hookData-derived position key).
///
///         EXPECTED ON CURRENT main: this test FAILS. HoldfastHook (V1) is a
///         BaseHook only; it does not implement ISubscriber, so it has no
///         notifySubscribe handler. PositionManager.subscribe calls
///         ISubscriber.notifySubscribe on the hook, the call hits a nonexistent
///         selector with no fallback, and subscribe bubbles up SubscriptionReverted.
///         The test reverts at the posm.subscribe step and never reaches the
///         accrual assertion. Committed RED as the V2 baseline; the subscriber
///         handler work makes it GREEN.
///
///         The mint passes hookData = abi.encode(lp) purely so the V1 hook's
///         afterAddLiquidity does not revert with HookDataMissing before we reach
///         subscribe (the V1 RED point is the subscribe call, not the mint). V2
///         resolves owner from PositionManager and ignores this hookData, so the
///         encoding is forward-compatible.
contract SubscriberNativeAccrualTest is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    IAllowanceTransfer internal permit2;
    IPositionManager internal posm;

    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    HoldfastHook internal hook;
    HoldfastNFT internal nft;
    MockYieldRouter internal mockRouter;

    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal lp;

    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant LIQ = 1e18;

    // Mirrors HoldfastHook.BRONZE_BLOCKS (1_000): minimum active tenure for Bronze.
    uint256 internal constant BRONZE_BLOCKS = 1_000;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        // Two 18-decimal mock tokens, sorted. token0 is designated USDC for the hook,
        // matching the harness convention; the hook requires USDC as a pool currency.
        MockERC20 a = new MockERC20("USDC", "USDC", 18);
        MockERC20 b = new MockERC20("WETH", "WETH", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Fund + approve the test contract (the swapper) on the swap router.
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        nft = new HoldfastNFT(address(this));
        mockRouter = new MockYieldRouter();

        // Mine + deploy the real HoldfastHook (not the harness) at a permission-valid
        // CREATE2 address. usdc = token0.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory cargs =
            abi.encode(IPoolManager(address(manager)), nft, YieldRouter(address(mockRouter)), address(token0));
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HoldfastHook).creationCode, cargs);
        hook = new HoldfastHook{salt: salt}(
            IPoolManager(address(manager)), nft, YieldRouter(address(mockRouter)), address(token0)
        );
        require(address(hook) == hookAddr, "hook mined address mismatch");
        nft.setHook(address(hook));

        // Deploy the canonical Uniswap v4 PositionManager locally (same contract code
        // as Base Sepolia 0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80).
        posm = _deployPosm(address(manager), address(permit2));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // LP: fund and wire the two-step Permit2 -> PositionManager approval.
        lp = makeAddr("lp");
        token0.mint(lp, 1e24);
        token1.mint(lp, 1e24);
        vm.startPrank(lp);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.roll(1);
    }

    /// @dev Deploys the canonical PositionManager. tokenDescriptor and weth9 are address(0):
    ///      the test never resolves tokenURI or wraps native.
    function _deployPosm(address poolManager_, address permit2_) internal returns (IPositionManager) {
        PositionManager pm = new PositionManager(
            IPoolManager(poolManager_),
            IAllowanceTransfer(permit2_),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        return IPositionManager(address(pm));
    }

    /// @dev Mints a position through the canonical PositionManager (MINT_POSITION + SETTLE_PAIR).
    function _mintPosition(address owner_, uint256 liquidity) internal {
        bytes memory hookData = abi.encode(owner_);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(type(uint128).max),
            uint128(type(uint128).max),
            owner_,
            hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        bytes memory unlockData = abi.encode(actions, params);
        vm.prank(owner_);
        posm.modifyLiquidities(unlockData, block.timestamp + 1);
    }

    function _swap(int256 amount, bool zeroForOne) internal {
        uint160 limit =
            zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _churn() internal {
        for (uint256 i = 0; i < 6; i++) {
            _swap(-int256(2e16), i % 2 == 0);
            vm.roll(block.number + 50);
        }
    }

    /// @dev RED baseline. The subscriber-native flow must accrue per-position score
    ///      keyed by the canonical PositionManager tokenId. Reverts at posm.subscribe
    ///      on current main (HoldfastHook has no notifySubscribe handler).
    function test_subscriberNativeAccrual_scoreKeyedByTokenId() public {
        // 1. LP mints a canonical PositionManager position.
        uint256 tokenId = posm.nextTokenId();
        _mintPosition(lp, LIQ);
        assertEq(IERC721Minimal(address(posm)).ownerOf(tokenId), lp, "LP must own the minted position NFT");

        // 2. LP subscribes the position to the Holdfast hook (the V2 entrypoint).
        //    REVERTS ON CURRENT main: HoldfastHook does not implement ISubscriber.
        vm.prank(lp);
        posm.subscribe(tokenId, address(hook), "");

        // 3. Swap churn plus block advancement past the Bronze tenure floor drive
        //    the per-position accumulator.
        _churn();
        vm.roll(block.number + BRONZE_BLOCKS + 1);
        _swap(-int256(2e16), true);

        // 4. Score must accrue, keyed by the canonical tokenId.
        bytes32 key = bytes32(tokenId);
        assertGt(
            hook.getStreak(key).accumulatedScore,
            0,
            "score must accrue keyed by tokenId after subscribe"
        );
    }
}
