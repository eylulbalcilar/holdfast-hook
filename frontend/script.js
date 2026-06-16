import { createPublicClient, createWalletClient, custom, http, defineChain, formatUnits, parseUnits } from "https://esm.sh/viem@2.x";
import { CURRENT, TIERS } from "./config.js";

function getMetaMaskProvider() {
  if (!window.ethereum) return null;
  if (window.ethereum.providers?.length) {
    return window.ethereum.providers.find((p) => p.isCoinbaseWallet)
        ?? window.ethereum.providers.find((p) => p.isMetaMask)
        ?? window.ethereum.providers[0];
  }
  return window.ethereum;
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
    deployment = CURRENT.addresses;
    console.log("[holdfast] falling back to config addresses");
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

const STATE_VIEW_ABI = [
  { type: "function", name: "getSlot0", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ] },
];

async function refreshPoolState() {
  try {
    const blockNumber = await publicClient.getBlockNumber();
    let statusHtml = `<span class="stat-value muted">No pool initialized</span>`;
    if (deployment.stateView && deployment.poolId) {
      try {
        const slot0 = await publicClient.readContract({
          address: deployment.stateView, abi: STATE_VIEW_ABI, functionName: "getSlot0", args: [deployment.poolId],
        });
        const tick = slot0[1];
        if (slot0[0] > 0n) {
          statusHtml = `<span class="stat-value">Initialized (tick ${tick})</span>`;
        }
      } catch (e) {
        console.warn("[holdfast] getSlot0 failed:", e.shortMessage ?? e.message);
      }
    }
    $("pool-state-body").innerHTML = `
      <div class="stat-row"><span class="stat-label">Hook</span><span class="stat-value">${shorten(deployment.holdfastHook)}</span></div>
      <div class="stat-row"><span class="stat-label">NFT</span><span class="stat-value">${shorten(deployment.holdfastNFT)}</span></div>
      <div class="stat-row"><span class="stat-label">Yield Router</span><span class="stat-value">${shorten(deployment.yieldRouter)}</span></div>
      <div class="stat-row"><span class="stat-label">Block</span><span class="stat-value">${blockNumber.toString()}</span></div>
      <div class="stat-row"><span class="stat-label">Status</span>${statusHtml}</div>
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

function tierProgress(score, blocks, currentTier) {
  if (currentTier >= 3) return { pct: 100, label: "Max tier (Gold)" };
  const next = currentTier === 0 ? TIERS.BRONZE : currentTier === 1 ? TIERS.SILVER : TIERS.GOLD;
  const nextName = currentTier === 0 ? "Bronze" : currentTier === 1 ? "Silver" : "Gold";
  const scorePct = next.score > 0n ? Math.min(100, Number((score * 100n) / next.score)) : 0;
  const blockPct = next.blocks > 0n ? Math.min(100, Number((blocks * 100n) / next.blocks)) : 0;
  const pct = Math.min(scorePct, blockPct);
  return { pct, label: `${pct}% to ${nextName}` };
}

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

const POOL_SWAP_TEST_ABI = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      { name: "key", type: "tuple", components: [
        { name: "currency0", type: "address" },
        { name: "currency1", type: "address" },
        { name: "fee", type: "uint24" },
        { name: "tickSpacing", type: "int24" },
        { name: "hooks", type: "address" },
      ]},
      { name: "params", type: "tuple", components: [
        { name: "zeroForOne", type: "bool" },
        { name: "amountSpecified", type: "int256" },
        { name: "sqrtPriceLimitX96", type: "uint160" },
      ]},
      { name: "testSettings", type: "tuple", components: [
        { name: "takeClaims", type: "bool" },
        { name: "settleUsingBurn", type: "bool" },
      ]},
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
];

const erc20ApproveAbi = [
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "allowance", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
];

const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n; // MAX_SQRT_PRICE - 1
const MIN_SQRT_PRICE_LIMIT = 4295128740n; // MIN_SQRT_PRICE + 1
const MAX_UINT256 = (1n << 256n) - 1n;

// Per-click swap sizing (mirrors the seed). Each click runs two legs so the bonus pool grows
// while the price stays near the center of the range, allowing repeated clicks without
// exhausting liquidity. On Base Sepolia USDC is token1, so only the WETH to USDC leg makes USDC
// the unspecified output currency, which is the case the hook captures into the bonus pool.
const CAPTURE_WETH_IN = parseUnits("0.00005", 18); // 5e13 WETH in, the capturing leg
const REPLENISH_USDC_IN = parseUnits("0.1", 6); // 1e5 USDC in, the replenish leg

function buildPoolKey() {
  const usdc = deployment.usdc.toLowerCase();
  const weth = CURRENT.addresses.weth.toLowerCase();
  const [c0, c1] = usdc < weth ? [deployment.usdc, CURRENT.addresses.weth] : [CURRENT.addresses.weth, deployment.usdc];
  return {
    currency0: c0,
    currency1: c1,
    fee: 3000,
    tickSpacing: 60,
    hooks: deployment.holdfastHook,
  };
}

// Approve `token` to the swap router if the current allowance is below `needed`. Approves the
// uint256 max so the user only ever confirms an approval once per token, not on every click.
async function ensureAllowance(token, spender, needed, label) {
  const allowance = await publicClient.readContract({
    address: token, abi: erc20ApproveAbi, functionName: "allowance", args: [account, spender],
  });
  if (allowance >= needed) return;
  setTxStatus("pending", `approving ${label} for swap router`);
  const hash = await walletClient.writeContract({
    account, address: token, abi: erc20ApproveAbi, functionName: "approve",
    args: [spender, MAX_UINT256],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

// Run one exact-input swap leg. The price limit follows the direction: zeroForOne moves the
// price down (limit MIN_SQRT_PRICE + 1), the other direction moves it up (limit MAX_SQRT_PRICE - 1).
async function doSwapLeg(zeroForOne, amountIn) {
  const key = buildPoolKey();
  const params = {
    zeroForOne,
    amountSpecified: -amountIn,
    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
  };
  const testSettings = { takeClaims: false, settleUsingBurn: false };
  const hash = await walletClient.writeContract({
    account, address: CURRENT.addresses.poolSwapTest, abi: POOL_SWAP_TEST_ABI,
    functionName: "swap", args: [key, params, testSettings, "0x"],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${shorten(hash)}`);
  return hash;
}

async function runSwap() {
  if (!walletClient || !account) {
    setTxStatus("error", "Wallet not connected");
    return;
  }
  const swapRouter = CURRENT.addresses.poolSwapTest;
  const usdc = deployment.usdc;
  const weth = CURRENT.addresses.weth;

  try {
    // Leg 1: WETH -> USDC (capturing leg). USDC is the unspecified output, so the hook captures
    // a fraction of the USDC delta into the bonus pool and supplies it to Aave V3.
    await ensureAllowance(weth, swapRouter, CAPTURE_WETH_IN, "WETH");
    setTxStatus("pending", "swap 1 of 2: WETH to USDC (capture)");
    const h1 = await doSwapLeg(true, CAPTURE_WETH_IN);

    // Leg 2: USDC -> WETH (replenish leg). Pulls the price back toward the center of the range so
    // the action can be repeated without driving the position to a tick boundary.
    await ensureAllowance(usdc, swapRouter, REPLENISH_USDC_IN, "USDC");
    setTxStatus("pending", "swap 2 of 2: USDC to WETH (replenish)");
    const h2 = await doSwapLeg(false, REPLENISH_USDC_IN);

    setTxStatus("success", `capture swaps done (${shorten(h1)}, ${shorten(h2)})`);
    await refreshAll();
  } catch (err) {
    console.error("[holdfast] swap failed:", err);
    setTxStatus("error", err.shortMessage ?? err.message);
  }
}

const swapBtn = document.getElementById("swap-btn");
if (swapBtn) swapBtn.addEventListener("click", runSwap);

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

  const tokenIdStr = CURRENT.addresses.demoTokenId;
  if (!tokenIdStr) {
    $("positions-body").innerHTML = `<p class="muted">No positions configured.</p>`;
    return;
  }
  const tokenId = BigInt(tokenIdStr);

  let streak;
  try {
    streak = await publicClient.readContract({
      address: deployment.holdfastHook, abi: abis.hook, functionName: "getStreak", args: [tokenId],
    });
  } catch (err) {
    $("positions-body").innerHTML = `<p class="muted">Could not load position: ${err.shortMessage ?? err.message}</p>`;
    return;
  }

  const owner = streak.owner ?? streak[0];
  if (!owner || owner === "0x0000000000000000000000000000000000000000") {
    $("positions-body").innerHTML = `<p class="muted">No positions yet. Subscribe a position to Holdfast to start.</p>`;
    return;
  }

  const accumulatedScore = streak.accumulatedScore ?? streak[1] ?? 0n;
  const firstActiveBlock = streak.firstActiveBlock ?? streak[4] ?? 0n;
  const entrySqrtPrice = streak.entrySqrtPriceX96 ?? streak[5] ?? 0n;
  const tier = Number(streak.currentTier ?? streak[6] ?? 0n);
  const isActive = streak.isActive ?? streak[10] ?? false;
  const realizedIL = streak.realizedIL ?? streak[11] ?? 0n;

  const currentBlock = await publicClient.getBlockNumber();
  const blocksActive = firstActiveBlock > 0n ? currentBlock - firstActiveBlock : 0n;
  const progress = tierProgress(accumulatedScore, blocksActive, tier);
  const ilDisplay = realizedIL === 0n
    ? "Not closed"
    : (realizedIL < 0n ? "-" : "") + fmtWad(realizedIL < 0n ? -realizedIL : realizedIL);
  const isOwner = owner.toLowerCase() === userAddress.toLowerCase();
  if (!isOwner) {
    $("positions-body").innerHTML = `<p class="muted">No positions for this wallet. Connect the wallet that owns a Holdfast position.</p>`;
    return;
  }

  $("positions-body").innerHTML = `
    <div class="position-card">
      <div class="position-header">
        <span class="position-id">Position #${tokenId.toString()}</span>
        <span class="tier-badge ${TIER_CLASS[tier]}">${TIER_NAMES[tier]}</span>
      </div>
      <div class="position-stats">
        <div><div class="position-stat-label">Accumulated Score</div><div class="position-stat-value">${fmtWad(accumulatedScore)}</div></div>
        <div><div class="position-stat-label">Blocks Active</div><div class="position-stat-value">${blocksActive.toString()}</div></div>
        <div><div class="position-stat-label">Entry sqrtPrice</div><div class="position-stat-value">${shorten(entrySqrtPrice.toString())}</div></div>
        <div><div class="position-stat-label">Realized IL</div><div class="position-stat-value">${ilDisplay}</div></div>
      </div>
      <div class="progress-block">
        <div class="progress-label"><span>Tier progress</span><span>${progress.label}</span></div>
        <div class="progress-bar"><div class="progress-fill" style="width: ${progress.pct}%"></div></div>
      </div>
      <button class="claim-btn" data-token-id="${tokenId.toString()}" ${isActive && isOwner ? "" : "disabled"}>Claim Rewards</button>
    </div>
  `;
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
  if (!ok) return;
  await refreshAll();
})();
