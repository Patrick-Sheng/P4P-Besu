// JSON-RPC proxy for phones. The Besu nodes only listen on localhost, so the
// phone's ethers provider talks to this route instead. Only the read methods a
// voter needs are forwarded, and eth_sendRawTransaction is accepted only for a
// castVote() call on the demo contract — the phone still signs its own vote.
import { ethers } from "ethers";
import { VOTING_ABI } from "@/lib/abi";
import { config, forwardRpc } from "@/lib/server/chain";

export const dynamic = "force-dynamic";

const ALLOWED = new Set([
  "eth_chainId",
  "net_version",
  "eth_blockNumber",
  "eth_call",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_getTransactionCount",
  "eth_getTransactionReceipt",
  "eth_getTransactionByHash",
  "eth_getBlockByNumber",
  "eth_sendRawTransaction",
]);

const iface = new ethers.Interface(VOTING_ABI);
const castVoteSelector = iface.getFunction("castVote")!.selector;

interface RpcRequest {
  jsonrpc: string;
  id: number | string | null;
  method: string;
  params?: unknown[];
}

function rejection(req: RpcRequest): string | null {
  if (!ALLOWED.has(req.method)) return `Method ${req.method} not allowed`;
  if (req.method !== "eth_sendRawTransaction") return null;
  try {
    const tx = ethers.Transaction.from(String(req.params?.[0]));
    if (tx.to?.toLowerCase() !== config.contractAddress.toLowerCase())
      return "Only transactions to the voting contract are accepted";
    if (!tx.data.startsWith(castVoteSelector)) return "Only castVote() is accepted";
  } catch {
    return "Malformed transaction";
  }
  return null;
}

async function handleOne(req: RpcRequest): Promise<unknown> {
  const reason = rejection(req);
  if (reason) return { jsonrpc: "2.0", id: req.id ?? null, error: { code: -32601, message: reason } };
  return forwardRpc(req);
}

export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
  }
  try {
    if (Array.isArray(body)) {
      if (body.length > 20) return Response.json({ error: "Batch too large" }, { status: 400 });
      return Response.json(await Promise.all((body as RpcRequest[]).map(handleOne)));
    }
    return Response.json(await handleOne(body as RpcRequest));
  } catch {
    return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32603, message: "Besu network unreachable" } }, { status: 502 });
  }
}
