"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { ethers } from "ethers";
import Link from "next/link";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from "recharts";

import { VOTING_ABI } from "@/lib/abi";
import { TX_OVERRIDES, parseError } from "@/lib/blockchain";
import {
  DEFAULT_RPC_URL,
  DEFAULT_CONTRACT_ADDRESS,
  RPC_NODES,
  CANDIDATE_NAMES,
  VOTER_STATE_LABELS,
  VOTER_STATE_VARIANT,
  type VotingConfig,
  type VoteReceipt,
} from "@/lib/types";

import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Alert, AlertDescription } from "@/components/ui/alert";

const STORAGE_KEY = "votingVoterConfig";
const TALLY_COLORS = ["#3b82f6", "#ef4444", "#22c55e", "#f59e0b", "#8b5cf6"];

export default function VoterPage() {
  // Config
  const [rpcUrl, setRpcUrl] = useState(DEFAULT_RPC_URL);
  const [contractAddress, setContractAddress] = useState(
    DEFAULT_CONTRACT_ADDRESS
  );

  // Wallet
  const [privateKey, setPrivateKey] = useState("");
  const [address, setAddress] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [connectionCounter, setConnectionCounter] = useState(0);

  // Voter status
  const [registered, setRegistered] = useState(false);
  const [voterState, setVoterState] = useState(0);
  const [votingOpen, setVotingOpen] = useState(false);

  // Voting
  const [selectedCandidate, setSelectedCandidate] = useState<number | null>(
    null
  );
  const [txPending, setTxPending] = useState(false);
  const [receipt, setReceipt] = useState<VoteReceipt | null>(null);

  // Chain data
  const [blockNumber, setBlockNumber] = useState(0);
  const [numCandidates, setNumCandidates] = useState(0);
  const [tally, setTally] = useState<number[]>([]);

  // UI
  const [error, setError] = useState<string | null>(null);
  const [txStatus, setTxStatus] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);

  // Refs
  const rpcUrlRef = useRef(rpcUrl);
  const contractAddrRef = useRef(contractAddress);
  const addressRef = useRef(address);
  const connectedRef = useRef(connected);

  useEffect(() => {
    rpcUrlRef.current = rpcUrl;
  }, [rpcUrl]);
  useEffect(() => {
    contractAddrRef.current = contractAddress;
  }, [contractAddress]);
  useEffect(() => {
    addressRef.current = address;
  }, [address]);
  useEffect(() => {
    connectedRef.current = connected;
  }, [connected]);
  useEffect(() => {
    setMounted(true);
  }, []);

  // Load/save config
  useEffect(() => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored) {
        const config: VotingConfig = JSON.parse(stored);
        if (config.rpcUrl) setRpcUrl(config.rpcUrl);
        if (config.contractAddress) setContractAddress(config.contractAddress);
      }
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ rpcUrl, contractAddress })
    );
  }, [rpcUrl, contractAddress]);

  // ─── Connect wallet ───────────────────────────────────────────────────────────

  const connectWallet = async () => {
    setError(null);
    setConnecting(true);

    try {
      const wallet = new ethers.Wallet(privateKey);
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const contract = new ethers.Contract(contractAddress, VOTING_ABI, provider);

      const [isRegistered, stateNum, isOpen, nCands] = await Promise.all([
        contract.registeredVoters(wallet.address),
        contract.getVoterState(wallet.address),
        contract.votingOpen(),
        contract.numCandidates(),
      ]);

      const nc = Number(nCands);
      const tallyResults =
        nc > 0
          ? await Promise.all(
              Array.from({ length: nc }, (_, i) => contract.getTally(i))
            )
          : [];

      setAddress(wallet.address);
      setRegistered(Boolean(isRegistered));
      setVoterState(Number(stateNum));
      setVotingOpen(Boolean(isOpen));
      setNumCandidates(nc);
      setTally(tallyResults.map((t) => Number(t)));
      setConnected(true);
      setConnectionCounter((c) => c + 1);
    } catch (err) {
      setError(parseError(err));
    } finally {
      setConnecting(false);
    }
  };

  // ─── Polling ──────────────────────────────────────────────────────────────────

  const poll = useCallback(async () => {
    if (!connectedRef.current || !addressRef.current) return;

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrlRef.current);
      const contract = new ethers.Contract(
        contractAddrRef.current,
        VOTING_ABI,
        provider
      );

      const [newBlockNum, stateNum, isOpen, nCands] = await Promise.all([
        provider.getBlockNumber(),
        contract.getVoterState(addressRef.current),
        contract.votingOpen(),
        contract.numCandidates(),
      ]);

      const nc = Number(nCands);
      const tallyResults =
        nc > 0
          ? await Promise.all(
              Array.from({ length: nc }, (_, i) => contract.getTally(i))
            )
          : [];

      setBlockNumber(newBlockNum as number);
      setVoterState(Number(stateNum));
      setVotingOpen(Boolean(isOpen));
      setNumCandidates(nc);
      setTally(tallyResults.map((t) => Number(t)));
    } catch {
      /* silent — connection issues shown on connect */
    }
  }, []);

  useEffect(() => {
    if (!connected) return;
    void poll();
    const interval = setInterval(() => void poll(), 2000);
    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [connected, connectionCounter, poll]);

  // ─── Cast vote ────────────────────────────────────────────────────────────────

  const castVote = async () => {
    if (selectedCandidate === null || !address) return;
    setError(null);
    setTxPending(true);
    setTxStatus("Submitting vote transaction to Besu node…");

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey, provider);
      const contract = new ethers.Contract(contractAddress, VOTING_ABI, wallet);

      const tx = await contract.castVote(
        selectedCandidate,
        TX_OVERRIDES
      ) as ethers.ContractTransactionResponse;
      setTxStatus(
        `Transaction ${tx.hash.slice(0, 12)}… submitted. Waiting for IBFT block seal (≤2s)…`
      );

      const txReceipt = await tx.wait();
      const block = await provider.getBlock(txReceipt?.blockNumber ?? 0);

      setReceipt({
        txHash: tx.hash,
        blockNumber: txReceipt?.blockNumber ?? 0,
        timestamp: (block?.timestamp ?? 0) * 1000,
        candidateId: selectedCandidate,
      });
      setTxStatus(null);
    } catch (err) {
      setError(parseError(err));
      setTxStatus(null);
    } finally {
      setTxPending(false);
    }
  };

  // ─── Derived ─────────────────────────────────────────────────────────────────

  const tallyChartData = tally.map((count, i) => ({
    name: CANDIDATE_NAMES[i] ?? `Candidate ${i}`,
    votes: count,
  }));

  const canVote =
    connected && registered && voterState === 0 && votingOpen && !receipt;

  // ─── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="border-b border-border bg-card">
        <div className="max-w-3xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Link href="/" className="text-muted-foreground hover:text-foreground text-sm">← Home</Link>
            <div>
              <h1 className="text-base font-semibold leading-tight">
                NZ Electronic Voting
              </h1>
              <p className="text-xs text-muted-foreground">
                Hyperledger Besu IBFT 2.0 · Immediate finality
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {blockNumber > 0 && (
              <Badge variant="outline" className="font-mono text-xs">
                Block #{blockNumber.toLocaleString()}
              </Badge>
            )}
            <Badge
              className={
                votingOpen
                  ? "bg-blue-100 text-blue-800"
                  : "bg-muted text-muted-foreground"
              }
            >
              {votingOpen ? "Voting Open" : "Voting Closed"}
            </Badge>
          </div>
        </div>
      </header>

      <main className="max-w-3xl mx-auto px-4 py-6 space-y-5">
        {/* ── Config ── */}
        <Card>
          <CardHeader>
            <CardTitle>Network Configuration</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div className="space-y-1">
                <label className="text-sm font-medium">RPC Node</label>
                <select
                  value={rpcUrl}
                  onChange={(e) => setRpcUrl(e.target.value)}
                  className="w-full h-8 rounded-lg border border-input bg-background px-2.5 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring"
                >
                  {RPC_NODES.map((n) => (
                    <option key={n.url} value={n.url}>
                      {n.label}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-sm font-medium">Contract Address</label>
                <Input
                  value={contractAddress}
                  onChange={(e) => setContractAddress(e.target.value)}
                  placeholder="0x…"
                  className="font-mono text-xs"
                />
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              Switch between nodes to verify all four validators hold identical chain state.
            </p>
          </CardContent>
        </Card>

        {/* ── Connect wallet ── */}
        {!connected && (
          <Card>
            <CardHeader>
              <CardTitle>Connect Your Wallet</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-1.5">
                <label className="text-sm font-medium">Your Private Key</label>
                <Input
                  type="password"
                  value={privateKey}
                  onChange={(e) => setPrivateKey(e.target.value)}
                  placeholder="0x… (your voter keypair)"
                  className="font-mono text-xs"
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && privateKey && !connecting)
                      void connectWallet();
                  }}
                />
                <p className="text-xs text-muted-foreground">
                  Your key is used only in this browser to sign the transaction.
                  It is never sent to any server.
                </p>
              </div>
              <Button
                onClick={() => void connectWallet()}
                disabled={!privateKey || connecting}
              >
                {connecting ? "Connecting…" : "Connect"}
              </Button>
            </CardContent>
          </Card>
        )}

        {/* ── Errors ── */}
        {error && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}

        {/* ── Tx status ── */}
        {txStatus && (
          <div className="flex items-center gap-2.5 text-sm text-muted-foreground">
            <span className="relative flex h-2 w-2 shrink-0">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-primary opacity-75" />
              <span className="relative inline-flex rounded-full h-2 w-2 bg-primary" />
            </span>
            {txStatus}
          </div>
        )}

        {/* ── Voter Status ── */}
        {connected && address && (
          <Card>
            <CardHeader>
              <CardTitle>Your Voter Status</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="flex items-start justify-between gap-4">
                <span className="text-sm text-muted-foreground shrink-0">
                  Address
                </span>
                <span className="font-mono text-xs break-all text-right">
                  {address}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-muted-foreground">
                  Registration
                </span>
                <span
                  className={`text-xs px-2.5 py-1 rounded-full font-medium ${
                    registered
                      ? "bg-green-100 text-green-800"
                      : "bg-red-100 text-red-800"
                  }`}
                >
                  {registered ? "Registered" : "Not Registered"}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-muted-foreground">
                  Vote Status
                </span>
                <span
                  className={`text-xs px-2.5 py-1 rounded-full font-medium ${VOTER_STATE_VARIANT[voterState] ?? "bg-muted text-muted-foreground"}`}
                >
                  {VOTER_STATE_LABELS[voterState] ?? "Unknown"}
                </span>
              </div>

              {!registered && (
                <Alert>
                  <AlertDescription>
                    Your address is not registered on the contract. Contact the
                    Electoral Commission to register before voting opens.
                  </AlertDescription>
                </Alert>
              )}
              {!votingOpen && registered && (
                <Alert>
                  <AlertDescription>
                    {voterState === 2
                      ? "Your vote has been recorded. Results visible in the tally below."
                      : "Voting is not currently open. Wait for the Electoral Commission to open voting."}
                  </AlertDescription>
                </Alert>
              )}
            </CardContent>
          </Card>
        )}

        {/* ── Cast Vote ── */}
        {canVote && (
          <Card>
            <CardHeader>
              <CardTitle>Cast Your Vote</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <p className="text-sm text-muted-foreground">
                Select a candidate and submit. Your vote is signed with your
                private key and permanently recorded on-chain. This action is
                irreversible.
              </p>

              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                {Array.from({ length: numCandidates }, (_, i) => (
                  <button
                    key={i}
                    onClick={() => setSelectedCandidate(i)}
                    disabled={txPending}
                    className={`p-4 rounded-xl border-2 text-left transition-all ${
                      selectedCandidate === i
                        ? "border-foreground bg-foreground/5 shadow-sm"
                        : "border-border hover:border-foreground/40"
                    } disabled:opacity-50 disabled:pointer-events-none`}
                  >
                    <div className="text-xs text-muted-foreground mb-1">
                      Candidate {i}
                    </div>
                    <div className="font-semibold text-sm">
                      {CANDIDATE_NAMES[i] ?? `Candidate ${i}`}
                    </div>
                    {selectedCandidate === i && (
                      <div className="mt-2 text-xs text-foreground/70">
                        ✓ Selected
                      </div>
                    )}
                  </button>
                ))}
              </div>

              <Button
                onClick={() => void castVote()}
                disabled={selectedCandidate === null || txPending}
                className="w-full"
              >
                {txPending
                  ? "Waiting for IBFT block seal…"
                  : selectedCandidate !== null
                    ? `Submit Vote for ${CANDIDATE_NAMES[selectedCandidate] ?? `Candidate ${selectedCandidate}`}`
                    : "Select a candidate to vote"}
              </Button>
            </CardContent>
          </Card>
        )}

        {/* ── Vote Receipt ── */}
        {receipt && (
          <Card className="border-green-300 bg-green-50/30">
            <CardHeader>
              <CardTitle className="text-green-800 flex items-center gap-2">
                <span>✓</span> Vote Confirmed On-Chain
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <p className="text-sm text-green-700">
                Your vote for{" "}
                <strong>
                  {CANDIDATE_NAMES[receipt.candidateId] ??
                    `Candidate ${receipt.candidateId}`}
                </strong>{" "}
                has been permanently recorded on the Besu blockchain via IBFT
                2.0 consensus.
              </p>

              <div className="rounded-lg border border-green-200 bg-white/60 divide-y divide-green-100">
                {[
                  {
                    label: "Transaction Hash",
                    value: receipt.txHash,
                    mono: true,
                  },
                  {
                    label: "Block Number",
                    value: receipt.blockNumber.toLocaleString(),
                    mono: false,
                  },
                  {
                    label: "Block Timestamp",
                    value:
                      receipt.timestamp > 0
                        ? new Date(receipt.timestamp).toLocaleString()
                        : "—",
                    mono: false,
                  },
                  {
                    label: "Candidate",
                    value:
                      CANDIDATE_NAMES[receipt.candidateId] ??
                      `Candidate ${receipt.candidateId}`,
                    mono: false,
                  },
                ].map((item) => (
                  <div
                    key={item.label}
                    className="flex items-start justify-between gap-4 px-4 py-2.5 text-sm"
                  >
                    <span className="text-muted-foreground shrink-0">
                      {item.label}
                    </span>
                    <span
                      className={`${item.mono ? "font-mono text-xs break-all" : "font-medium"} text-right`}
                    >
                      {item.value}
                    </span>
                  </div>
                ))}
              </div>

              <p className="text-xs text-muted-foreground">
                This receipt is verifiable on any of the four Besu validator nodes
                by calling{" "}
                <code className="font-mono">
                  getVoterState({address?.slice(0, 8)}…)
                </code>{" "}
                — it will return <code className="font-mono">2</code> (Voted).
              </p>
            </CardContent>
          </Card>
        )}

        {/* ── Live Tally ── */}
        {connected && tally.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle>
                Live Vote Tally{" "}
                {blockNumber > 0 && (
                  <span className="text-muted-foreground text-sm font-normal ml-1">
                    · Block #{blockNumber.toLocaleString()}
                  </span>
                )}
              </CardTitle>
            </CardHeader>
            <CardContent>
              {mounted ? (
                <>
                  <ResponsiveContainer width="100%" height={220}>
                    <BarChart data={tallyChartData}>
                      <CartesianGrid
                        strokeDasharray="3 3"
                        stroke="var(--border)"
                      />
                      <XAxis dataKey="name" tick={{ fontSize: 12 }} />
                      <YAxis tick={{ fontSize: 12 }} allowDecimals={false} />
                      <Tooltip />
                      <Bar dataKey="votes" name="Votes">
                        {tallyChartData.map((_, i) => (
                          <Cell
                            key={i}
                            fill={TALLY_COLORS[i % TALLY_COLORS.length]}
                          />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>

                  <div className="flex gap-6 justify-center mt-4">
                    {tallyChartData.map((d, i) => (
                      <div key={i} className="text-center">
                        <div
                          className="text-2xl font-bold"
                          style={{ color: TALLY_COLORS[i % TALLY_COLORS.length] }}
                        >
                          {d.votes}
                        </div>
                        <div className="text-xs text-muted-foreground mt-0.5">
                          {d.name}
                        </div>
                      </div>
                    ))}
                  </div>
                  <p className="text-xs text-center text-muted-foreground mt-3">
                    Results update every 2 seconds. No trusted third party —
                    readable from any validator node via{" "}
                    <code className="font-mono">getTally(candidateId)</code>.
                  </p>
                </>
              ) : (
                <div className="h-48 flex items-center justify-center text-sm text-muted-foreground">
                  Loading chart…
                </div>
              )}
            </CardContent>
          </Card>
        )}

        {/* ── Reconnect option ── */}
        {connected && (
          <div className="text-center">
            <button
              onClick={() => {
                setConnected(false);
                setAddress(null);
                setReceipt(null);
                setSelectedCandidate(null);
                setError(null);
              }}
              className="text-xs text-muted-foreground hover:text-foreground transition-colors underline underline-offset-2"
            >
              Disconnect / use a different key
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
