// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHoldfastHook} from "./interfaces/IHoldfastHook.sol";

/// @title HoldfastNFT
/// @notice ERC-721 representing a Holdfast LP position. Minted when a position first
///         crosses Bronze threshold; metadata pointer is updated on tier upgrades.
/// @dev Hook address is set once post-deployment via setHook (one-time, only-owner).
///      mint and upgradeTier are gated by onlyHook. _update calls hook.settleOnTransfer
///      on every non-mint transfer to prevent accrual theft.
contract HoldfastNFT is ERC721, Ownable {
    /// @notice Tier constants. 0 = none (never minted in this state).
    uint8 public constant TIER_BRONZE = 1;
    uint8 public constant TIER_SILVER = 2;
    uint8 public constant TIER_GOLD = 3;

    /// @notice Per-tier ERC-721 metadata JSON CIDs on IPFS. Each JSON carries name,
    ///         description, image (the tier PNG), and attributes.
    string private constant BRONZE_URI = "ipfs://bafkreibfnikwxbrk35ooasgk6wruh4tzk7hxlzb27mmf3d4gdgnduqulou";
    string private constant SILVER_URI = "ipfs://bafkreigxsa4m3socq5huqlunzhph255bcocraudus7nlfe3tspxyswcqae";
    string private constant GOLD_URI = "ipfs://bafkreieor3eys6c2bq43sbf7k5hy36sfpoqpiik6gsbkl52kfxdtrdsr5u";

    /// @notice Authorized hook contract. Set once via setHook.
    address public hook;

    /// @notice Next tokenId to mint (starts at 1, 0 reserved as sentinel).
    uint256 public nextTokenId = 1;

    /// @notice tokenId -> current tier.
    mapping(uint256 => uint8) public tokenIdToTier;

    /// @notice positionKey -> tokenId. Zero means no NFT for that position.
    mapping(bytes32 => uint256) public positionKeyToTokenId;

    /// @notice tokenId -> positionKey (reverse lookup for settlement on transfer).
    mapping(uint256 => bytes32) public tokenIdToPositionKey;

    event HookSet(address indexed hook);
    event PositionMinted(uint256 indexed tokenId, bytes32 indexed positionKey, address indexed to, uint8 tier);
    event TierUpgraded(uint256 indexed tokenId, uint8 oldTier, uint8 newTier);

    error HookAlreadySet();
    error HookNotSet();
    error NotHook();
    error PositionAlreadyMinted();
    error InvalidTier();
    error TierDowngrade();
    error UnknownToken();

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address initialOwner) ERC721("Holdfast Position", "HOLDFAST") Ownable(initialOwner) {}

    /// @notice One-time hook address binding. Only owner, only when unset.
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (_hook == address(0)) revert HookNotSet();
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice Mint a new position NFT at Bronze tier. Called by hook when a position
    ///         first crosses the Bronze threshold.
    function mint(address to, bytes32 positionKey) external onlyHook returns (uint256 tokenId) {
        if (positionKeyToTokenId[positionKey] != 0) revert PositionAlreadyMinted();
        tokenId = nextTokenId++;
        positionKeyToTokenId[positionKey] = tokenId;
        tokenIdToPositionKey[tokenId] = positionKey;
        tokenIdToTier[tokenId] = TIER_BRONZE;
        _mint(to, tokenId);
        emit PositionMinted(tokenId, positionKey, to, TIER_BRONZE);
    }

    /// @notice Upgrade an existing NFT's tier. Called by hook on Silver/Gold crossing.
    ///         Same tokenId is reused; only the metadata pointer changes.
    function upgradeTier(uint256 tokenId, uint8 newTier) external onlyHook {
        if (newTier != TIER_SILVER && newTier != TIER_GOLD) revert InvalidTier();
        uint8 oldTier = tokenIdToTier[tokenId];
        if (oldTier == 0) revert UnknownToken();
        if (newTier <= oldTier) revert TierDowngrade();
        tokenIdToTier[tokenId] = newTier;
        emit TierUpgraded(tokenId, oldTier, newTier);
    }

    /// @notice Returns the IPFS pointer corresponding to the current tier.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint8 tier = tokenIdToTier[tokenId];
        if (tier == TIER_GOLD) return GOLD_URI;
        if (tier == TIER_SILVER) return SILVER_URI;
        return BRONZE_URI;
    }

    /// @notice OZ v5 transfer hook. Calls settleOnTransfer for non-mint transfers.
    /// @dev Mint is when previous owner is address(0); we skip settlement there.
    ///      Burn (to == address(0)) still settles to the outgoing owner.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            if (hook == address(0)) revert HookNotSet();
            bytes32 positionKey = tokenIdToPositionKey[tokenId];
            IHoldfastHook(hook).settleOnTransfer(positionKey, from, to);
        }
    }
}
