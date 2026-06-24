import { ethers } from "ethers";
import type { Overrides } from "ethers";
import { VOTING_ABI } from "./abi";

export const TX_OVERRIDES: Overrides = { gasPrice: BigInt(0), type: 0 };

export function createProvider(rpcUrl: string): ethers.JsonRpcProvider {
  return new ethers.JsonRpcProvider(rpcUrl);
}

export function createReadContract(
  contractAddress: string,
  provider: ethers.Provider
): ethers.Contract {
  return new ethers.Contract(contractAddress, VOTING_ABI, provider);
}

export function createSignerContract(
  contractAddress: string,
  privateKey: string,
  provider: ethers.Provider
): { contract: ethers.Contract; wallet: ethers.Wallet } {
  const wallet = new ethers.Wallet(privateKey, provider);
  const contract = new ethers.Contract(contractAddress, VOTING_ABI, wallet);
  return { contract, wallet };
}

export function parseError(error: unknown): string {
  if (error instanceof Error) {
    const msg = error.message;

    if (msg.includes("Already voted")) return "Already voted";
    if (msg.includes("Not registered")) return "Voter is not registered";
    if (msg.includes("Voting not open")) return "Voting is not currently open";
    if (msg.includes("Only admin") || msg.includes("not admin"))
      return "Admin access required";
    if (
      msg.includes("Voter already registered") ||
      msg.includes("already registered")
    )
      return "Voter already registered";
    if (msg.includes("ECONNREFUSED") || msg.includes("could not detect network"))
      return "Cannot connect to node. Is the Besu network running?";
    if (msg.includes("invalid private key") || msg.includes("invalid arrayify"))
      return "Invalid private key format";

    const revertQuoted = msg.match(
      /reverted(?:\s+with\s+reason\s+string\s*)?["']([^"']+)["']/i
    );
    if (revertQuoted) return revertQuoted[1];

    const execRevert = msg.match(/execution reverted[: ]*["']?([^"'\n]+)["']?/i);
    if (execRevert) return execRevert[1].trim();

    return msg.split("\n")[0].slice(0, 200);
  }
  return "Unknown error occurred";
}
