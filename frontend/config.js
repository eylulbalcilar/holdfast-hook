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
    rpcUrl: "https://sepolia.base.org",
    blockExplorer: "https://sepolia.basescan.org",
  },
};

export const ADDRESSES = {
  anvil: {
    holdfastHook: "0x0000000000000000000000000000000000000000",
    holdfastNFT: "0x0000000000000000000000000000000000000000",
    yieldRouter: "0x0000000000000000000000000000000000000000",
    poolManager: "0x0000000000000000000000000000000000000000",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    aUSDC: "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB",
    poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
  },
  sepolia: {
    holdfastHook: "0xAbCada5D4ca9CD87E74F6ED3daA3974ad39d90c4",
    holdfastNFT: "0x4D54F634Dc5461866d174825fCAaFD8481Fe6EC7",
    yieldRouter: "0xa24cbe3667fCAa4C3a53efB045b7bb5c5C698f57",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    stateView: "0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4",
    usdc: "0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f",
    aUSDC: "0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC",
    poolId: "0x066b6b57b4c1cf1031b59355cc6fc7db88cb29efb9258eaa2a3ecc49446c08b7",
    demoTokenId: "24915",
    poolSwapTest: "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9",
    weth: "0x4200000000000000000000000000000000000006",
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
