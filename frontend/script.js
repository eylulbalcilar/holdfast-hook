import { createPublicClient, http } from "https://esm.sh/viem@2.x";
import { CURRENT } from "./config.js";

console.log("[holdfast] script loaded");
console.log("[holdfast] target network:", CURRENT.network.name, "chainId:", CURRENT.network.chainId);

// Public client for read-only calls. Wallet client wired in Step 3.
const publicClient = createPublicClient({
  transport: http(CURRENT.network.rpcUrl),
});

// Smoke test: fetch latest block number from configured RPC.
publicClient.getBlockNumber()
  .then((bn) => console.log("[holdfast] connected to RPC, block:", bn))
  .catch((err) => console.error("[holdfast] RPC connection failed:", err.message));

// Placeholder handlers, filled in next steps.
document.getElementById("connect-btn").addEventListener("click", () => {
  console.log("[holdfast] connect clicked, wallet logic in Step 3");
});
