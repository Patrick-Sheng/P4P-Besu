// Server-only helpers for the QR-code demo (app/api/*). Holds the admin key,
// talks to the Besu validators over their localhost RPC ports, and serialises
// every admin transaction so concurrent phone registrations never race on the
// admin nonce. Configured entirely from env vars set by demo/start-demo.sh.
import { ethers } from "ethers";
import { VOTING_ABI } from "@/lib/abi";
import { TX_OVERRIDES } from "@/lib/blockchain";

export const CHAIN_ID = Number(process.env.DEMO_CHAIN_ID ?? 1337);

export const config = {
  rpcUrls: (process.env.BESU_RPC_URLS ?? "http://127.0.0.1:8545")
    .split(",")
    .map((u) => u.trim())
    .filter(Boolean),
  contractAddress: process.env.DEMO_CONTRACT_ADDRESS ?? "",
  deployBlock: Number(process.env.DEMO_DEPLOY_BLOCK ?? 0),
  adminKey: process.env.DEMO_ADMIN_PRIVATE_KEY ?? "",
  adminToken: process.env.DEMO_ADMIN_TOKEN ?? "",
  joinCode: process.env.DEMO_JOIN_CODE ?? "",
  publicUrl: (process.env.DEMO_PUBLIC_URL ?? "").replace(/\/$/, ""),
  candidateNames: (process.env.DEMO_CANDIDATES ?? "Party A,Party B,Party C")
    .split(",")
    .map((c) => c.trim())
    .filter(Boolean),
  maxVoters: Number(process.env.DEMO_MAX_VOTERS ?? 500),
};

// Route handlers are bundled separately, so module-level state could be
// duplicated per route; keep the singletons on globalThis instead.
interface DemoGlobals {
  rr: number;
  adminQueue: Promise<unknown>;
  adminNonce: number | null;
  providers: Map<string, ethers.JsonRpcProvider>;
}
const g = globalThis as typeof globalThis & { __p4pDemo?: DemoGlobals };
const state: DemoGlobals = (g.__p4pDemo ??= {
  rr: 0,
  adminQueue: Promise.resolve(),
  adminNonce: null,
  providers: new Map(),
});

function providerFor(url: string): ethers.JsonRpcProvider {
  let p = state.providers.get(url);
  if (!p) {
    const network = ethers.Network.from(CHAIN_ID);
    p = new ethers.JsonRpcProvider(url, network, { staticNetwork: network });
    state.providers.set(url, p);
  }
  return p;
}

/** Validator RPC URLs in round-robin order, so load spreads across nodes and
 *  a crashed validator is skipped by the caller's failover loop. */
export function rpcOrder(): string[] {
  const urls = config.rpcUrls;
  const start = state.rr++ % urls.length;
  return [...urls.slice(start), ...urls.slice(0, start)];
}

/** Forward one raw JSON-RPC body to the first validator that answers. */
export async function forwardRpc(body: unknown): Promise<unknown> {
  let lastErr: unknown;
  for (const url of rpcOrder()) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(8000),
      });
      return await res.json();
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr ?? new Error("No Besu node reachable");
}

/** Read-only contract bound to a healthy validator. */
export async function readContract(): Promise<{
  contract: ethers.Contract;
  provider: ethers.JsonRpcProvider;
}> {
  let lastErr: unknown;
  for (const url of rpcOrder()) {
    const provider = providerFor(url);
    try {
      await provider.getBlockNumber();
      return {
        contract: new ethers.Contract(config.contractAddress, VOTING_ABI, provider),
        provider,
      };
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr ?? new Error("No Besu node reachable");
}

/**
 * Send one admin transaction. Calls are queued so nonces are assigned strictly
 * in order; the queue is released as soon as the tx is in the pool, so a burst
 * of registrations lands in the next one or two IBFT blocks rather than one per
 * block. Resolves once the tx is mined.
 */
export async function sendAdminTx(
  method: "registerVoter" | "openVoting" | "closeVoting",
  args: unknown[] = []
): Promise<ethers.TransactionReceipt> {
  if (!config.adminKey) throw new Error("DEMO_ADMIN_PRIVATE_KEY not set");

  const sent = state.adminQueue.then(async () => {
    const { provider } = await readContract();
    const wallet = new ethers.Wallet(config.adminKey, provider);
    const contract = new ethers.Contract(config.contractAddress, VOTING_ABI, wallet);
    if (state.adminNonce === null) {
      state.adminNonce = await provider.getTransactionCount(wallet.address, "pending");
    }
    try {
      const tx = (await contract[method](...args, {
        ...TX_OVERRIDES,
        nonce: state.adminNonce,
        gasLimit: 200_000,
      })) as ethers.ContractTransactionResponse;
      state.adminNonce++;
      return tx;
    } catch (err) {
      state.adminNonce = null; // resync from the chain on the next call
      throw err;
    }
  });
  // keep the queue alive even if this send failed
  state.adminQueue = sent.catch(() => undefined);

  const tx = await sent;
  const receipt = await tx.wait(1, 30_000);
  if (!receipt || receipt.status !== 1) throw new Error(`${method} reverted`);
  return receipt;
}

export function isAdmin(req: Request): boolean {
  const token =
    req.headers.get("x-admin-token") ?? new URL(req.url).searchParams.get("admin");
  return Boolean(config.adminToken) && token === config.adminToken;
}

export function joinUrl(): string {
  return `${config.publicUrl}/vote?code=${encodeURIComponent(config.joinCode)}`;
}
