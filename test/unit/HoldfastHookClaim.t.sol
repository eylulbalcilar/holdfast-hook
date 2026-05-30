// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHookBase} from "../harness/HoldfastHookBase.t.sol";
import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {Position} from "v4-core/libraries/Position.sol";

/// @notice Minimal revert-path tests for HoldfastHook.claim. Happy-path payout
///         math is exercised end-to-end against a real Aave V3 USDC reserve in
///         the fork tests; here we only cover authorization and empty-claim guards.
contract HoldfastHookClaimTest is HoldfastHookBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;
    bytes32 internal constant SALT = bytes32(0);

    function setUp() public {
        _deployHook();
        vm.roll(10_000);
    }

    function test_claim_revertsIfNotNftOwner() public {
        // Mint an NFT to ALICE via the lazy-tier path.
        bytes32 positionKey = Position.calculatePositionKey(ALICE, TICK_LOWER, TICK_UPPER, SALT);
        harness.exposed_setStreakForTest(positionKey, 1e23, block.number - 2_000); // > Bronze score & blocks
        harness.exposed_evaluateAndMaybeMint(positionKey, ALICE);
        uint256 tokenId = nft.positionKeyToTokenId(positionKey);
        assertGt(tokenId, 0, "precondition: NFT must be minted");
        assertEq(nft.ownerOf(tokenId), ALICE);

        // BOB tries to claim ALICE's NFT.
        vm.prank(BOB);
        vm.expectRevert(HoldfastHook.NotNftOwner.selector);
        harness.claim(tokenId);
    }

    function test_claim_revertsIfNothingToClaim() public {
        // ALICE mints an NFT but has zero accumulatedScore at claim time (we mint via
        // exogenous score, then zero it out to model "already claimed once").
        bytes32 positionKey = Position.calculatePositionKey(ALICE, TICK_LOWER, TICK_UPPER, SALT);
        harness.exposed_setStreakForTest(positionKey, 1e23, block.number - 2_000);
        harness.exposed_evaluateAndMaybeMint(positionKey, ALICE);
        uint256 tokenId = nft.positionKeyToTokenId(positionKey);

        // Zero the score so the claim computes zero share.
        harness.exposed_zeroStreakScoreForTest(positionKey);

        vm.prank(ALICE);
        vm.expectRevert(HoldfastHook.NothingToClaim.selector);
        harness.claim(tokenId);
    }
}
