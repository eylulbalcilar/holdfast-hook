// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {IHoldfastHook} from "./interfaces/IHoldfastHook.sol";
import {HoldfastNFT} from "./HoldfastNFT.sol";

/// @title HoldfastHook
/// @notice Uniswap v4 hook measuring IL exposure, partially compensating realized IL,
///         and compounding rewards via Aave V3. Authoritative source of truth for tier
///         eligibility (HoldfastNFT trusts this contract; see DESIGN.md Trust Boundary).
/// @dev Lifecycle bodies are filled in subsequent steps. This skeleton wires permissions,
///      state, tier constants, helpers, and the IHoldfastHook.settleOnTransfer stub.
contract HoldfastHook is BaseHook, IHoldfastHook {
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

    uint8 internal constant VOL_BUFFER_LEN = 10;

    struct PositionStreak {
        uint256 accumulatedScore;
        uint256 lastUpdateBlock;
        uint256 firstActiveBlock;
        uint160 entrySqrtPriceX96;
        uint8 currentTier;
        uint256 nftTokenId;
        uint128 frozenAt;
        bool isActive;
    }

    struct PoolVolatility {
        uint256[10] recentPriceObservations;
        uint8 cursor;
        uint256 cachedVolatility;
        uint256 lastVolUpdate;
    }

    mapping(bytes32 => PositionStreak) public streaks;
    mapping(PoolId => PoolVolatility) public volatility;

    HoldfastNFT public immutable nft;

    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint160 entrySqrtPriceX96,
        uint256 firstActiveBlock
    );

    event TierMinted(bytes32 indexed positionKey, address indexed owner, uint256 tokenId);
    event TierUpgraded(bytes32 indexed positionKey, uint256 indexed tokenId, uint8 newTier);

    constructor(IPoolManager _poolManager, HoldfastNFT _nft) BaseHook(_poolManager) {
        nft = _nft;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
    }

    /// @inheritdoc IHoldfastHook
    /// @dev Stub: real settlement logic lands in Day 7-8 once bonus pool accounting exists.
    function settleOnTransfer(bytes32 positionKey, address from, address to) external {
        require(msg.sender == address(nft), "HoldfastHook: only nft");
        positionKey; from; to;
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
    }

    function _evaluateNextTier(uint8 currentTier, uint256 accumulatedScore, uint256 blocksActive)
        internal
        pure
        returns (uint8 nextTier)
    {
        if (currentTier < TIER_GOLD && accumulatedScore >= GOLD_SCORE && blocksActive >= GOLD_BLOCKS) {
            return TIER_GOLD;
        }
        if (currentTier < TIER_SILVER && accumulatedScore >= SILVER_SCORE && blocksActive >= SILVER_BLOCKS) {
            return TIER_SILVER;
        }
        if (currentTier < TIER_BRONZE && accumulatedScore >= BRONZE_SCORE && blocksActive >= BRONZE_BLOCKS) {
            return TIER_BRONZE;
        }
        return currentTier;
    }
}
