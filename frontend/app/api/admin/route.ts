// Presenter-only endpoints for the projector page (app/demo). Both require the
// DEMO_ADMIN_TOKEN that demo/start-demo.sh prints in the projector URL.
//   GET  -> join URL for the QR code, registered-voter count, validator info
//   POST {action: "open" | "close"} -> openVoting() / closeVoting()
import { config, isAdmin, joinUrl, readContract, sendAdminTx } from "@/lib/server/chain";
import { parseError } from "@/lib/blockchain";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (!isAdmin(request)) return Response.json({ error: "Unauthorized" }, { status: 401 });
  try {
    const { contract, provider } = await readContract();
    const [registered, validators] = await Promise.all([
      contract.queryFilter(contract.filters.VoterRegistered(), config.deployBlock),
      provider.send("ibft_getValidatorsByBlockNumber", ["latest"]).catch(() => []) as Promise<string[]>,
    ]);
    return Response.json({
      joinUrl: joinUrl(),
      publicUrl: config.publicUrl,
      contractAddress: config.contractAddress,
      registeredCount: registered.length,
      validatorCount: validators.length,
      nodeCount: config.rpcUrls.length,
    });
  } catch {
    return Response.json({ error: "Besu network unreachable" }, { status: 502 });
  }
}

export async function POST(request: Request) {
  if (!isAdmin(request)) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const { action } = (await request.json().catch(() => ({}))) as { action?: string };
  if (action !== "open" && action !== "close") return Response.json({ error: "Unknown action" }, { status: 400 });
  try {
    const receipt = await sendAdminTx(action === "open" ? "openVoting" : "closeVoting");
    return Response.json({ ok: true, txHash: receipt.hash, blockNumber: receipt.blockNumber });
  } catch (err) {
    return Response.json({ error: parseError(err) }, { status: 502 });
  }
}
