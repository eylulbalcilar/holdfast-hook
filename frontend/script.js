import { createPublicClient, createWalletClient, custom, http, defineChain, formatUnits, parseAbiItem } from "https://esm.sh/viem@2.x";
import { CURRENT, TIERS } from "./config.js";

function getMetaMaskProvider() {
  if (!window.ethereum) return null;
  if (window.ethereum.providers?.length) {
    return window.ethereum.providers.find((p) => p.isMetaMask) ?? null;
  }
  return window.ethereum.isMetaMask ? window.ethereum : null;
}

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

const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint8" }] },
];

const transferEvent = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)");

const $ = (id) => document.getElementById(id);
const shorten = (addr) => `${addr.slice(0, 6)}...${addr.slice(-4)}`;
const fmtUsdc = (raw) => Number(formatUnits(raw, 6)).toLocaleString("en-US", { maximumFractionDigits: 2 });
const fmtWad = (raw) => Number(formatUnits(raw, 18)).toLocaleString("en-US", { maximumFractionDigits: 4 });

function setWalletStatus(text) { $("wallet-status").textContent = text; }
function setConnectButton(text, disabled = false) {
  const btn = $("connect-btn");
  btn.textContent = text;
  btn.disabled = disabled;
}

const TIER_NAMES = { 0: "None", 1: "Bronze", 2: "Silver", 3: "Gold" };
const TIER_CLASS = { 0: "tier-none", 1: "tier-bronze", 2: "tier-silver", 3: "tier-gold" };

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

async function refreshPoolState() {
  try {
    const blockNumber = await publicClient.getBlockNumber();
    $("pool-state-body").innerHTML = `
      <div class="stat-row"><span class="stat-label">Hook</span><span class="stat-value">${shorten(deployment.holdfastHook)}</span></div>
      <div class="stat-row"><span class="stat-label">NFT</span><span class="stat-value">${shorten(deployment.holdfastNFT)}</span></div>
      <div class="stat-row"><span class="stat-label">Yield Router</span><span class="stat-value">${shorten(deployment.yieldRouter)}</span></div>
      <div class="stat-row"><span class="stat-label">Block</span><span class="stat-value">${blockNumber.toString()}</span></div>
      <div class="stat-row"><span class="stat-label">Status</span><span class="stat-value muted">No pool initialized</span></div>
    `;
  } catch (err) {
    console.error("[holdfast] refreshPoolState failed:", err);
    $("pool-state-body").innerHTML = `<p class="muted">Read failed: ${err.shortMessage ?? err.message}</p>`;
  }
}

async function refreshBonusPool() {
  try {
    const aUsdcAddr = await publicClient.readContract({
      address: deployment.yieldRouter, abi: abis.router, functionName: "aUsdc",
    }).catch(() => null);

    const routerUsdc = await publicClient.readContract({
      address: deployment.usdc, abi: erc20Abi, functionName: "balanceOf", args: [deployment.yieldRouter],
    });

    let routerAUsdc = 0n;
    if (aUsdcAddr) {
      routerAUsdc = await publicClient.readContract({
        address: aUsdcAddr, abi: erc20Abi, functionName: "balanceOf", args: [deployment.yieldRouter],
      }).catch(() => 0n);
    }

    const totalBonus = routerUsdc + routerAUsdc;
    $("bonus-pool-body").innerHTML = `
      <div class="big-value">$${fmtUsdc(totalBonus)} USDC</div>
      <div class="stat-row"><span class="stat-label">Router idle USDC</span><span class="stat-value">$${fmtUsdc(routerUsdc)}</span></div>
      <div class="stat-row"><span class="stat-label">Supplied to Aave V3</span><span class="stat-value">$${fmtUsdc(routerAUsdc)}</span></div>
      <div class="stat-row"><span class="stat-label">aUSDC token</span><span class="stat-value">${aUsdcAddr ? shorten(aUsdcAddr) : "n/a"}</span></div>
    `;
  } catch (err) {
    console.error("[holdfast] refreshBonusPool failed:", err);
    $("bonus-pool-body").innerHTML = `<p class="muted">Read failed: ${err.shortMessage ?? err.message}</p>`;
  }
}

async function findUserTokenIds(userAddress) {
  // Anvil fork delegates eth_getLogs to Alchemy. Free tier caps query ranges,
  // so we scan in small chunks across a recent window.
  const currentBlock = await publicClient.getBlockNumber();
  const CHUNK = 9n;
  const MAX_LOOKBACK = 100n;
  const startBlock = currentBlock > MAX_LOOKBACK ? currentBlock - MAX_LOOKBACK : 0n;

  const owned = new Set();
  const removed = new Set();

  for (let from = startBlock; from <= currentBlock; from += CHUNK + 1n) {
    const to = from + CHUNK > currentBlock ? currentBlock : from + CHUNK;
    try {
      const incoming = await publicClient.getLogs({
        address: deployment.holdfastNFT,
        event: transferEvent,
        args: { to: userAddress },
        fromBlock: from,
        toBlock: to,
      });
      for (const log of incoming) owned.add(log.args.tokenId);

      const outgoing = await publicClient.getLogs({
        address: deployment.holdfastNFT,
        event: transferEvent,
        args: { from: userAddress },
        fromBlock: from,
        toBlock: to,
      });
      for (const log of outgoing) removed.add(log.args.tokenId);
    } catch (err) {
      console.warn(`[holdfast] getLogs failed at ${from}-${to}:`, err.shortMessage ?? err.message);
    }
  }

  for (const id of removed) owned.delete(id);

  const finalOwned = [];
  for (const tokenId of owned) {
    try {
      const currentOwner = await publicClient.readContract({
        address: deployment.holdfastNFT, abi: abis.nft, functionName: "ownerOf", args: [tokenId],
      });
      if (currentOwner.toLowerCase() === userAddress.toLowerCase()) {
        finalOwned.push(tokenId);
      }
    } catch {}
  }
  return finalOwned;
}

function tierProgress(score, blocks, currentTier) {
  if (currentTier >= 3) return { pct: 100, label: "Max tier (Gold)" };
  const next = currentTier === 0 ? TIERS.BRONZE : currentTier === 1 ? TIERS.SILVER : TIERS.GOLD;
  const nextName = currentTier === 0 ? "Bronze" : currentTier === 1 ? "Silver" : "Gold";
  const scorePct = Math.min(100, Number((score * 100n) / next.score));
  const blockPct = Math.min(100, Number((blocks * 100n) / next.blocks));
  const pct = Math.min(scorePct, blockPct);
  return { pct, label: `${pct}% to ${nextName}` };
}
// --- Transaction status ---
function setTxStatus(state, message) {
  const body = $("tx-status-body");
  if (state === "idle") {
    body.innerHTML = `<p class="muted">Idle</p>`;
  } else if (state === "pending") {
    body.innerHTML = `<p class="tx-pending">Pending: ${message}</p>`;
  } else if (state === "success") {
    body.innerHTML = `<p class="tx-success">Success: ${message}</p>`;
  } else if (state === "error") {
    body.innerHTML = `<p class="tx-error">Error: ${message}</p>`;
  }
}

// --- Auto-fund (dev only): give the connected account gas on Anvil ---
async function ensureGasOnAnvil(address) {
  if (CURRENT.network.chainId !== 31337) return;
  try {
    const balance = await publicClient.getBalance({ address });
    if (balance > 10n ** 17n) return; // already has >0.1 ETH
    await fetch(CURRENT.network.rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "anvil_setBalance",
        params: [address, "0x8AC7230489E80000"], // 10 ETH
      }),
    });
    console.log("[holdfast] funded", address, "with 10 ETH on Anvil");
  } catch (err) {
    console.warn("[holdfast] auto-fund failed:", err.message);
  }
}

// --- Claim rewards ---
async function claimRewards(tokenId) {
  if (!walletClient || !account) {
    setTxStatus("error", "Wallet not connected");
    return;
  }
  setTxStatus("pending", `claim(${tokenId})`);

  try {
    const hash = await walletClient.writeContract({
      account,
      address: deployment.holdfastHook,
      abi: abis.hook,
      functionName: "claim",
      args: [BigInt(tokenId)],
    });
    setTxStatus("pending", `tx ${shorten(hash)}, waiting for receipt`);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === "success") {
      setTxStatus("success", `tx ${shorten(hash)}`);
      await refreshAll();
    } else {
      setTxStatus("error", `tx reverted: ${shorten(hash)}`);
    }
  } catch (err) {
    console.error("[holdfast] claim failed:", err);
    setTxStatus("error", err.shortMessage ?? err.message);
  }
}

// --- Claim button delegation ---
document.addEventListener("click", (e) => {
  if (e.target.classList?.contains("claim-btn")) {
    const tokenId = e.target.dataset.tokenId;
    if (tokenId) claimRewards(tokenId);
  }
});

async function renderPositions(userAddress) {
  if (!userAddress) {
    $("positions-body").innerHTML = `<p class="muted">Connect wallet to view positions</p>`;
    return;
  }
  $("positions-body").innerHTML = `<p class="muted">Loading positions...</p>`;

  const tokenIds = await findUserTokenIds(userAddress);
  if (tokenIds.length === 0) {
    $("positions-body").innerHTML = `<p class="muted">No positions yet. Add liquidity to a Holdfast pool to start.</p>`;
    return;
  }

  const cards = await Promise.all(tokenIds.map(async (tokenId) => {
    const positionKey = await publicClient.readContract({
      address: deployment.holdfastNFT, abi: abis.nft, functionName: "tokenIdToPositionKey", args: [tokenId],
    });
    const tier = await publicClient.readContract({
      address: deployment.holdfastNFT, abi: abis.nft, functionName: "tokenIdToTier", args: [tokenId],
    });
    const streak = await publicClient.readContract({
      address: deployment.holdfastHook, abi: abis.hook, functionName: "streaks", args: [positionKey],
    });

    const accumulatedScore = streak[0] ?? streak.accumulatedScore ?? 0n;
    const firstActiveBlock = streak[2] ?? streak.firstActiveBlock ?? 0n;
    const entrySqrtPrice = streak[3] ?? streak.entrySqrtPriceX96 ?? 0n;
    const isActive = streak[7] ?? streak.isActive ?? false;
    const realizedIL = streak[8] ?? streak.realizedIL ?? 0n;

    const currentBlock = await publicClient.getBlockNumber();
    const blocksActive = firstActiveBlock > 0n ? currentBlock - firstActiveBlock : 0n;
    const progress = tierProgress(accumulatedScore, blocksActive, Number(tier));

    const ilDisplay = realizedIL === 0n
      ? "Not closed"
      : (realizedIL < 0n ? "-" : "") + fmtWad(realizedIL < 0n ? -realizedIL : realizedIL);

    return `
      <div class="position-card">
        <div class="position-header">
          <span class="position-id">Token #${tokenId.toString()}</span>
          <span class="tier-badge ${TIER_CLASS[Number(tier)]}">${TIER_NAMES[Number(tier)]}</span>
        </div>
        <div class="position-stats">
          <div>
            <div class="position-stat-label">Accumulated Score</div>
            <div class="position-stat-value">${fmtWad(accumulatedScore)}</div>
          </div>
          <div>
            <div class="position-stat-label">Blocks Active</div>
            <div class="position-stat-value">${blocksActive.toString()}</div>
          </div>
          <div>
            <div class="position-stat-label">Entry sqrtPrice</div>
            <div class="position-stat-value">${shorten(entrySqrtPrice.toString())}</div>
          </div>
          <div>
            <div class="position-stat-label">Realized IL</div>
            <div class="position-stat-value">${ilDisplay}</div>
          </div>
        </div>
        <div class="progress-block">
          <div class="progress-label"><span>Tier progress</span><span>${progress.label}</span></div>
          <div class="progress-bar"><div class="progress-fill" style="width: ${progress.pct}%"></div></div>
        </div>
        <button class="claim-btn" data-token-id="${tokenId.toString()}" ${isActive ? "" : "disabled"}>Claim Rewards</button>
      </div>
    `;
  }));

  $("positions-body").innerHTML = cards.join("");
}

async function refreshAll() {
  if (!deployment) return;
  await Promise.all([refreshPoolState(), refreshBonusPool()]);
  if (account) await renderPositions(account);
}

async function connectWallet() {
  const provider = getMetaMaskProvider();
  if (!provider) { setWalletStatus("MetaMask not found"); return; }
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
    await ensureGasOnAnvil(address);
    await renderPositions(address);
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
          chainId: hexId, chainName: CURRENT.network.name,
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          rpcUrls: [CURRENT.network.rpcUrl],
        }],
      });
    } else { throw err; }
  }
}

const mmProvider = getMetaMaskProvider();
if (mmProvider) {
  mmProvider.on("accountsChanged", (accounts) => {
    if (accounts.length === 0) {
      account = null; walletClient = null;
      setWalletStatus("Not connected");
      setConnectButton("Connect Wallet", false);
      $("positions-body").innerHTML = `<p class="muted">Connect wallet to view positions</p>`;
    } else {
      account = accounts[0];
      setWalletStatus(shorten(account));
      renderPositions(account);
    }
  });
  mmProvider.on("chainChanged", () => window.location.reload());
}

$("connect-btn").addEventListener("click", connectWallet);

console.log("[holdfast] target:", CURRENT.network.name, "chainId:", CURRENT.network.chainId);

(async () => {
  const ok = await loadDeployment();
  if (ok) await refreshAll();
})();
