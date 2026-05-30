// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoldfastHookHarness} from "../harness/HoldfastHookHarness.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {MockYieldRouter} from "../mocks/MockYieldRouter.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

/// @notice Unit tests for HoldfastHook pure helpers: _positionKey and _evaluateNextTier.
///         The harness is deployed via CREATE2 to an address whose low 14 bits encode
///         the permission flags HoldfastHook declares, so BaseHook's constructor-time
///         address validation passes. The PoolManager is a dummy address since no
///         lifecycle entry point is invoked.
contract HoldfastHookHelpersTest is Test {
    address internal constant MOCK_USDC = address(0xCAFE);

    HoldfastHookHarness internal harness;
    HoldfastNFT internal nft;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);

    function setUp() public {
        nft = new HoldfastNFT(address(this));

        // Permission flag mask matching HoldfastHook.getHookPermissions():
        //   afterInitialize, afterAddLiquidity, beforeRemoveLiquidity,
        //   afterRemoveLiquidity, beforeSwap, afterSwap
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
        bytes memory constructorArgs = abi.encode(IPoolManager(address(0xDEAD)), nft, YieldRouter(address(mockRouter)), MOCK_USDC);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(HoldfastHookHarness).creationCode,
            constructorArgs
        );
        harness = new HoldfastHookHarness{salt: salt}(IPoolManager(address(0xDEAD)), nft, YieldRouter(address(mockRouter)), MOCK_USDC);
        require(address(harness) == hookAddr, "harness mined address mismatch");
    }

    // -----------------------------------------------------------------
    // _positionKey
    // -----------------------------------------------------------------

    function test_positionKey_deterministic() public view {
        bytes32 k1 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(0));
        bytes32 k2 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(0));
        assertEq(k1, k2);
    }

    function test_positionKey_differentOwner_differentKey() public view {
        bytes32 k1 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(0));
        bytes32 k2 = harness.exposed_positionKey(OTHER, -60, 60, bytes32(0));
        assertTrue(k1 != k2);
    }

    function test_positionKey_differentTicks_differentKey() public view {
        bytes32 k1 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(0));
        bytes32 k2 = harness.exposed_positionKey(OWNER, -120, 120, bytes32(0));
        assertTrue(k1 != k2);
    }

    function test_positionKey_differentSalt_differentKey() public view {
        bytes32 k1 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(uint256(1)));
        bytes32 k2 = harness.exposed_positionKey(OWNER, -60, 60, bytes32(uint256(2)));
        assertTrue(k1 != k2);
    }

    // -----------------------------------------------------------------
    // _evaluateNextTier: dual criterion enforcement
    // -----------------------------------------------------------------

    function test_evaluateNextTier_noCriteriaMet_returnsCurrent() public view {
        uint8 next = harness.exposed_evaluateNextTier(harness.TIER_NONE_(), 0, 0);
        assertEq(next, harness.TIER_NONE_());
    }

    /// @dev Dual criterion failure mode 1: score sufficient, blocks insufficient.
    function test_evaluateNextTier_scoreOnly_noBlocks_returnsCurrent() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            harness.BRONZE_SCORE_(),
            0
        );
        assertEq(next, harness.TIER_NONE_());
    }

    /// @dev Dual criterion failure mode 2: blocks sufficient, score insufficient.
    function test_evaluateNextTier_blocksOnly_noScore_returnsCurrent() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            0,
            harness.BRONZE_BLOCKS_()
        );
        assertEq(next, harness.TIER_NONE_());
    }

    function test_evaluateNextTier_bronzeBothMet_returnsBronze() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            harness.BRONZE_SCORE_(),
            harness.BRONZE_BLOCKS_()
        );
        assertEq(next, harness.TIER_BRONZE_());
    }

    // -----------------------------------------------------------------
    // _evaluateNextTier: whale-instant-Gold attempt (pure logic check)
    // -----------------------------------------------------------------

    /// @dev Whale accumulates Gold-level score in Bronze-tenure window.
    ///      Gold and Silver are blocks-gated; Bronze qualifies (score >> BRONZE_SCORE,
    ///      blocks == BRONZE_BLOCKS).
    function test_evaluateNextTier_whaleInstantGold_blockedByBlocks() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            harness.GOLD_SCORE_() * 10,
            harness.BRONZE_BLOCKS_()
        );
        assertEq(next, harness.TIER_BRONZE_());
    }

    /// @dev Whale with Gold-level score but below Bronze tenure: no tier at all.
    function test_evaluateNextTier_whaleInstantGold_noTierAtAll() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            harness.GOLD_SCORE_() * 10,
            harness.BRONZE_BLOCKS_() - 1
        );
        assertEq(next, harness.TIER_NONE_());
    }

    // -----------------------------------------------------------------
    // _evaluateNextTier: progressive transitions
    // -----------------------------------------------------------------

    function test_evaluateNextTier_silverBothMet_returnsSilver() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_BRONZE_(),
            harness.SILVER_SCORE_(),
            harness.SILVER_BLOCKS_()
        );
        assertEq(next, harness.TIER_SILVER_());
    }

    function test_evaluateNextTier_goldBothMet_returnsGold() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_SILVER_(),
            harness.GOLD_SCORE_(),
            harness.GOLD_BLOCKS_()
        );
        assertEq(next, harness.TIER_GOLD_());
    }

    function test_evaluateNextTier_noneToGold_directJump() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_NONE_(),
            harness.GOLD_SCORE_(),
            harness.GOLD_BLOCKS_()
        );
        assertEq(next, harness.TIER_GOLD_());
    }

    function test_evaluateNextTier_bronzeToGold_skipsSilver() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_BRONZE_(),
            harness.GOLD_SCORE_(),
            harness.GOLD_BLOCKS_()
        );
        assertEq(next, harness.TIER_GOLD_());
    }

    // -----------------------------------------------------------------
    // _evaluateNextTier: no downgrade, idempotence
    // -----------------------------------------------------------------

    function test_evaluateNextTier_atGold_staysGold() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_GOLD_(),
            harness.GOLD_SCORE_(),
            harness.GOLD_BLOCKS_()
        );
        assertEq(next, harness.TIER_GOLD_());
    }

    function test_evaluateNextTier_atGold_lowScore_staysGold() public view {
        uint8 next = harness.exposed_evaluateNextTier(harness.TIER_GOLD_(), 0, 0);
        assertEq(next, harness.TIER_GOLD_());
    }

    function test_evaluateNextTier_atSilver_belowGoldBlocks_staysSilver() public view {
        uint8 next = harness.exposed_evaluateNextTier(
            harness.TIER_SILVER_(),
            harness.GOLD_SCORE_(),
            harness.GOLD_BLOCKS_() - 1
        );
        assertEq(next, harness.TIER_SILVER_());
    }
    function test_mult_zeroIsOneX() public view {
        assertEq(harness.exposed_volatilityMultiplier(0), 1e18);
    }

    function test_mult_atLowerBoundIsOneX() public view {
        assertEq(harness.exposed_volatilityMultiplier(5e17), 1e18);
    }

    function test_mult_midBandInterpolates() public view {
        assertEq(harness.exposed_volatilityMultiplier(1e18), 1.25e18);
    }

    function test_mult_atUpperBoundIsMax() public view {
        assertEq(harness.exposed_volatilityMultiplier(15e17), 1.5e18);
    }

    function test_mult_aboveUpperIsCapped() public view {
        assertEq(harness.exposed_volatilityMultiplier(2e18), 1.5e18);
    }

    function test_mult_monotonicAcrossBand() public view {
        uint256 m1 = harness.exposed_volatilityMultiplier(6e17);
        uint256 m2 = harness.exposed_volatilityMultiplier(1e18);
        uint256 m3 = harness.exposed_volatilityMultiplier(14e17);
        assertLt(m1, m2, "multiplier increases across the band");
        assertLt(m2, m3, "multiplier increases across the band");
    }
}
