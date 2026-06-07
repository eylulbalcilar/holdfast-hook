// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";

import {HoldfastHookV2} from "../src/HoldfastHookV2.sol";
import {HoldfastNFT} from "../src/HoldfastNFT.sol";
import {YieldRouter} from "../src/YieldRouter.sol";

import {BaseSepoliaConstants} from "./constants/BaseSepolia.sol";

/// @notice Deploys the subscriber-native HoldfastHookV2 stack (NFT, YieldRouter, Hook) to Base
///         Sepolia. Separate from Deploy.s.sol, which deploys the V1 stack and stays as the
///         fallback. V2 is scoped to Base Sepolia: it requires the canonical PositionManager
///         (the ISubscriber counterparty), which has no BaseMainnet constant here.
/// @dev Writes deployment addresses to frontend/deployments/<chainid>.json for the dashboard.
contract DeployV2 is Script {
    // CREATE2_FACTORY (Foundry's deterministic deployer, 0x4e59...) is inherited from forge-std's
    // CommonBase. `new X{salt}` under broadcast deploys through it, so the hook address is mined
    // against this deployer.

    struct DeployConfig {
        address poolManager;
        address positionManager;
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
            // No PRIVATE_KEY in env, use Anvil's default test account 0.
            deployerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        address deployer = vm.addr(deployerPk);
        console2.log("Deployer:", deployer);
        console2.log("ChainId:", block.chainid);

        vm.startBroadcast(deployerPk);

        // 1. NFT (tier badge), owned by the deployer for the one-time setHook bind.
        HoldfastNFT nft = new HoldfastNFT(deployer);
        console2.log("HoldfastNFT:", address(nft));

        // 2. YieldRouter. Its constructor reads the aUSDC address from the Aave reserve and
        //    reverts AaveReserveInactive if that reserve is not configured.
        YieldRouter router = new YieldRouter(cfg.aavePool, cfg.usdc, deployer);
        console2.log("YieldRouter:", address(router));

        // 3. Mine the hook salt for V2's exact permission flags.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(cfg.poolManager),
            IPositionManager(cfg.positionManager),
            nft,
            router,
            cfg.usdc
        );

        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(HoldfastHookV2).creationCode, constructorArgs);
        console2.log("Hook salt mined, target address:", hookAddr);

        // 4. Deploy the hook at the mined CREATE2 address. BaseHook's constructor validates that
        //    the address encodes exactly these permissions, so a flag mismatch reverts here.
        HoldfastHookV2 hook = new HoldfastHookV2{salt: salt}(
            IPoolManager(cfg.poolManager),
            IPositionManager(cfg.positionManager),
            nft,
            router,
            cfg.usdc
        );
        require(address(hook) == hookAddr, "Hook address mismatch after CREATE2");
        console2.log("HoldfastHookV2:", address(hook));

        // 5. Bind the hook into the NFT and the YieldRouter (one-time binds).
        nft.setHook(address(hook));
        router.setHook(address(hook));
        console2.log("Bindings set");

        vm.stopBroadcast();

        // 6. Write deployment JSON for the frontend.
        _writeDeploymentJson(
            Deployed({nft: address(nft), yieldRouter: address(router), hook: address(hook)}), cfg
        );
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        if (block.chainid == BaseSepoliaConstants.CHAIN_ID) {
            cfg.poolManager = BaseSepoliaConstants.POOL_MANAGER;
            cfg.positionManager = BaseSepoliaConstants.POSITION_MANAGER;
            cfg.aavePool = BaseSepoliaConstants.AAVE_V3_POOL;
            cfg.usdc = BaseSepoliaConstants.USDC;
        } else {
            revert("DeployV2: only Base Sepolia is supported");
        }
    }

    function _writeDeploymentJson(Deployed memory d, DeployConfig memory cfg) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "holdfastHook", d.hook);
        vm.serializeAddress(obj, "holdfastNFT", d.nft);
        vm.serializeAddress(obj, "yieldRouter", d.yieldRouter);
        vm.serializeAddress(obj, "poolManager", cfg.poolManager);
        vm.serializeAddress(obj, "positionManager", cfg.positionManager);
        vm.serializeAddress(obj, "aavePool", cfg.aavePool);
        string memory json = vm.serializeAddress(obj, "usdc", cfg.usdc);

        string memory path = string.concat("./frontend/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment written:", path);
    }
}
