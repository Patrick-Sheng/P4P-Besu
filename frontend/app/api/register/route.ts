// Auto-registration for QR-code joiners. The phone generates its own keypair
// and sends only the address plus the join code from the QR; the server (as
// contract admin) calls registerVoter() on-chain. The private key never leaves
// the phone.
import { ethers } from "ethers";
import { config, readContract, sendAdminTx } from "@/lib/server/chain";
import { parseError } from "@/lib/blockchain";

export const dynamic = "force-dynamic";

const g = globalThis as typeof globalThis & { __p4pRegistered?: Set<string> };
const registeredHere = (g.__p4pRegistered ??= new Set<string>());

export async function POST(request: Request) {
  let address: string, code: string;
  try {
    ({ address, code } = await request.json());
  } catch {
    return Response.json({ error: "Bad request" }, { status: 400 });
  }
  if (!config.joinCode || code !== config.joinCode)
    return Response.json({ error: "Invalid or expired join code — scan the QR code again" }, { status: 403 });
  if (!ethers.isAddress(address)) return Response.json({ error: "Invalid address" }, { status: 400 });

  const addr = ethers.getAddress(address);
  try {
    const { contract } = await readContract();
    if (await contract.registeredVoters(addr)) return Response.json({ registered: true, address: addr });

    if (registeredHere.size >= config.maxVoters)
      return Response.json({ error: "This demo has reached its voter limit" }, { status: 429 });
    registeredHere.add(addr.toLowerCase());

    const receipt = await sendAdminTx("registerVoter", [addr]);
    return Response.json({ registered: true, address: addr, txHash: receipt.hash, blockNumber: receipt.blockNumber });
  } catch (err) {
    const msg = parseError(err);
    if (msg === "Voter already registered") return Response.json({ registered: true, address: addr });
    registeredHere.delete(addr.toLowerCase());
    return Response.json({ error: msg }, { status: 502 });
  }
}
