// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {IHoldfastHook} from "../../src/interfaces/IHoldfastHook.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockHook is IHoldfastHook {
    bytes32 public lastPositionKey;
    address public lastFrom;
    address public lastTo;
    uint256 public callCount;

    function settleOnTransfer(bytes32 positionKey, address from, address to) external {
        lastPositionKey = positionKey;
        lastFrom = from;
        lastTo = to;
        callCount++;
    }
}

contract HoldfastNFTTest is Test {
    HoldfastNFT internal nft;
    MockHook internal mockHook;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xBEEF);
    address internal bob = address(0xCAFE);

    bytes32 internal constant KEY_1 = keccak256("position-1");
    bytes32 internal constant KEY_2 = keccak256("position-2");

    // Mirror the per-tier metadata JSON CIDs in HoldfastNFT; tokenURI returns these verbatim.
    string internal constant BRONZE_URI = "ipfs://bafkreibfnikwxbrk35ooasgk6wruh4tzk7hxlzb27mmf3d4gdgnduqulou";
    string internal constant SILVER_URI = "ipfs://bafkreigxsa4m3socq5huqlunzhph255bcocraudus7nlfe3tspxyswcqae";
    string internal constant GOLD_URI = "ipfs://bafkreieor3eys6c2bq43sbf7k5hy36sfpoqpiik6gsbkl52kfxdtrdsr5u";

    function setUp() public {
        nft = new HoldfastNFT(owner);
        mockHook = new MockHook();
        vm.prank(owner);
        nft.setHook(address(mockHook));
    }

    function _mint(address to, bytes32 key) internal returns (uint256 tokenId) {
        vm.startPrank(address(mockHook));
        tokenId = nft.mint(to, key);
        vm.stopPrank();
    }

    function _upgrade(uint256 tokenId, uint8 tier) internal {
        vm.startPrank(address(mockHook));
        nft.upgradeTier(tokenId, tier);
        vm.stopPrank();
    }

    // ---------- setHook ----------

    function test_setHook_setsAddress() public {
        HoldfastNFT fresh = new HoldfastNFT(owner);
        vm.prank(owner);
        fresh.setHook(address(mockHook));
        assertEq(fresh.hook(), address(mockHook));
    }

    function test_setHook_revertsIfAlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(HoldfastNFT.HookAlreadySet.selector);
        nft.setHook(address(0xDEAD));
    }

    function test_setHook_revertsIfZeroAddress() public {
        HoldfastNFT fresh = new HoldfastNFT(owner);
        vm.prank(owner);
        vm.expectRevert(HoldfastNFT.HookNotSet.selector);
        fresh.setHook(address(0));
    }

    function test_setHook_revertsIfNotOwner() public {
        HoldfastNFT fresh = new HoldfastNFT(owner);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setHook(address(mockHook));
    }

    // ---------- mint ----------

    function test_mint_mintsAtBronze() public {
        uint256 tokenId = _mint(alice, KEY_1);
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(nft.tokenIdToTier(tokenId), nft.TIER_BRONZE());
        assertEq(nft.positionKeyToTokenId(KEY_1), tokenId);
        assertEq(nft.tokenIdToPositionKey(tokenId), KEY_1);
    }

    function test_mint_revertsIfNotHook() public {
        vm.prank(alice);
        vm.expectRevert(HoldfastNFT.NotHook.selector);
        nft.mint(alice, KEY_1);
    }

    function test_mint_revertsOnDuplicatePositionKey() public {
        _mint(alice, KEY_1);
        vm.startPrank(address(mockHook));
        vm.expectRevert(HoldfastNFT.PositionAlreadyMinted.selector);
        nft.mint(alice, KEY_1);
        vm.stopPrank();
    }

    function test_mint_incrementsTokenId() public {
        uint256 id1 = _mint(alice, KEY_1);
        uint256 id2 = _mint(bob, KEY_2);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    // ---------- upgradeTier ----------

    function test_upgradeTier_bronzeToSilver() public {
        uint256 tokenId = _mint(alice, KEY_1);
        _upgrade(tokenId, nft.TIER_SILVER());
        assertEq(nft.tokenIdToTier(tokenId), nft.TIER_SILVER());
    }

    function test_upgradeTier_silverToGold() public {
        uint256 tokenId = _mint(alice, KEY_1);
        _upgrade(tokenId, nft.TIER_SILVER());
        _upgrade(tokenId, nft.TIER_GOLD());
        assertEq(nft.tokenIdToTier(tokenId), nft.TIER_GOLD());
    }

    function test_upgradeTier_revertsOnDowngrade() public {
        uint256 tokenId = _mint(alice, KEY_1);
        _upgrade(tokenId, nft.TIER_GOLD());
        uint8 silver = nft.TIER_SILVER();
        vm.startPrank(address(mockHook));
        vm.expectRevert(HoldfastNFT.TierDowngrade.selector);
        nft.upgradeTier(tokenId, silver);
        vm.stopPrank();
    }

    function test_upgradeTier_revertsOnSameTier() public {
        // Bronze is set on mint and cannot be passed to upgradeTier;
        // the InvalidTier guard fires before the downgrade check.
        uint256 tokenId = _mint(alice, KEY_1);
        uint8 bronze = nft.TIER_BRONZE();
        vm.startPrank(address(mockHook));
        vm.expectRevert(HoldfastNFT.InvalidTier.selector);
        nft.upgradeTier(tokenId, bronze);
        vm.stopPrank();
    }

    function test_upgradeTier_revertsOnInvalidTier() public {
        uint256 tokenId = _mint(alice, KEY_1);
        vm.startPrank(address(mockHook));
        vm.expectRevert(HoldfastNFT.InvalidTier.selector);
        nft.upgradeTier(tokenId, 4);
        vm.stopPrank();
    }

    function test_upgradeTier_revertsOnUnknownToken() public {
        uint8 silver = nft.TIER_SILVER();
        vm.startPrank(address(mockHook));
        vm.expectRevert(HoldfastNFT.UnknownToken.selector);
        nft.upgradeTier(999, silver);
        vm.stopPrank();
    }

    function test_upgradeTier_revertsIfNotHook() public {
        uint256 tokenId = _mint(alice, KEY_1);
        uint8 silver = nft.TIER_SILVER();
        vm.prank(alice);
        vm.expectRevert(HoldfastNFT.NotHook.selector);
        nft.upgradeTier(tokenId, silver);
    }

    // ---------- tokenURI ----------

    function test_tokenURI_bronze() public {
        uint256 tokenId = _mint(alice, KEY_1);
        assertEq(nft.tokenURI(tokenId), BRONZE_URI);
    }

    function test_tokenURI_silver() public {
        uint256 tokenId = _mint(alice, KEY_1);
        _upgrade(tokenId, nft.TIER_SILVER());
        assertEq(nft.tokenURI(tokenId), SILVER_URI);
    }

    function test_tokenURI_gold() public {
        uint256 tokenId = _mint(alice, KEY_1);
        _upgrade(tokenId, nft.TIER_GOLD());
        assertEq(nft.tokenURI(tokenId), GOLD_URI);
    }

    function test_tokenURI_revertsOnUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        nft.tokenURI(999);
    }

    // ---------- _update settlement ----------

    function test_transfer_callsSettleOnHook() public {
        uint256 tokenId = _mint(alice, KEY_1);
        uint256 mintCalls = mockHook.callCount();

        vm.prank(alice);
        nft.transferFrom(alice, bob, tokenId);

        assertEq(mockHook.callCount(), mintCalls + 1);
        assertEq(mockHook.lastPositionKey(), KEY_1);
        assertEq(mockHook.lastFrom(), alice);
        assertEq(mockHook.lastTo(), bob);
        assertEq(nft.ownerOf(tokenId), bob);
    }

    function test_mint_doesNotCallSettle() public {
        uint256 before_ = mockHook.callCount();
        _mint(alice, KEY_1);
        assertEq(mockHook.callCount(), before_);
    }
}
