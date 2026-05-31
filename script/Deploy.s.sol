// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

import {HoldfastHook} from "../src/HoldfastHook.sol";
import {HoldfastNFT} from "../src/HoldfastNFT.sol";
import {YieldRouter} from "../src/YieldRouter.sol";

import {BaseMainnet} from "../test/fork/constants/BaseMainnet.sol";
import {BaseSepoliaConstants} from "./constants/BaseSepolia.sol";

/// @notice Deploy Holdfast (NFT, YieldRouter, Hook) to Base mainnet (Anvil fork) or Base Sepolia.
/// @dev    Selects external addresses (PoolManager, Aave V3 Pool, USDC) by block.chainid.
///         Writes deployment addresses to frontend/deployments/<chainid>.json for the dashboard.
contract Deploy is Script {
    struct DeployConfig {
        address poolManager;
        address aavePool;
        address usdc;
    }

    struct Deployed {
        address nft;
        address yieldRouter;
        address hook;
    }

    function run() external {
        DeployConfig memory cfg = _loadConfig();

        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerPk == 0) {
            // No PRIVATE_KEY in env, use Anvil's default test account 0
            deployerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        address deployer = vm.addr(deployerPk);
        console2.log("Deployer:", deployer);
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(deployerPk);

        // 1. NFT
        HoldfastNFT nft = new HoldfastNFT(deployer);
        console2.log("HoldfastNFT:", address(nft));

        // 2. YieldRouter
        YieldRouter router = new YieldRouter(cfg.aavePool, cfg.usdc, deployer);
        console2.log("YieldRouter:", address(router));

        // 3. Mine hook salt for the required permission flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(cfg.poolManager),
            nft,
            router,
            cfg.usdc
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            flags,
            type(HoldfastHook).creationCode,
            constructorArgs
        );
        console2.log("Hook salt mined, target address:", hookAddr);

        // 4. Deploy hook at mined CREATE2 address
        HoldfastHook hook = new HoldfastHook{salt: salt}(
            IPoolManager(cfg.poolManager),
            nft,
            router,
            cfg.usdc
        );
        require(address(hook) == hookAddr, "Hook address mismatch after CREATE2");
        console2.log("HoldfastHook:", address(hook));

        // 5. Bind hook into NFT and YieldRouter
        nft.setHook(address(hook));
        router.setHook(address(hook));
        console2.log("Bindings set");

        vm.stopBroadcast();

        // 6. Write deployment JSON for the frontend
        _writeDeploymentJson(Deployed({
            nft: address(nft),
            yieldRouter: address(router),
            hook: address(hook)
        }), cfg);
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        if (block.chainid == 8453 || block.chainid == 31337) {
            cfg.poolManager = BaseMainnet.POOL_MANAGER;
            cfg.aavePool = BaseMainnet.AAVE_V3_POOL;
            cfg.usdc = BaseMainnet.USDC;
        } else if (block.chainid == BaseSepoliaConstants.CHAIN_ID) {
            cfg.poolManager = BaseSepoliaConstants.POOL_MANAGER;
            cfg.aavePool = BaseSepoliaConstants.AAVE_V3_POOL;
            cfg.usdc = BaseSepoliaConstants.USDC;
        } else {
            revert("Deploy: unsupported chainid");
        }
    }

    function _writeDeploymentJson(Deployed memory d, DeployConfig memory cfg) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "holdfastHook", d.hook);
        vm.serializeAddress(obj, "holdfastNFT", d.nft);
        vm.serializeAddress(obj, "yieldRouter", d.yieldRouter);
        vm.serializeAddress(obj, "poolManager", cfg.poolManager);
        vm.serializeAddress(obj, "aavePool", cfg.aavePool);
        string memory json = vm.serializeAddress(obj, "usdc", cfg.usdc);

        string memory path = string.concat(
            "./frontend/deployments/",
            vm.toString(block.chainid),
            ".json"
        );
        vm.writeJson(json, path);
        console2.log("Deployment written:", path);
    }
}
