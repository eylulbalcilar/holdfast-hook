import { createPublicClient, createWalletClient, custom, http, defineChain, formatUnits } from "https://esm.sh/viem@2.x";
import { CURRENT, TIERS } from "./config.js";

// --- Provider selection ---
function getMetaMaskProvider() {
  if (!window.ethereum) return null;
  if (window.ethereum.providers?.length) {
    return window.ethereum.providers.find((p) => p.isMetaMask) ?? null;
  }
  return window.ethereum.isMetaMask ? window.ethereum : null;
}

// --- Chain ---
const holdfastChain = defineChain({
  id: CURRENT.network.chainId,
  name: CURRENT.network.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CURRENT.network.rpcUrl] } },
});

const publicClient = createPublicClient({
  chain: holdfastChain,
  transport: http(CURRENT.network.rpcUrl),
});

let walletClient = null;
let account = null;
let deployment = null;
let abis = {};

// Minimal ERC20 ABI for balance reads
const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint8" }] },
];

// --- DOM helpers ---
const $ = (id) => document.getElementById(id);
const shorten = (addr) => `${addr.slice(0, 6)}...${addr.slice(-4)}`;
const fmtUsdc = (raw) => Number(formatUnits(raw, 6)).toLocaleString("en-US", { maximumFractionDigits: 2 });
const fmtPct = (bps) => `${(Number(bps) / 100).toFixed(2)}%`;

function setWalletStatus(text) { $("wallet-status").textContent = text; }
function setConnectButton(text, disabled = false) {
  const btn = $("connect-btn");
  btn.textContent = text;
  btn.disabled = disabled;
}

// --- Load deployment + ABIs ---
async function loadDeployment() {
  const chainId = CURRENT.network.chainId;
  try {
    const res = await fetch(`./deployments/${chainId}.json`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    deployment = await res.json();
    console.log("[holdfast] deployment loaded:", deployment);
  } catch (err) {
    console.error("[holdfast] deployment fetch failed:", err.message);
    $("pool-state-body").innerHTML = `<p class="muted">No deployment found for chainId ${chainId}</p>`;
    $("bonus-pool-body").innerHTML = `<p class="muted">No deployment found</p>`;
    return false;
  }

  const [hookAbi, nftAbi, routerAbi] = await Promise.all([
    fetch("./abis/HoldfastHook.json").then((r) => r.json()),
    fetch("./abis/HoldfastNFT.json").then((r) => r.json()),
    fetch("./abis/YieldRouter.json").then((r) => r.json()),
  ]);
  abis = { hook: hookAbi, nft: nftAbi, router: routerAbi };
  console.log("[holdfast] ABIs loaded");
  return true;
}

// --- Read protocol-level state ---
async function refreshPoolState() {
  try {
    const blockNumber = await publicClient.getBlockNumber();

    $("pool-state-body").innerHTML = `
      <div class="stat-row">
        <span class="stat-label">Hook</span>
        <span class="stat-value">${shorten(deployment.holdfastHook)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">NFT</span>
        <span class="stat-value">${shorten(deployment.holdfastNFT)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Yield Router</span>
        <span class="stat-value">${shorten(deployment.yieldRouter)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Block</span>
        <span class="stat-value">${blockNumber.toString()}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Status</span>
        <span class="stat-value muted">No pool initialized</span>
      </div>
    `;
  } catch (err) {
    console.error("[holdfast] refreshPoolState failed:", err);
    $("pool-state-body").innerHTML = `<p class="muted">Read failed: ${err.shortMessage ?? err.message}</p>`;
  }
}

async function refreshBonusPool() {
  try {
    const [routerUsdc, routerAUsdc, aUsdcAddr] = await Promise.all([
      publicClient.readContract({
        address: deployment.usdc,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [deployment.yieldRouter],
      }),
      publicClient.readContract({
        address: deployment.yieldRouter,
        abi: abis.router,
        functionName: "aUsdc",
      }).then((addr) =>
        publicClient.readContract({
          address: addr,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [deployment.yieldRouter],
        })
      ).catch(() => 0n),
      publicClient.readContract({
        address: deployment.yieldRouter,
        abi: abis.router,
        functionName: "aUsdc",
      }).catch(() => "0x0"),
    ]);

    const totalBonus = routerUsdc + routerAUsdc;

    $("bonus-pool-body").innerHTML = `
      <div class="big-value">$${fmtUsdc(totalBonus)} USDC</div>
      <div class="stat-row">
        <span class="stat-label">Router idle USDC</span>
        <span class="stat-value">$${fmtUsdc(routerUsdc)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">Supplied to Aave V3</span>
        <span class="stat-value">$${fmtUsdc(routerAUsdc)}</span>
      </div>
      <div class="stat-row">
        <span class="stat-label">aUSDC token</span>
        <span class="stat-value">${shorten(aUsdcAddr)}</span>
      </div>
    `;
  } catch (err) {
    console.error("[holdfast] refreshBonusPool failed:", err);
    $("bonus-pool-body").innerHTML = `<p class="muted">Read failed: ${err.shortMessage ?? err.message}</p>`;
  }
}

async function refreshAll() {
  if (!deployment) return;
  await Promise.all([refreshPoolState(), refreshBonusPool()]);
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
    walletClient = createWalletClient({ chain: holdfastChain, transport: custom(provider) });
    const [address] = await walletClient.requestAddresses();
    account = address;

    const currentChainId = await walletClient.getChainId();
    if (currentChainId !== CURRENT.network.chainId) {
      await switchOrAddChain(provider);
    }

    setWalletStatus(shorten(address));
    setConnectButton("Connected", true);
    console.log("[holdfast] connected:", address);
  } catch (err) {
    console.error("[holdfast] connect failed:", err);
    setWalletStatus("Connection rejected");
    setConnectButton("Connect Wallet", false);
  }
}

async function switchOrAddChain(provider) {
  const hexId = `0x${CURRENT.network.chainId.toString(16)}`;
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
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
  mmProvider.on("chainChanged", () => window.location.reload());
}

// --- Init ---
$("connect-btn").addEventListener("click", connectWallet);

console.log("[holdfast] target:", CURRENT.network.name, "chainId:", CURRENT.network.chainId);

(async () => {
  const ok = await loadDeployment();
  if (ok) await refreshAll();
})();
