// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Constants} from "v4-core/../test/utils/Constants.sol";
import {Position} from "v4-core/libraries/Position.sol";

/// @notice The 3 mandatory security tests that compensate for the Trust Boundary
///         design (HoldfastNFT does not enforce dual criterion; HoldfastHook is
///         the single source of truth). Each test exercises the full hook path:
///         open a position, set the streak score exogenously to model swap accrual,
///         advance blocks as needed, then trigger lazy tier evaluation and assert
///         the resulting NFT state.
contract HoldfastHookSecurityTest is HoldfastHookBase {
    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    int256 internal constant LIQ_DELTA = 1e18;

    // Mirror of HoldfastHook tier constants for assertions.
    uint8 internal constant TIER_NONE = 0;
    uint8 internal constant TIER_BRONZE = 1;
    uint8 internal constant TIER_SILVER = 2;
    uint8 internal constant TIER_GOLD = 3;

    uint256 internal constant BRONZE_SCORE = 10 * 1e18;
    uint256 internal constant SILVER_SCORE = 100 * 1e18;
    uint256 internal constant GOLD_SCORE = 1_000 * 1e18;

    uint256 internal constant BRONZE_BLOCKS = 1_000;
    uint256 internal constant SILVER_BLOCKS = 10_000;
    uint256 internal constant GOLD_BLOCKS = 100_000;

    address internal constant LP_OWNER = address(0xA11CE);

    function setUp() public {
        _deployHook();
        (poolKey, poolId) = _initHookPool(3000, 60, Constants.SQRT_PRICE_1_1);

        // Always start at a known block to make tenure math explicit.
        vm.roll(1);
    }

    function _openPosition() internal returns (bytes32 positionKey) {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQ_DELTA,
                salt: bytes32(0)
            }),
            _ownerHookData()
        );
        positionKey =
            Position.calculatePositionKey(address(modifyLiquidityRouter), TICK_LOWER, TICK_UPPER, bytes32(0));
    }

    function _currentTier(bytes32 positionKey) internal view returns (uint8 tier) {
        (,,,,, tier,,,,,) = harness.streaks(positionKey);
    }

    function _nftTokenId(bytes32 positionKey) internal view returns (uint256 tokenId) {
        (,,,,,, tokenId,,,,) = harness.streaks(positionKey);
    }

    // -----------------------------------------------------------------
    // MANDATORY TEST 1: whale-instant-Gold attempt
    // -----------------------------------------------------------------

    /// @dev Whale opens a position, accumulates Gold-level score in minutes
    ///      (block.number - firstActiveBlock far below GOLD_BLOCKS). The hook
    ///      must NOT promote the NFT to Gold. The dual-criterion gate enforces
    ///      tenure mechanically regardless of score magnitude.
    function test_security_whaleInstantGold_doesNotMintGold() public {
        bytes32 positionKey = _openPosition();

        // 10x Gold score, but only BRONZE_BLOCKS of tenure elapsed.
        harness.setStreakScore(positionKey, GOLD_SCORE * 10);
        vm.roll(block.number + BRONZE_BLOCKS);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        uint8 tier = _currentTier(positionKey);
        assertEq(tier, TIER_BRONZE, "whale must not skip to Gold; only Bronze tenure elapsed");

        // NFT was minted at Bronze (Bronze threshold both criteria met). Confirm tier metadata.
        uint256 tokenId = _nftTokenId(positionKey);
        assertGt(tokenId, 0, "Bronze NFT should be minted (Bronze criteria met)");
        assertEq(nft.tokenIdToTier(tokenId), TIER_BRONZE, "NFT tier must be Bronze, not Gold");
    }

    /// @dev Tighter whale case: Gold-level score but blocks below BRONZE_BLOCKS.
    ///      No tier qualifies; no NFT minted.
    function test_security_whaleInstantGold_belowBronzeTenure_noMint() public {
        bytes32 positionKey = _openPosition();

        harness.setStreakScore(positionKey, GOLD_SCORE * 10);
        vm.roll(block.number + BRONZE_BLOCKS - 1);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_NONE, "no tier should be assigned");
        assertEq(_nftTokenId(positionKey), 0, "no NFT should be minted");
        assertEq(nft.nextTokenId(), 1, "no NFT in collection");
    }

    // -----------------------------------------------------------------
    // MANDATORY TEST 2: mint timing
    // -----------------------------------------------------------------

    /// @dev Mint must not happen until BOTH score and block thresholds are met.
    ///      Open a position with no score; even after BRONZE_BLOCKS elapse, no mint.
    function test_security_mintTiming_noScore_noMint() public {
        bytes32 positionKey = _openPosition();

        // Tenure satisfied, score zero.
        vm.roll(block.number + BRONZE_BLOCKS);
        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_NONE, "no score: tier must remain NONE");
        assertEq(nft.nextTokenId(), 1, "no NFT minted");
    }

    /// @dev With Bronze score AND Bronze tenure, mint executes and NFT is at Bronze.
    function test_security_mintTiming_bothCriteriaMet_mints() public {
        bytes32 positionKey = _openPosition();

        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_BRONZE, "Bronze criteria met -> mint");
        uint256 tokenId = _nftTokenId(positionKey);
        assertGt(tokenId, 0, "Bronze NFT should be minted");
        assertEq(nft.tokenIdToTier(tokenId), TIER_BRONZE);
        assertEq(nft.ownerOf(tokenId), LP_OWNER, "NFT minted to declared owner");
    }

    // -----------------------------------------------------------------
    // MANDATORY TEST 3: dual criterion enforcement (both failure modes)
    // -----------------------------------------------------------------

    /// @dev Failure mode A: score >= threshold, blocks < threshold. No mint.
    function test_security_dualCriterion_scoreOnly_noMint() public {
        bytes32 positionKey = _openPosition();

        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS - 1);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_NONE);
        assertEq(nft.nextTokenId(), 1);
    }

    /// @dev Failure mode B: blocks >= threshold, score < threshold. No mint.
    function test_security_dualCriterion_blocksOnly_noMint() public {
        bytes32 positionKey = _openPosition();

        harness.setStreakScore(positionKey, BRONZE_SCORE - 1);
        vm.roll(block.number + BRONZE_BLOCKS);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_NONE);
        assertEq(nft.nextTokenId(), 1);
    }

    /// @dev Same dual-criterion enforcement at the Silver tier: a Bronze-tier NFT
    ///      does not upgrade to Silver unless BOTH SILVER_SCORE and SILVER_BLOCKS
    ///      are satisfied beyond Bronze.
    function test_security_dualCriterion_silver_scoreOnly_noUpgrade() public {
        bytes32 positionKey = _openPosition();

        // First: mint Bronze legitimately.
        harness.setStreakScore(positionKey, BRONZE_SCORE);
        vm.roll(block.number + BRONZE_BLOCKS);
        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);
        assertEq(_currentTier(positionKey), TIER_BRONZE);
        uint256 tokenId = _nftTokenId(positionKey);

        // Then: bump score to Silver, but block count short of SILVER_BLOCKS.
        harness.setStreakScore(positionKey, SILVER_SCORE);
        // We are at block 1 + BRONZE_BLOCKS now. Move just below SILVER_BLOCKS tenure.
        // firstActiveBlock = 1, target blocksActive = SILVER_BLOCKS - 1.
        vm.roll(1 + SILVER_BLOCKS - 1);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_BRONZE, "must not upgrade to Silver without tenure");
        assertEq(nft.tokenIdToTier(tokenId), TIER_BRONZE);
    }

    /// @dev Direct-jump path: a single evaluation can take a never-minted position
    ///      to Gold if all three score AND block thresholds happen to be satisfied
    ///      simultaneously. This is the legitimate organic case (long-lived whale
    ///      position) and must succeed.
    function test_security_directJump_noneToGold_legitimate() public {
        bytes32 positionKey = _openPosition();

        harness.setStreakScore(positionKey, GOLD_SCORE);
        vm.roll(block.number + GOLD_BLOCKS);

        harness.exposed_evaluateAndMaybeMint(positionKey, LP_OWNER);

        assertEq(_currentTier(positionKey), TIER_GOLD, "should reach Gold in one call");
        uint256 tokenId = _nftTokenId(positionKey);
        assertGt(tokenId, 0);
        assertEq(nft.tokenIdToTier(tokenId), TIER_GOLD);
    }
}
