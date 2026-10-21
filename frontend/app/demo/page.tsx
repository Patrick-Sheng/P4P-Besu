"use client";

// Projector page for the live demo (/demo?admin=<token>, printed by
// demo/start-demo.sh), styled after the P4P poster. Shows the join QR code,
// live registration / vote counters and tally, the 0-6 vote journey (which
// replays each time a new vote is sealed), and open/close voting controls.

import { useCallback, useEffect, useRef, useState } from "react";
import QRCode from "qrcode";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  ResponsiveContainer,
  Cell,
  LabelList,
} from "recharts";

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

interface AdminInfo {
  joinUrl: string;
  publicUrl: string;
  contractAddress: string;
  registeredCount: number;
  validatorCount: number;
  nodeCount: number;
}

interface Status {
  blockNumber: number;
  votingOpen: boolean;
  candidates: string[];
  tally: number[];
}

export default function DemoPage() {
  const [token, setToken] = useState<string | null>(null);
  const [info, setInfo] = useState<AdminInfo | null>(null);
  const [status, setStatus] = useState<Status | null>(null);
  const [qrSvg, setQrSvg] = useState<string>("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [journeyStep, setJourneyStep] = useState<number | undefined>(undefined);
  const lastTotal = useRef<number | null>(null);
  const journeyTimer = useRef<ReturnType<typeof setInterval> | undefined>(undefined);

  useEffect(() => {
    setToken(new URLSearchParams(window.location.search).get("admin") ?? "");
  }, []);

  const refresh = useCallback(async () => {
    if (!token) return;
    try {
      const [iRes, sRes] = await Promise.all([
        fetch("/api/admin", { headers: { "x-admin-token": token }, cache: "no-store" }),
        fetch("/api/status", { cache: "no-store" }),
      ]);
      const [i, s] = await Promise.all([iRes.json(), sRes.json()]);
      if (!iRes.ok) throw new Error(i.error);
      if (!sRes.ok) throw new Error(s.error);
      setInfo(i);
      setStatus(s);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [token]);

  useEffect(() => {
    if (!token) return;
    void refresh();
    const id = setInterval(() => void refresh(), 2000);
    return () => clearInterval(id);
  }, [token, refresh]);

  useEffect(() => {
    if (!info?.joinUrl) return;
    QRCode.toString(info.joinUrl, {
      type: "svg",
      margin: 1,
      errorCorrectionLevel: "M",
      color: { dark: "#13294b", light: "#ffffff" },
    })
      .then(setQrSvg)
      .catch(() => setQrSvg(""));
  }, [info?.joinUrl]);

  const totalVotes = (status?.tally ?? []).reduce((a, b) => a + b, 0);

  // Replay the 0-6 journey whenever new votes are sealed.
  useEffect(() => {
    if (!status) return;
    const prev = lastTotal.current;
    lastTotal.current = totalVotes;
    if (prev === null || totalVotes <= prev) return;
    clearInterval(journeyTimer.current);
    let step = 0;
    setJourneyStep(0);
    journeyTimer.current = setInterval(() => {
      step++;
      if (step > 7) {
        clearInterval(journeyTimer.current);
        setJourneyStep(undefined);
      } else {
        setJourneyStep(Math.min(step, 6));
      }
    }, 260);
  }, [status, totalVotes]);

  useEffect(() => () => clearInterval(journeyTimer.current), []);

  const setVoting = async (action: "open" | "close") => {
    if (!token) return;
    setBusy(true);
    try {
      const res = await fetch("/api/admin", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-admin-token": token },
        body: JSON.stringify({ action }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error);
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  if (token === "") {
    return (
      <div className="min-h-screen flex items-center justify-center p-6">
        <Alert className="max-w-md">
          <AlertDescription>
            Open this page with the presenter link printed by <code>demo/start-demo.sh</code>{" "}
            (it ends in <code>?admin=…</code>).
          </AlertDescription>
        </Alert>
      </div>
    );
  }

  const chartData = (status?.candidates ?? []).map((name, i) => ({ name, votes: status?.tally[i] ?? 0 }));
  const turnout =
    info && info.registeredCount > 0 ? `${Math.round((totalVotes / info.registeredCount) * 100)}%` : undefined;

  return (
    <div className="min-h-screen flex flex-col bg-background">
      <PosterHeader
        title={<>#68 Live Demo: Blockchain Voting for New Zealand General Elections</>}
        left="Patrick Sheng & Eason Chang"
        right={
          <>
            Hyperledger Besu · IBFT 2.0 · {info?.validatorCount ?? "–"} validators · block #
            {status?.blockNumber.toLocaleString() ?? "–"}
          </>
        }
      />

      <main className="w-full max-w-[1500px] mx-auto px-6 py-4 space-y-4">
        {error && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,340px)_1fr] gap-5">
          <PosterSection title="Scan to Vote">
            <div className="space-y-3">
              {qrSvg ? (
                <div
                  className="bg-white p-3 rounded-xl border-[1.5px] border-navy/80 [&>svg]:w-full [&>svg]:h-auto"
                  dangerouslySetInnerHTML={{ __html: qrSvg }}
                />
              ) : (
                <div className="aspect-square rounded-xl bg-peach-deep animate-pulse" />
              )}
              <p className="text-center text-navy font-semibold leading-snug">
                Your phone creates its own <strong>digital key</strong> and is{" "}
                <strong>enrolled on-chain</strong> automatically.
              </p>
              <p className="text-[11px] text-muted-foreground font-mono break-all text-center">
                {info?.joinUrl}
              </p>
              {/* No phone, or the QR/tunnel is down: vote in a new tab on this
                  machine. Local path, so it works without the public URL. */}
              {info?.joinUrl && (
                <Button
                  asChild
                  variant="outline"
                  className="w-full font-bold border-2 border-navy/80 text-navy"
                >
                  {/* One reusable booth tab; the timestamp forces a fresh load
                      (and so a new voter) on every click, even if it is open. */}
                  <a
                    href={boothUrl(info.joinUrl)}
                    onClick={(e) => {
                      e.currentTarget.href = boothUrl(info.joinUrl);
                    }}
                    target="p4p-voting-booth"
                  >
                    No phone? Vote on this computer
                  </a>
                </Button>
              )}
            </div>
          </PosterSection>

          <PosterSection
            title="Live Results"
            action={
              <div className="flex items-center gap-3">
                <span
                  className={`text-sm px-3 py-1.5 rounded-full font-bold border-2 ${
                    status?.votingOpen
                      ? "bg-[#dcefc4] border-[#43a047] text-[#2e7d32]"
                      : "bg-card border-navy/30 text-navy/70"
                  }`}
                >
                  {status?.votingOpen ? "● Voting open" : "Voting closed"}
                </span>
                {status?.votingOpen ? (
                  <Button
                    className="bg-navy hover:bg-navy/85 font-bold"
                    disabled={busy}
                    onClick={() => void setVoting("close")}
                  >
                    {busy ? "Sealing…" : "Close voting"}
                  </Button>
                ) : (
                  <Button className="font-bold" disabled={busy || !status} onClick={() => void setVoting("open")}>
                    {busy ? "Sealing…" : "Open voting"}
                  </Button>
                )}
              </div>
            }
          >
            <div className="space-y-4">
              <div className="grid grid-cols-3 gap-4">
                <Stat label="Registered voters" value={info?.registeredCount} />
                <Stat label="Votes recorded" value={status ? totalVotes : undefined} />
                <Stat label="Turnout" value={turnout} />
              </div>

              <PosterCard title="Vote Tally">
                <ResponsiveContainer width="100%" height={230}>
                  <BarChart data={chartData} margin={{ top: 30, right: 8, left: -8, bottom: 0 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#e9c3a4" vertical={false} />
                    <XAxis
                      dataKey="name"
                      tick={{ fontSize: 16, fontWeight: 700, fill: "#13294b" }}
                      axisLine={{ stroke: "#13294b" }}
                      tickLine={false}
                    />
                    <YAxis allowDecimals={false} tick={{ fontSize: 13, fill: "#5b6474" }} axisLine={false} tickLine={false} />
                    <Bar dataKey="votes" radius={[6, 6, 0, 0]} maxBarSize={120} isAnimationActive={false}>
                      {chartData.map((_, i) => (
                        <Cell key={i} fill={PARTY_COLORS[i % PARTY_COLORS.length]} />
                      ))}
                      <LabelList
                        dataKey="votes"
                        position="top"
                        style={{ fontSize: 20, fontWeight: 800, fill: "#13294b" }}
                      />
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
                <p className="text-xs text-center text-muted-foreground mt-1">
                  Read directly from the smart contract on every validator · updates every block
                  (2 s) · <span className="font-mono">{info?.contractAddress}</span>
                </p>
              </PosterCard>
            </div>
          </PosterSection>
        </div>

        <PosterSection title="How Your Vote Is Recorded">
          <VoteJourney active={journeyStep} />
        </PosterSection>
      </main>

      <PosterFooter />
    </div>
  );
}

function boothUrl(joinUrl: string) {
  const code = new URL(joinUrl).searchParams.get("code") ?? "";
  return `/vote?${new URLSearchParams({ code, kiosk: "1", t: String(Date.now()) })}`;
}

function Stat({ label, value }: { label: string; value: number | string | undefined }) {
  return (
    <div className="border-[1.5px] border-navy/80 rounded-xl bg-card py-3 text-center">
      <div className="text-5xl font-extrabold tabular-nums text-navy">{value ?? "–"}</div>
      <div className="text-sm font-semibold text-muted-foreground mt-1">{label}</div>
      <span className="block mx-auto mt-2 h-[3px] w-10 rounded-full bg-orange" />
    </div>
  );
}
