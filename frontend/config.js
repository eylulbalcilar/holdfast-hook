// Holdfast frontend config.
// Switch ENV between "anvil" and "sepolia" to retarget.

export const ENV = "anvil";

export const NETWORKS = {
  anvil: {
    chainId: 31337,
    name: "Anvil (Base mainnet fork)",
    rpcUrl: "http://127.0.0.1:8545",
    blockExplorer: null,
  },
  sepolia: {
    chainId: 84532,
    name: "Base Sepolia",
    rpcUrl: "https://sepolia.base.org",
    blockExplorer: "https://sepolia.basescan.org",
  },
};

// Contract addresses, filled after local deploy (Step 2 prep).
export const ADDRESSES = {
  anvil: {
    holdfastHook: "0x0000000000000000000000000000000000000000",
    holdfastNFT: "0x0000000000000000000000000000000000000000",
    yieldRouter: "0x0000000000000000000000000000000000000000",
    poolManager: "0x0000000000000000000000000000000000000000",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // Base mainnet USDC (fork keeps mainnet addresses)
    aUSDC: "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB", // Base mainnet aUSDC
    poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
  },
  sepolia: {
    holdfastHook: "0x0000000000000000000000000000000000000000",
    holdfastNFT: "0x0000000000000000000000000000000000000000",
    yieldRouter: "0x0000000000000000000000000000000000000000",
    poolManager: "0x0000000000000000000000000000000000000000",
    usdc: "0x0000000000000000000000000000000000000000",
    aUSDC: "0x0000000000000000000000000000000000000000",
    poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
  },
};

export const CURRENT = {
  network: NETWORKS[ENV],
  addresses: ADDRESSES[ENV],
};

// Tier thresholds (mirrors HoldfastHook constants).
export const TIERS = {
  BRONZE: { score: 10n * 10n ** 18n, blocks: 1000n, name: "Bronze" },
  SILVER: { score: 100n * 10n ** 18n, blocks: 10000n, name: "Silver" },
  GOLD: { score: 1000n * 10n ** 18n, blocks: 100000n, name: "Gold" },
};
