"use client";

// Mobile voter page opened from the projector QR code (/vote?code=<join code>).
// On first visit the phone generates a fresh keypair and keeps it in
// localStorage, so the same phone always comes back as the same voter. The
// server registers the address on-chain; the vote itself is signed here and
// relayed to Besu through /api/rpc.
//
// With &kiosk=1 (the "Vote on this computer" button on the projector) the page
// is a shared voting booth instead: every load starts on a "New voter" screen,
// each voter gets a fresh in-memory key that is never stored, and "Next voter"
// reloads the page back to that screen for the next person.

import { useCallback, useEffect, useRef, useState } from "react";
import { ethers } from "ethers";

import { VOTING_ABI } from "@/lib/abi";
import { TX_OVERRIDES, parseError } from "@/lib/blockchain";
import type { VoteReceipt } from "@/lib/types";

import { Button } from "@/components/ui/button";
import { Alert, AlertDescription } from "@/components/ui/alert";
import {
  PARTY_COLORS,
  PosterCard,
  PosterFooter,
  PosterHeader,
  PosterSection,
  VoteJourney,
} from "@/components/poster";

const KEY_STORAGE = "p4pDemoVoterKey";
const RECEIPT_STORAGE = "p4pDemoReceipt";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Status {
  contractAddress: string;
  blockNumber: number;
  votingOpen: boolean;
  question: string;
  candidates: string[];
  tally: number[];
  voter: { registered: boolean; state: number } | null;
}

type Phase = "init" | "welcome" | "registering" | "ready" | "no-code" | "error";

function loadWallet(kiosk: boolean): ethers.Wallet {
  if (kiosk) return new ethers.Wallet(ethers.Wallet.createRandom().privateKey);
  try {
    const stored = localStorage.getItem(KEY_STORAGE);
    if (stored) return new ethers.Wallet(stored);
  } catch {
    /* fall through to a fresh key */
  }
  const fresh = ethers.Wallet.createRandom();
  try {
    localStorage.setItem(KEY_STORAGE, fresh.privateKey);
  } catch {
    /* private mode: key lives only for this tab */
  }
  return new ethers.Wallet(fresh.privateKey);
}

export default function VotePage() {
  const walletRef = useRef<ethers.Wallet | null>(null);
  const codeRef = useRef("");
  const [address, setAddress] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>("init");
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [receipt, setReceipt] = useState<VoteReceipt | null>(null);
  // poster step (0-6) currently lit while a vote travels through the network
  const [journey, setJourney] = useState<number | null>(null);
  const [kiosk, setKiosk] = useState(false);

  const fetchStatus = useCallback(async (addr: string) => {
    const res = await fetch(`/api/status?address=${addr}`, { cache: "no-store" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error ?? "Status unavailable");
    setStatus(data as Status);
    return data as Status;
  }, []);

  // ─── Keypair → status → auto-register ──────────────────────────────────────
  const enrol = useCallback(
    async (wallet: ethers.Wallet) => {
      walletRef.current = wallet;
      setAddress(wallet.address);
      try {
        const s = await fetchStatus(wallet.address);
        if (s.voter?.registered) return setPhase("ready");
        if (!codeRef.current) return setPhase("no-code");

        setPhase("registering");
        const res = await fetch("/api/register", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ address: wallet.address, code: codeRef.current }),
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error ?? "Registration failed");
        await fetchStatus(wallet.address);
        setPhase("ready");
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
        setPhase("error");
      }
    },
    [fetchStatus]
  );

  // ─── First load: phones enrol straight away, the shared booth waits ────────
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    codeRef.current = params.get("code") ?? "";
    if (params.get("kiosk") === "1") {
      setKiosk(true);
      setPhase("welcome");
      // Back/Forward can restore the previous voter's page from the bfcache;
      // reload so every visit starts as a new voter.
      const onShow = (e: PageTransitionEvent) => e.persisted && window.location.reload();
      window.addEventListener("pageshow", onShow);
      return () => window.removeEventListener("pageshow", onShow);
    }
    try {
      const r = localStorage.getItem(RECEIPT_STORAGE);
      if (r) setReceipt(JSON.parse(r));
    } catch {
      /* ignore */
    }
    void enrol(loadWallet(false));
  }, [enrol]);

  // ─── Poll every 2s (one IBFT block) once registered ─────────────────────────
  useEffect(() => {
    if (phase !== "ready" || !address) return;
    const id = setInterval(() => void fetchStatus(address).catch(() => {}), 2000);
    return () => clearInterval(id);
  }, [phase, address, fetchStatus]);

  // ─── Cast vote: signed on the phone, relayed by /api/rpc ────────────────────
  const castVote = async () => {
    const wallet = walletRef.current;
    if (selected === null || !wallet || !status) return;
    setError(null);
    setSubmitting(true);
    setJourney(0);
    let timer: ReturnType<typeof setInterval> | undefined;
    try {
      const network = ethers.Network.from(1337);
      const provider = new ethers.JsonRpcProvider(`${window.location.origin}/api/rpc`, network, {
        staticNetwork: network,
        batchMaxCount: 1,
        pollingInterval: 1000,
      });
      const signer = wallet.connect(provider);
      const contract = new ethers.Contract(status.contractAddress, VOTING_ABI, signer);
      await sleep(350);
      setJourney(1);
      const tx = (await contract.castVote(selected, TX_OVERRIDES)) as ethers.ContractTransactionResponse;

      // Steps 2-5 happen inside one IBFT round (~2 s); walk through them while
      // waiting for the block, then land on "Recorded" when it is sealed.
      let step = 2;
      setJourney(step);
      timer = setInterval(() => setJourney((step = Math.min(step + 1, 5))), 450);
      const mined = await tx.wait(1, 60_000);
      clearInterval(timer);
      while (step < 5) {
        await sleep(200);
        setJourney(++step);
      }
      await sleep(300);
      setJourney(6);
      const block = mined ? await provider.getBlock(mined.blockNumber) : null;
      const r: VoteReceipt = {
        txHash: tx.hash,
        blockNumber: mined?.blockNumber ?? 0,
        timestamp: (block?.timestamp ?? 0) * 1000,
        candidateId: selected,
      };
      setReceipt(r);
      try {
        if (!kiosk) localStorage.setItem(RECEIPT_STORAGE, JSON.stringify(r));
      } catch {
        /* ignore */
      }
      await fetchStatus(wallet.address);
    } catch (err) {
      setError(parseError(err));
      setJourney(null);
    } finally {
      clearInterval(timer);
      setSubmitting(false);
    }
  };

  const voted = status?.voter?.state === 2;
  const candidates = status?.candidates ?? [];
  const totalVotes = (status?.tally ?? []).reduce((a, b) => a + b, 0);
  const showJourney = journey !== null || voted;
  const device = kiosk ? "computer" : "phone";

  return (
    <div className="min-h-screen flex flex-col bg-background">
      <PosterHeader
        compact
        title="NZ Blockchain Vote"
        left={kiosk ? "Shared voting computer · P4P #68" : "Live demo · P4P #68"}
        right={status ? `Block #${status.blockNumber.toLocaleString()}` : undefined}
      >
        {status && (
          <span
            className={`shrink-0 mt-0.5 text-xs px-2.5 py-1 rounded-full font-bold ${
              status.votingOpen ? "bg-white text-[#2e7d32]" : "bg-white/25 text-white"
            }`}
          >
            {status.votingOpen ? "● Voting open" : "Voting closed"}
          </span>
        )}
      </PosterHeader>

      <main className="w-full max-w-md mx-auto px-4 py-5 space-y-5">
        {(phase === "init" || phase === "registering") && (
          <PosterSection title={phase === "init" ? "Connecting" : "Enrolling you"} size="sm">
            <div className="py-6 text-center space-y-3">
              <div className="mx-auto h-9 w-9 rounded-full border-4 border-peach-deep border-t-orange animate-spin" />
              <p className="font-bold text-navy">
                {phase === "init" ? "Connecting to the network…" : "Registering you on the blockchain…"}
              </p>
              {phase === "registering" && (
                <p className="text-sm text-muted-foreground">
                  A fresh digital key was created on this {device}. The Electoral Commission is adding
                  you to the voter roll — about one block (2 seconds).
                </p>
              )}
            </div>
          </PosterSection>
        )}

        {phase === "welcome" && (
          <PosterSection title="New voter" size="sm">
            <div className="py-5 text-center space-y-3">
              <p className="font-bold text-navy text-lg">Welcome to the voting computer</p>
              <p className="text-sm text-muted-foreground">
                Press start to get your own digital key. You will be enrolled on the blockchain as a
                new voter, separate from everyone who used this computer before you.
              </p>
              <Button
                onClick={() => void enrol(loadWallet(true))}
                className="w-full h-12 text-base font-bold rounded-xl"
              >
                Start voting
              </Button>
            </div>
          </PosterSection>
        )}

        {phase === "no-code" && (
          <PosterCard title="Not enrolled yet">
            <p className="text-sm">Scan the QR code on the screen to join the vote.</p>
          </PosterCard>
        )}

        {error && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}

        {phase === "ready" && status && !voted && !status.votingOpen && journey === null && (
          <PosterSection title="You're enrolled" size="sm">
            <div className="py-5 text-center space-y-2">
              <div className="mx-auto h-12 w-12 rounded-full bg-[#43a047] text-white text-2xl font-bold flex items-center justify-center">
                ✓
              </div>
              <p className="font-bold text-navy text-lg">Ready to vote</p>
              <p className="text-sm text-muted-foreground">
                Waiting for the Electoral Commission to open voting. This page updates by itself.
              </p>
            </div>
          </PosterSection>
        )}

        {phase === "ready" && status && !voted && status.votingOpen && journey === null && (
          <PosterSection title="Cast your vote" size="sm">
            <div className="space-y-2.5">
              <p className="text-xl font-bold text-navy leading-snug pb-1">{status.question}</p>
              {candidates.map((name, i) => (
                <button
                  key={i}
                  onClick={() => setSelected(i)}
                  disabled={submitting}
                  className={`w-full p-4 rounded-xl border-2 bg-card text-left text-base font-bold text-navy transition-all flex items-center gap-3 ${
                    selected === i ? "border-orange ring-2 ring-orange/30" : "border-navy/30"
                  } disabled:opacity-50`}
                >
                  <span
                    className="h-4 w-4 rounded-full shrink-0"
                    style={{ background: PARTY_COLORS[i % PARTY_COLORS.length] }}
                  />
                  {name}
                  <span
                    className={`ml-auto h-6 w-6 rounded-full border-2 flex items-center justify-center text-sm ${
                      selected === i ? "bg-orange border-orange text-white" : "border-navy/30"
                    }`}
                  >
                    {selected === i ? "✓" : ""}
                  </span>
                </button>
              ))}
              <Button
                onClick={() => void castVote()}
                disabled={selected === null || submitting}
                className="w-full h-12 text-base font-bold rounded-xl"
              >
                {selected !== null ? `Vote for ${candidates[selected]}` : "Choose an answer"}
              </Button>
              <p className="text-xs text-muted-foreground">
                Your ballot is signed with the key on this {device}. Once it is recorded it cannot be
                changed.
              </p>
            </div>
          </PosterSection>
        )}

        {showJourney && (
          <PosterSection title={journey !== null && journey < 6 ? "Your vote's journey" : "Vote recorded"} size="sm">
            <VoteJourney layout="list" active={journey ?? 7} />
            {receipt && (journey === null || journey === 6) && (
              <div className="mt-3 rounded-xl border-[1.5px] border-[#43a047] bg-[#e8f5e9] px-3 py-2.5 space-y-1.5 text-sm">
                <Row label="Choice" value={candidates[receipt.candidateId] ?? `#${receipt.candidateId}`} />
                <Row label="Block" value={`#${receipt.blockNumber.toLocaleString()}`} />
                <Row label="Transaction" value={receipt.txHash} mono />
              </div>
            )}
            {voted && !receipt && (
              <p className="mt-3 text-sm font-semibold text-[#2e7d32]">This {device} has already voted.</p>
            )}
            {kiosk && voted && (journey === null || journey === 6) && (
              <Button
                onClick={() => window.location.reload()}
                className="mt-3 w-full h-12 text-base font-bold rounded-xl"
              >
                Next voter
              </Button>
            )}
          </PosterSection>
        )}

        {phase === "ready" && status && (voted || status.votingOpen) && (journey === null || journey === 6) && (
          <PosterCard title={<>Live tally <span className="text-muted-foreground text-sm font-semibold">· {totalVotes} vote{totalVotes === 1 ? "" : "s"}</span></>}>
            <div className="space-y-3 pt-1">
              {candidates.map((name, i) => {
                const v = status.tally[i] ?? 0;
                const pct = totalVotes ? (v / totalVotes) * 100 : 0;
                return (
                  <div key={i} className="space-y-1">
                    <div className="flex justify-between text-sm font-semibold text-navy">
                      <span>{name}</span>
                      <span className="tabular-nums">{v}</span>
                    </div>
                    <div className="h-3 rounded-full bg-peach-deep overflow-hidden">
                      <div
                        className="h-full rounded-full transition-all duration-500"
                        style={{ width: `${pct}%`, background: PARTY_COLORS[i % PARTY_COLORS.length] }}
                      />
                    </div>
                  </div>
                );
              })}
            </div>
          </PosterCard>
        )}

        {address && (
          <p className="text-[11px] text-center text-muted-foreground font-mono break-all">
            Your voter address: {address}
          </p>
        )}
      </main>

      <PosterFooter compact />
    </div>
  );
}

function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <span className="text-[#2e7d32] font-semibold shrink-0">{label}</span>
      <span className={`text-right text-navy ${mono ? "font-mono text-xs break-all" : "font-bold"}`}>{value}</span>
    </div>
  );
}
