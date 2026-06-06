// Holdfast frontend config.
// Switch ENV between "anvil" and "sepolia" to retarget.

export const ENV = "sepolia";

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
    rpcUrl: "https://base-sepolia-rpc.publicnode.com",
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
    holdfastHook: "0xE793eaf666ED37ef8573784f8c5fc33920dF57c4",
    holdfastNFT: "0x5a3a19952E6eeAA2f5bF41977ffbF1C106092097",
    yieldRouter: "0x0F77E49237c88242652788dfCC829a61AA250C1A",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    stateView: "0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4",
    usdc: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",
    aUSDC: "0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC",
    poolId: "0x10ad9a3049c38eca566db11f305f4663ff7b68a2022a860e97e99d69dddebe9f",
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
