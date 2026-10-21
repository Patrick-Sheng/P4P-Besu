// Public election status for phones: open/closed, candidates, live tally and
// (with ?address=) that voter's registration and vote state, in one request.
import { ethers } from "ethers";
import { config, readContract } from "@/lib/server/chain";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const address = new URL(request.url).searchParams.get("address");
  try {
    const { contract, provider } = await readContract();
    const [blockNumber, votingOpen, nCands] = await Promise.all([
      provider.getBlockNumber(),
      contract.votingOpen() as Promise<boolean>,
      contract.numCandidates() as Promise<bigint>,
    ]);
    const n = Number(nCands);
    const tally = (
      await Promise.all(Array.from({ length: n }, (_, i) => contract.getTally(i) as Promise<bigint>))
    ).map(Number);

    let voter: { registered: boolean; state: number } | null = null;
    if (address && ethers.isAddress(address)) {
      const [registered, voterState] = await Promise.all([
        contract.registeredVoters(address) as Promise<boolean>,
        contract.getVoterState(address) as Promise<bigint>,
      ]);
      voter = { registered, state: Number(voterState) };
    }

    return Response.json({
      contractAddress: config.contractAddress,
      blockNumber,
      votingOpen,
      candidates: Array.from({ length: n }, (_, i) => config.candidateNames[i] ?? `Candidate ${i + 1}`),
      tally,
      voter,
    });
  } catch {
    return Response.json({ error: "Besu network unreachable" }, { status: 502 });
  }
}
