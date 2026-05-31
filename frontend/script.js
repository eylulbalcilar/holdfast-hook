import { createPublicClient, createWalletClient, custom, http, defineChain } from "https://esm.sh/viem@2.x";
import { CURRENT } from "./config.js";

// --- Provider selection (prefer MetaMask over Coinbase or others) ---
function getMetaMaskProvider() {
  if (!window.ethereum) return null;
  if (window.ethereum.providers?.length) {
    return window.ethereum.providers.find((p) => p.isMetaMask) ?? null;
  }
  return window.ethereum.isMetaMask ? window.ethereum : null;
}

// --- Chain definition ---
const holdfastChain = defineChain({
  id: CURRENT.network.chainId,
  name: CURRENT.network.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CURRENT.network.rpcUrl] } },
});

// --- Clients ---
const publicClient = createPublicClient({
  chain: holdfastChain,
  transport: http(CURRENT.network.rpcUrl),
});

let walletClient = null;
let account = null;

// --- DOM helpers ---
const $ = (id) => document.getElementById(id);
const shorten = (addr) => `${addr.slice(0, 6)}...${addr.slice(-4)}`;

function setWalletStatus(text) {
  $("wallet-status").textContent = text;
}

function setConnectButton(text, disabled = false) {
  const btn = $("connect-btn");
  btn.textContent = text;
  btn.disabled = disabled;
}

// --- Wallet connect ---
async function connectWallet() {
  const provider = getMetaMaskProvider();
  if (!provider) {
    setWalletStatus("MetaMask not found");
    return;
  }

  setConnectButton("Connecting...", true);

  try {
    walletClient = createWalletClient({
      chain: holdfastChain,
      transport: custom(provider),
    });

    const [address] = await walletClient.requestAddresses();
    account = address;

    const currentChainId = await walletClient.getChainId();
    if (currentChainId !== CURRENT.network.chainId) {
      await switchOrAddChain(provider);
    }

    setWalletStatus(shorten(address));
    setConnectButton("Connected", true);

    console.log("[holdfast] connected:", address, "chain:", currentChainId);
  } catch (err) {
    console.error("[holdfast] connect failed:", err);
    setWalletStatus("Connection rejected");
    setConnectButton("Connect Wallet", false);
  }
}

async function switchOrAddChain(provider) {
  const hexId = `0x${CURRENT.network.chainId.toString(16)}`;
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: hexId }],
    });
  } catch (err) {
    if (err.code === 4902) {
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: hexId,
          chainName: CURRENT.network.name,
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          rpcUrls: [CURRENT.network.rpcUrl],
        }],
      });
    } else {
      throw err;
    }
  }
}

// --- Account / chain change listeners ---
const mmProvider = getMetaMaskProvider();
if (mmProvider) {
  mmProvider.on("accountsChanged", (accounts) => {
    if (accounts.length === 0) {
      account = null;
      walletClient = null;
      setWalletStatus("Not connected");
      setConnectButton("Connect Wallet", false);
    } else {
      account = accounts[0];
      setWalletStatus(shorten(account));
    }
  });

  mmProvider.on("chainChanged", () => {
    window.location.reload();
  });
}

// --- Init ---
$("connect-btn").addEventListener("click", connectWallet);

publicClient.getBlockNumber()
  .then((bn) => console.log("[holdfast] RPC ok, block:", bn))
  .catch((err) => console.error("[holdfast] RPC failed:", err.message));

console.log("[holdfast] target:", CURRENT.network.name, "chainId:", CURRENT.network.chainId);
