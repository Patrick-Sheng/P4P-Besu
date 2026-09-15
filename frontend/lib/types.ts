export const DEFAULT_RPC_URL = "http://127.0.0.1:8545";
export const DEFAULT_CONTRACT_ADDRESS = "0x6227c4d25cd67543c8fd0cda1f87d022ad902334";

export const RPC_NODES = [
  { label: "Node 1 (Bootnode) — :8545", url: "http://127.0.0.1:8545" },
  { label: "Node 2 — :8546", url: "http://127.0.0.1:8546" },
  { label: "Node 3 — :8547", url: "http://127.0.0.1:8547" },
  { label: "Node 4 — :8548", url: "http://127.0.0.1:8548" },
];

export const CANDIDATE_NAMES = ["Party A", "Party B", "Party C"];

export const VOTER_STATE_LABELS: Record<number, string> = {
  0: "Not Voted",
  1: "Processing",
  2: "Voted",
};

export const VOTER_STATE_VARIANT: Record<number, string> = {
  0: "bg-blue-100 text-blue-800",
  1: "bg-yellow-100 text-yellow-800",
  2: "bg-green-100 text-green-800",
};

export interface VotingConfig {
  rpcUrl: string;
  contractAddress: string;
}

export interface BlockStat {
  blockNumber: number;
  txCount: number;
  timestamp: number;
}

export interface LatencyRecord {
  label: string;
  latencyMs: number;
  blockNumber: number;
}

export interface VoterRecord {
  address: string;
  state: number;
}

export interface VoteReceipt {
  txHash: string;
  blockNumber: number;
  timestamp: number;
  candidateId: number;
}
