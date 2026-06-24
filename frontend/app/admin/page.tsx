"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { ethers } from "ethers";
import type { EventLog } from "ethers";
import Link from "next/link";
import {
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
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
  type BlockStat,
  type LatencyRecord,
  type VoterRecord,
} from "@/lib/types";

import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";

const STORAGE_KEY = "votingAdminConfig";

export default function AdminPage() {
  // Config
  const [rpcUrl, setRpcUrl] = useState(DEFAULT_RPC_URL);
  const [contractAddress, setContractAddress] = useState(
    DEFAULT_CONTRACT_ADDRESS
  );
  const [privateKey, setPrivateKey] = useState("");

  // Connection
  const [connected, setConnected] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [adminAddress, setAdminAddress] = useState("");
  const [chainId, setChainId] = useState(0);
  const [connectionCounter, setConnectionCounter] = useState(0);

  // Status messages
  const [error, setError] = useState<string | null>(null);
  const [txStatus, setTxStatus] = useState<string | null>(null);
  const [pollError, setPollError] = useState<string | null>(null);

  // Chain stats
  const [blockNumber, setBlockNumber] = useState(0);
  const [peerCount, setPeerCount] = useState(0);
  const [validators, setValidators] = useState<string[]>([]);
  const [latestBlockTxCount, setLatestBlockTxCount] = useState(0);

  // Contract state
  const [votingOpen, setVotingOpen] = useState(false);
  const [numCandidates, setNumCandidates] = useState(0);
  const [voters, setVoters] = useState<VoterRecord[]>([]);
  const [tally, setTally] = useState<number[]>([]);

  // Benchmark
  const [blockHistory, setBlockHistory] = useState<BlockStat[]>([]);
  const [latencyHistory, setLatencyHistory] = useState<LatencyRecord[]>([]);

  // UI state
  const [registerInput, setRegisterInput] = useState("");
  const [registerStatus, setRegisterStatus] = useState<string | null>(null);
  const [registerError, setRegisterError] = useState<string | null>(null);
  const [txLoading, setTxLoading] = useState(false);
  const [mounted, setMounted] = useState(false);

  // Refs to avoid stale closures in polling
  const rpcUrlRef = useRef(rpcUrl);
  const contractAddrRef = useRef(contractAddress);
  const connectedRef = useRef(connected);
  const lastBlockRef = useRef(0);

  useEffect(() => {
    rpcUrlRef.current = rpcUrl;
  }, [rpcUrl]);
  useEffect(() => {
    contractAddrRef.current = contractAddress;
  }, [contractAddress]);
  useEffect(() => {
    connectedRef.current = connected;
  }, [connected]);
  useEffect(() => {
    setMounted(true);
  }, []);

  // Load config from localStorage
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

  // Save config to localStorage
  useEffect(() => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ rpcUrl, contractAddress })
    );
  }, [rpcUrl, contractAddress]);

  // ─── Connect ────────────────────────────────────────────────────────────────

  const connect = async () => {
    setError(null);
    setConnecting(true);
    setTxStatus("Connecting to Besu node...");

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const network = await provider.getNetwork();
      const wallet = new ethers.Wallet(privateKey, provider);
      const contract = new ethers.Contract(contractAddress, VOTING_ABI, wallet);

      const contractAdmin = (await contract.admin()) as string;

      if (contractAdmin.toLowerCase() !== wallet.address.toLowerCase()) {
        throw new Error(
          `This key (${wallet.address.slice(0, 8)}...) is not the contract admin (${contractAdmin.slice(0, 8)}...)`
        );
      }

      setAdminAddress(wallet.address);
      setChainId(Number(network.chainId));
      lastBlockRef.current = 0; // reset so poll fetches fresh block data
      setConnected(true);
      setConnectionCounter((c) => c + 1);
      setTxStatus(`Connected to chain ID ${network.chainId.toString()}`);
    } catch (err) {
      setError(parseError(err));
      setTxStatus(null);
    } finally {
      setConnecting(false);
    }
  };

  // ─── Polling ─────────────────────────────────────────────────────────────────

  const poll = useCallback(async () => {
    if (!connectedRef.current) return;

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrlRef.current);
      const contract = new ethers.Contract(
        contractAddrRef.current,
        VOTING_ABI,
        provider
      );

      // Parallel: block number + contract state
      const [newBlockNum, isOpen, nCands] = await Promise.all([
        provider.getBlockNumber(),
        contract.votingOpen(),
        contract.numCandidates(),
      ]);

      const blockNum = newBlockNum as number;
      const numCands = Number(nCands);

      setBlockNumber(blockNum);
      setVotingOpen(Boolean(isOpen));
      setNumCandidates(numCands);

      // Peer count
      try {
        const peerHex = (await provider.send("net_peerCount", [])) as string;
        setPeerCount(parseInt(peerHex, 16));
      } catch {
        /* ignore */
      }

      // Tally
      if (numCands > 0) {
        const tallyResults = await Promise.all(
          Array.from({ length: numCands }, (_, i) => contract.getTally(i))
        );
        setTally(tallyResults.map((t) => Number(t)));
      }

      // IBFT validators — try both param formats
      for (const params of [["latest", null], ["latest"]] as unknown[][]) {
        try {
          const vals = (await provider.send(
            "ibft_getValidatorsByBlockNumber",
            params
          )) as string[];
          setValidators(vals);
          break;
        } catch {
          /* try next */
        }
      }

      // On new block: update benchmark data + voter list
      if (blockNum > lastBlockRef.current) {
        lastBlockRef.current = blockNum;

        const block = await provider.getBlock(blockNum);
        if (block) {
          const txCount = block.transactions.length;
          setLatestBlockTxCount(txCount);
          setBlockHistory((prev) => [
            ...prev.slice(-19),
            {
              blockNumber: blockNum,
              txCount,
              timestamp: block.timestamp * 1000,
            },
          ]);
        }

        // Refresh voter list from on-chain events
        const events = await contract.queryFilter(
          "VoterRegistered",
          0,
          "latest"
        );
        const addresses = (events as EventLog[])
          .filter((e) => e.args)
          .map((e) => e.args[0] as string);

        if (addresses.length > 0) {
          const stateResults = await Promise.all(
            addresses.map((addr) => contract.getVoterState(addr))
          );
          setVoters(
            addresses.map((addr, i) => ({
              address: addr,
              state: Number(stateResults[i]),
            }))
          );
        } else {
          setVoters([]);
        }
      }

      setPollError(null);
    } catch (err) {
      setPollError(parseError(err));
    }
  }, []);

  useEffect(() => {
    if (!connected) return;
    void poll();
    const interval = setInterval(() => void poll(), 2000);
    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [connected, connectionCounter, poll]);

  // ─── Admin transactions ──────────────────────────────────────────────────────

  const submitTx = async (
    label: string,
    fn: (contract: ethers.Contract) => Promise<ethers.ContractTransactionResponse>
  ) => {
    setError(null);
    setTxLoading(true);
    setTxStatus(`Submitting ${label}...`);
    const submitTime = Date.now();

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey, provider);
      const contract = new ethers.Contract(contractAddress, VOTING_ABI, wallet);

      const tx = await fn(contract);
      setTxStatus(`Transaction sent: ${tx.hash.slice(0, 18)}... Waiting for IBFT block seal...`);

      const receipt = await tx.wait();
      const latencyMs = Date.now() - submitTime;

      setLatencyHistory((prev) => [
        ...prev.slice(-9),
        {
          label: `${label} (${tx.hash.slice(0, 8)}...)`,
          latencyMs,
          blockNumber: receipt?.blockNumber ?? 0,
        },
      ]);
      setTxStatus(
        `${label} confirmed in block ${receipt?.blockNumber}. Finality latency: ${latencyMs}ms`
      );
    } catch (err) {
      setError(parseError(err));
      setTxStatus(null);
    } finally {
      setTxLoading(false);
    }
  };

  const registerVoter = async () => {
    const addr = registerInput.trim();
    if (!addr) return;

    // Validate address before touching the network
    let checksumAddr: string;
    try {
      checksumAddr = ethers.getAddress(addr);
    } catch {
      setRegisterError("Invalid Ethereum address. Must be 0x followed by 40 hex characters (42 chars total).");
      return;
    }

    setRegisterError(null);
    setRegisterStatus("Submitting transaction…");
    setTxLoading(true);
    const submitTime = Date.now();

    try {
      const provider = new ethers.JsonRpcProvider(rpcUrl);
      const wallet = new ethers.Wallet(privateKey, provider);
      const contract = new ethers.Contract(contractAddress, VOTING_ABI, wallet);

      const tx = await contract.registerVoter(checksumAddr, TX_OVERRIDES) as ethers.ContractTransactionResponse;
      setRegisterStatus(`Transaction sent: ${tx.hash.slice(0, 16)}… Waiting for IBFT seal…`);

      const receipt = await tx.wait();
      const latencyMs = Date.now() - submitTime;

      // Optimistic: add voter immediately with NotVoted state
      setVoters((prev) =>
        prev.some((v) => v.address.toLowerCase() === checksumAddr.toLowerCase())
          ? prev
          : [...prev, { address: checksumAddr, state: 0 }]
      );

      // Record latency
      setLatencyHistory((prev) => [
        ...prev.slice(-9),
        { label: `registerVoter (${tx.hash.slice(0, 8)}…)`, latencyMs, blockNumber: receipt?.blockNumber ?? 0 },
      ]);

      setRegisterStatus(`Registered in block ${receipt?.blockNumber}. Latency: ${latencyMs}ms`);
      setRegisterInput("");

      // Force voter list to reload on the very next poll regardless of block number
      lastBlockRef.current = 0;
    } catch (err) {
      setRegisterError(parseError(err));
      setRegisterStatus(null);
    } finally {
      setTxLoading(false);
    }
  };

  const openVoting = () =>
    submitTx("openVoting", (c) =>
      c.openVoting(TX_OVERRIDES) as Promise<ethers.ContractTransactionResponse>
    );

  const closeVoting = () =>
    submitTx("closeVoting", (c) =>
      c.closeVoting(TX_OVERRIDES) as Promise<ethers.ContractTransactionResponse>
    );

  // ─── Derived data ────────────────────────────────────────────────────────────

  const tpsData = blockHistory.map((block, i) => {
    if (i === 0) return { label: `#${block.blockNumber}`, tps: 0 };
    const prev = blockHistory[i - 1];
    const timeDiff = (block.timestamp - prev.timestamp) / 1000;
    return {
      label: `#${block.blockNumber}`,
      tps: timeDiff > 0 ? parseFloat((block.txCount / timeDiff).toFixed(3)) : 0,
    };
  });

  const tallyChartData = tally.map((count, i) => ({
    name: CANDIDATE_NAMES[i] ?? `Candidate ${i}`,
    votes: count,
  }));

  // ─── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="border-b border-border bg-card">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Link href="/" className="text-muted-foreground hover:text-foreground text-sm">← Home</Link>
            <div>
              <h1 className="text-base font-semibold leading-tight">
                Electoral Commission · Admin Dashboard
              </h1>
              <p className="text-xs text-muted-foreground">
                Hyperledger Besu IBFT 2.0 · Chain {chainId || "—"}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            {connected && (
              <Badge variant="secondary" className="font-mono text-xs">
                {adminAddress.slice(0, 6)}…{adminAddress.slice(-4)}
              </Badge>
            )}
            <Badge
              className={
                connected
                  ? "bg-green-100 text-green-800"
                  : "bg-muted text-muted-foreground"
              }
            >
              {connected ? "Connected" : "Disconnected"}
            </Badge>
            <Badge
              className={
                votingOpen
                  ? "bg-blue-100 text-blue-800"
                  : "bg-gray-100 text-gray-700"
              }
            >
              Voting {votingOpen ? "Open" : "Closed"}
            </Badge>
          </div>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-4 py-6 space-y-5">
        {/* ── Config ── */}
        <Card>
          <CardHeader>
            <CardTitle>Network Configuration</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
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
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  Admin Private Key
                </label>
                <Input
                  type="password"
                  value={privateKey}
                  onChange={(e) => setPrivateKey(e.target.value)}
                  placeholder="0x… (node 1 validator key)"
                  className="font-mono text-xs"
                />
              </div>
            </div>
            <div className="flex items-center gap-4 flex-wrap">
              <Button
                onClick={connect}
                disabled={!privateKey || connecting}
                size="sm"
              >
                {connecting ? "Connecting…" : connected ? "Reconnect" : "Connect"}
              </Button>
              {txStatus && (
                <p className="text-xs text-muted-foreground">{txStatus}</p>
              )}
            </div>
          </CardContent>
        </Card>

        {/* ── Errors ── */}
        {error && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}
        {pollError && connected && (
          <Alert variant="destructive">
            <AlertDescription>
              Poll error: {pollError} — check node connectivity.
            </AlertDescription>
          </Alert>
        )}

        {/* ── Chain Stats ── */}
        {connected && (
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
            {[
              { label: "Block Number", value: blockNumber.toLocaleString() },
              { label: "Peer Count", value: peerCount.toString() },
              {
                label: "Validators",
                value: validators.length ? validators.length.toString() : "—",
              },
              { label: "Latest Block TXs", value: latestBlockTxCount.toString() },
            ].map((stat) => (
              <Card key={stat.label}>
                <CardContent className="pt-4 pb-4">
                  <p className="text-xs text-muted-foreground">{stat.label}</p>
                  <p className="text-2xl font-bold mt-1">{stat.value}</p>
                </CardContent>
              </Card>
            ))}
          </div>
        )}

        {/* ── Tabs ── */}
        {connected && (
          <Tabs defaultValue="voters" className="w-full">
            <TabsList variant="line" className="mb-1">
              <TabsTrigger value="voters">Voter Management</TabsTrigger>
              <TabsTrigger value="control">Voting Control</TabsTrigger>
              <TabsTrigger value="benchmark">Benchmark</TabsTrigger>
              <TabsTrigger value="results">Live Results</TabsTrigger>
            </TabsList>

            {/* ── Voter Management ── */}
            <TabsContent value="voters" className="space-y-4 pt-4">
              <Card>
                <CardHeader>
                  <CardTitle>Register Voter</CardTitle>
                </CardHeader>
                <CardContent className="space-y-3">
                  <div className="flex gap-2">
                    <Input
                      value={registerInput}
                      onChange={(e) => {
                        setRegisterInput(e.target.value);
                        setRegisterError(null);
                      }}
                      placeholder="0x… voter Ethereum address (40 hex chars)"
                      className="font-mono text-xs flex-1"
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && registerInput.trim() && !txLoading)
                          void registerVoter();
                      }}
                    />
                    <Button
                      onClick={() => void registerVoter()}
                      disabled={!registerInput.trim() || txLoading}
                      size="sm"
                    >
                      {txLoading ? "Sending…" : "Register"}
                    </Button>
                  </div>

                  {registerStatus && (
                    <div className="flex items-center gap-2 text-xs text-muted-foreground">
                      {txLoading && (
                        <span className="relative flex h-2 w-2 shrink-0">
                          <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-primary opacity-75" />
                          <span className="relative inline-flex rounded-full h-2 w-2 bg-primary" />
                        </span>
                      )}
                      {registerStatus}
                    </div>
                  )}

                  {registerError && (
                    <Alert variant="destructive">
                      <AlertDescription>{registerError}</AlertDescription>
                    </Alert>
                  )}
                </CardContent>
              </Card>

              <Card>
                <CardHeader>
                  <CardTitle>
                    Registered Voters ({voters.length})
                  </CardTitle>
                </CardHeader>
                <CardContent>
                  {voters.length === 0 ? (
                    <p className="text-sm text-muted-foreground py-2">
                      No voters registered yet. Use the form above to register eligible voters.
                    </p>
                  ) : (
                    <div className="space-y-1.5">
                      {voters.map((v) => (
                        <div
                          key={v.address}
                          className="flex items-center justify-between p-2.5 rounded-lg border border-border"
                        >
                          <span className="font-mono text-xs text-foreground/80">
                            {v.address}
                          </span>
                          <span
                            className={`text-xs px-2 py-0.5 rounded-full font-medium ${VOTER_STATE_VARIANT[v.state] ?? "bg-muted text-muted-foreground"}`}
                          >
                            {VOTER_STATE_LABELS[v.state] ?? "Unknown"}
                          </span>
                        </div>
                      ))}
                    </div>
                  )}
                </CardContent>
              </Card>
            </TabsContent>

            {/* ── Voting Control ── */}
            <TabsContent value="control" className="pt-4">
              <Card>
                <CardHeader>
                  <CardTitle>Voting Control</CardTitle>
                </CardHeader>
                <CardContent className="space-y-5">
                  <div className="flex items-center gap-3">
                    <div
                      className={`px-4 py-2 rounded-full text-sm font-semibold ${
                        votingOpen
                          ? "bg-blue-100 text-blue-800"
                          : "bg-muted text-muted-foreground"
                      }`}
                    >
                      {votingOpen ? "VOTING IS OPEN" : "VOTING IS CLOSED"}
                    </div>
                    <span className="text-sm text-muted-foreground">
                      {numCandidates} candidates · {voters.length} registered voters
                    </span>
                  </div>

                  <div className="flex gap-3">
                    <Button
                      onClick={() => void openVoting()}
                      disabled={votingOpen || txLoading}
                      className="bg-green-600 hover:bg-green-700 text-white border-0"
                    >
                      Open Voting
                    </Button>
                    <Button
                      variant="destructive"
                      onClick={() => void closeVoting()}
                      disabled={!votingOpen || txLoading}
                    >
                      Close Voting
                    </Button>
                  </div>

                  <div className="text-sm text-muted-foreground space-y-1 border-t border-border pt-4">
                    <p>• <strong>Open Voting</strong> — calls <code className="font-mono text-xs">openVoting()</code> on the contract, enabling <code className="font-mono text-xs">castVote()</code> calls from registered voters.</p>
                    <p>• <strong>Close Voting</strong> — calls <code className="font-mono text-xs">closeVoting()</code>, reverting any further <code className="font-mono text-xs">castVote()</code> attempts.</p>
                    <p>• Both are on-chain transactions requiring IBFT consensus (≤2 seconds). The admin key signs with <code className="font-mono text-xs">gasPrice=0</code>.</p>
                  </div>
                </CardContent>
              </Card>
            </TabsContent>

            {/* ── Benchmark ── */}
            <TabsContent value="benchmark" className="space-y-4 pt-4">
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <Card>
                  <CardHeader>
                    <CardTitle>TPS — Rolling Window</CardTitle>
                  </CardHeader>
                  <CardContent>
                    {mounted && tpsData.length > 1 ? (
                      <ResponsiveContainer width="100%" height={200}>
                        <LineChart data={tpsData}>
                          <CartesianGrid
                            strokeDasharray="3 3"
                            stroke="var(--border)"
                          />
                          <XAxis
                            dataKey="label"
                            tick={{ fontSize: 10 }}
                            interval="preserveStartEnd"
                          />
                          <YAxis tick={{ fontSize: 10 }} />
                          <Tooltip />
                          <Line
                            type="monotone"
                            dataKey="tps"
                            stroke="var(--primary)"
                            dot={false}
                            name="TPS"
                            strokeWidth={2}
                          />
                        </LineChart>
                      </ResponsiveContainer>
                    ) : (
                      <div className="h-[200px] flex items-center justify-center text-sm text-muted-foreground">
                        Accumulating block data… ({blockHistory.length}/2 blocks needed)
                      </div>
                    )}
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle>Block Utilization</CardTitle>
                  </CardHeader>
                  <CardContent>
                    {mounted && blockHistory.length > 0 ? (
                      <ResponsiveContainer width="100%" height={200}>
                        <BarChart
                          data={blockHistory.slice(-20).map((b) => ({
                            label: `#${b.blockNumber}`,
                            txCount: b.txCount,
                          }))}
                        >
                          <CartesianGrid
                            strokeDasharray="3 3"
                            stroke="var(--border)"
                          />
                          <XAxis
                            dataKey="label"
                            tick={{ fontSize: 9 }}
                            interval="preserveStartEnd"
                          />
                          <YAxis
                            tick={{ fontSize: 10 }}
                            allowDecimals={false}
                          />
                          <Tooltip />
                          <Bar
                            dataKey="txCount"
                            fill="var(--primary)"
                            name="Transactions"
                          />
                        </BarChart>
                      </ResponsiveContainer>
                    ) : (
                      <div className="h-[200px] flex items-center justify-center text-sm text-muted-foreground">
                        Waiting for first block…
                      </div>
                    )}
                  </CardContent>
                </Card>
              </div>

              <Card>
                <CardHeader>
                  <CardTitle>Finality Latency</CardTitle>
                </CardHeader>
                <CardContent>
                  {latencyHistory.length === 0 ? (
                    <p className="text-sm text-muted-foreground py-2">
                      No transactions submitted yet. Register voters or open/close voting to record latency measurements.
                    </p>
                  ) : (
                    <div className="space-y-1.5">
                      {latencyHistory.map((l, i) => (
                        <div
                          key={i}
                          className="flex items-center justify-between p-2.5 rounded-lg border border-border text-sm"
                        >
                          <span className="font-mono text-xs text-muted-foreground truncate max-w-xs">
                            {l.label}
                          </span>
                          <span className="text-xs text-muted-foreground">
                            Block {l.blockNumber}
                          </span>
                          <span className="font-semibold tabular-nums">
                            {l.latencyMs} ms
                          </span>
                        </div>
                      ))}
                      {latencyHistory.length > 0 && (
                        <p className="text-xs text-muted-foreground pt-2">
                          Avg:{" "}
                          {Math.round(
                            latencyHistory.reduce((s, l) => s + l.latencyMs, 0) /
                              latencyHistory.length
                          )}{" "}
                          ms over {latencyHistory.length} transactions
                        </p>
                      )}
                    </div>
                  )}
                </CardContent>
              </Card>
            </TabsContent>

            {/* ── Live Results ── */}
            <TabsContent value="results" className="pt-4">
              <Card>
                <CardHeader>
                  <CardTitle>
                    Live Vote Tally — Block {blockNumber.toLocaleString()}
                  </CardTitle>
                </CardHeader>
                <CardContent>
                  {mounted && tallyChartData.length > 0 ? (
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
                          <Bar dataKey="votes" name="Votes" fill="var(--primary)" />
                        </BarChart>
                      </ResponsiveContainer>
                      <div className="flex gap-6 justify-center mt-4">
                        {tallyChartData.map((d, i) => (
                          <div key={i} className="text-center">
                            <div className="text-2xl font-bold">{d.votes}</div>
                            <div className="text-xs text-muted-foreground">{d.name}</div>
                          </div>
                        ))}
                      </div>
                      <p className="text-xs text-center text-muted-foreground mt-3">
                        Total votes cast:{" "}
                        {tally.reduce((s, v) => s + v, 0)} /{" "}
                        {voters.length} registered
                      </p>
                    </>
                  ) : (
                    <div className="h-48 flex items-center justify-center text-sm text-muted-foreground">
                      Loading tally data…
                    </div>
                  )}
                </CardContent>
              </Card>
            </TabsContent>
          </Tabs>
        )}

        {/* ── IBFT Validators ── */}
        {connected && validators.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle>
                IBFT 2.0 Validator Set ({validators.length})
              </CardTitle>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                {validators.map((v, i) => (
                  <div
                    key={v}
                    className="flex items-center gap-2 p-2 rounded-lg bg-muted/40"
                  >
                    <span className="text-xs text-muted-foreground w-4 shrink-0">
                      #{i + 1}
                    </span>
                    <span className="font-mono text-xs">{v}</span>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}

        {!connected && !connecting && (
          <div className="text-center py-16 text-muted-foreground">
            <p className="text-4xl mb-3">🔌</p>
            <p className="font-medium">Not connected</p>
            <p className="text-sm mt-1">
              Enter your admin private key above and click Connect to begin.
            </p>
          </div>
        )}
      </main>
    </div>
  );
}
