// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HoldfastHook} from "../../src/HoldfastHook.sol";
import {HoldfastNFT} from "../../src/HoldfastNFT.sol";
import {YieldRouter} from "../../src/YieldRouter.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title HoldfastHookHarness
/// @notice Test-only subclass that exposes HoldfastHook's internal pure helpers
///         and tier constants. Production surface stays minimal; harness lives
///         only under test/.
contract HoldfastHookHarness is HoldfastHook {
    constructor(IPoolManager _poolManager, HoldfastNFT _nft, YieldRouter _yieldRouter) HoldfastHook(_poolManager, _nft, _yieldRouter) {}

    function exposed_positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return _positionKey(owner, tickLower, tickUpper, salt);
    }

    function exposed_evaluateNextTier(uint8 currentTier, uint256 accumulatedScore, uint256 blocksActive)
        external
        pure
        returns (uint8)
    {
        return _evaluateNextTier(currentTier, accumulatedScore, blocksActive);
    }

    // Constants re-exposed for assertions
    function TIER_NONE_() external pure returns (uint8) { return TIER_NONE; }
    function TIER_BRONZE_() external pure returns (uint8) { return TIER_BRONZE; }
    function TIER_SILVER_() external pure returns (uint8) { return TIER_SILVER; }
    function TIER_GOLD_() external pure returns (uint8) { return TIER_GOLD; }

    function BRONZE_SCORE_() external pure returns (uint256) { return BRONZE_SCORE; }
    function SILVER_SCORE_() external pure returns (uint256) { return SILVER_SCORE; }
    function GOLD_SCORE_() external pure returns (uint256) { return GOLD_SCORE; }

    function BRONZE_BLOCKS_() external pure returns (uint256) { return BRONZE_BLOCKS; }
    function SILVER_BLOCKS_() external pure returns (uint256) { return SILVER_BLOCKS; }
    function GOLD_BLOCKS_() external pure returns (uint256) { return GOLD_BLOCKS; }

    function exposed_afterInitialize(PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4)
    {
        return _afterInitialize(address(0), key, sqrtPriceX96, tick);
    }

    function getVolatilityObservation(PoolId poolId, uint8 idx) external view returns (uint256) {
        return volatility[poolId].recentPriceObservations[idx];
    }

    function getVolatilityMeta(PoolId poolId)
        external
        view
        returns (uint8 cursor, uint256 cachedVolatility, uint256 lastVolUpdate)
    {
        PoolVolatility storage v = volatility[poolId];
        return (v.cursor, v.cachedVolatility, v.lastVolUpdate);
    }

    function VOL_BUFFER_LEN_() external pure returns (uint8) { return VOL_BUFFER_LEN; }

    function exposed_evaluateAndMaybeMint(bytes32 positionKey, address owner) external {
        _evaluateAndMaybeMint(positionKey, owner);
    }

    function setStreakScore(bytes32 positionKey, uint256 score) external {
        streaks[positionKey].accumulatedScore = score;
    }

    function exposed_volatilityMultiplier(uint256 volatilityFactor) external pure returns (uint256) {
        return _volatilityMultiplier(volatilityFactor);
    }
}
