# Area 4 — Throughput results, SCALED (2026-10-08)

**These are not the planned Area 4 tests.** The configs in `caliper/benchmarks/throughput/` target
300–1,200 TPS at n=7 with 0.1–4.3M voters; this host saturates at ≈80 TPS at n=7. What ran instead is
a scaled version at **n=4**, with rates set relative to the measured n=4 ceiling. It answers the same
questions (steady-state behaviour, spike recovery, ceiling, endurance, read latency vs. state) for
*this* setup — not the 300–500 TPS target, which still needs real hardware.

Host: 4 cores, 7.7 GB, no swap; Besu 24.12.0, IBFT 2.0, 2 s blocks; 4 validators capped at ~880–893 MB
each (heap ~350 MB). Driver: `scripts/run-area4.sh` → `scripts/area4-throughput.sh`. 2 Caliper workers,
sends spread across all validators. Per-10 s timelines: `<run>/timeline-*.txt`.

## Summary

| Test | Scaled design | Result |
|---|---|---|
| Load | 60 TPS steady, 10 min | **Steady for ~8 min** (p50 1.4–1.7 s, p95 2.3–2.8 s, 32,000 votes, 0 reverts), then a **memory-driven collapse**: validators reached their caps, validator1 went into back-to-back full GCs, chain stalled (`CONSENSUS_STALL`) |
| Spike | 30 → 150 → 30 TPS (2 / 1 / 3 min) | **Recovered cleanly**: 117 TPS confirmed during the burst, p50 back to baseline in recovery; 16,893/16,893 succeeded |
| Stress | staircase 20 → 200 TPS, 10 × 20 s | **Knee ≈ 140 TPS**; max sustained ≈ 150–160 TPS confirmed with latency climbing to 5–8 s; 21,928/21,928 succeeded |
| Endurance | (planned 40 TPS × 45 min) | **Not run as such** — the load test already showed the endurance limit on this host: steady memory growth to the per-node cap after ~70k transactions (~17 min of registration + load) |
| Volume | read probes as state grows | Reads stay fast at this (small) scale: p50 9–13 ms, p95 33–43 ms at 2–17k votes; the 2.9M-vote question is not reachable here |

## Load (60 TPS) — run n4-20261008-230215

| Minute | Submitted | Confirmed | p50 (s) | p95 (s) | p99 (s) |
|---|---|---|---|---|---|
| 0 | 3,604 | 3,511 | 1.70 | 2.81 | 3.12 |
| 1–7 | ~3,600/min | ~3,600/min | 1.44–1.64 | 2.34–2.63 | 2.48–3.08 |
| 8 | 3,196 | 3,132 | 2.97 | 7.17 | 8.46 |
| 9 | 0 | 172 | 13.65 | 15.83 | 16.37 |

Validator memory (cgroup, MB) climbed roughly linearly through registration and load:
~330 → 480 (registration) → 630 → 790 → 890 (cap) over ~17 min. At the end validator1's 346 MB heap held
~230 MB live after every full GC and ran 0.5 s full GCs back-to-back (240 in total), its RPC stopped
answering, and consensus stalled at block 467. ~3,100 votes were left unconfirmed.

**Finding:** per-node memory grows with chain activity (≈35 MB/min/node at 60 TPS here). On this host the
budget runs out at ~70k transactions; on production-sized heaps the same growth takes longer to bite but
is exactly what a real endurance run must watch. Whether it plateaus (cache sizing) or keeps growing
could not be determined within this host's memory.

## Spike — run n4-20261008-232149 (30 → 150 → 30 TPS)

| Phase | Offered | Confirmed TPS | p50 (s) | p95 (s) | Block gap |
|---|---|---|---|---|---|
| Baseline (2 min) | 30 | 29.5 | 1.54 | 2.64 | 2.00 s |
| Spike (1 min) | 150 | 117.0 | 6.54 | 9.05 | 2.03 s (max 3) |
| Recovery (3 min) | 30 | 34.9 | 1.50 | 5.51 | 2.00 s |

The burst exceeded capacity (≈117 confirmed of 150 offered), latency rose to 6.5 s p50, and the backlog
drained in the first part of recovery (confirmed > offered), after which latency returned to baseline.
Block production never missed its period. No transaction failed.

## Stress — run n4-20261008-233320 (staircase 20 → 200 TPS)

| Step | Offered | Confirmed TPS | p50 (s) | p95 (s) |
|---|---|---|---|---|
| 0–3 | 20 / 40 / 60 / 80 | 17.9 / 38.1 / 58.0 / 78.1 | 1.46–1.77 | 2.38–2.93 |
| 4 | 100 | 98.2 | 1.98 | 2.93 |
| 5 | 120 | 117.9 | 2.20 | 3.16 |
| 6 | 140 | 138.1 | 2.54 | 4.08 |
| 7 | 160 | 130.7 | **5.77** | 7.22 |
| 8 | 180 | 187.1* | 4.97 | 6.45 |
| 9 | 200 | 186.5* | 6.67 | 10.06 |

\* steps 8–9 include backlog from earlier steps; per-10 s confirmations were bursty (86–204), averaging
≈155 TPS from step 7 to the end of the run. Latency is flat to 140 TPS and steps up sharply at 160.

This ceiling (≈140–160 TPS) is a little higher than Area 1's ≈120–135 TPS: Area 1 relaunched Caliper
per round and its own send rate fell short above ~135, so part of that limit was the load generator.

## Volume (read latency vs. state size)

| Run / probe | Votes on chain | Voters registered | Reads | p50 / p95 / p99 (ms) |
|---|---|---|---|---|
| spike run, after test | 16,893 | 19,800 | 500 | 9 / 33 / 76 |
| stress run, after test | 21,928 | 25,410 | 500 | 11 / 26 / 57 |
| smoke runs | 1.7k–7.5k | 2.4k–10.8k | 50–100 | 10–30 / 22–115 |

No read degradation is visible at ≤ 22k votes; that says nothing about 2.9M. Note: the volume probes
were meant to accumulate across one long-lived network, which this host's memory ceiling prevented.

## Besu 24.12.0 deadlock found while validating the harness

Two smoke runs (`n4-20261008-225230`, `n4-20261008-225553`) hit a validator that stopped importing
blocks ~40 s after start while staying "active". The thread dump (`n4-20261008-225553/threaddump-v4.txt`)
shows a lock-ordering deadlock:

- `nioEventLoopGroup` (sync downloader) holds the **SyncState** lock (`SyncState.replaceSyncTarget`) and,
  via the "stop IBFT mining coordinator while syncing" listener, waits in `BftProcessor.awaitStop`;
- `BftProcessorExecutor-IBFT-0` holds the **DefaultBlockchain** lock importing a committed block
  (`IbftRound.importBlockToChain`) and waits for the **SyncState** lock (`SyncState.checkInSync`).

Trigger here: a freshly started validator briefly falls behind (JIT warm-up CPU load + a large registration
block) and the sync downloader kicks in while IBFT is importing. With 4 validators, one hung node makes
the 25% of client sends routed to it disappear; two hung nodes halt the chain. Mitigations used: 60 s
warm-up before load; the watchdog now detects a node lagging the chain (`NODE_STUCK`) and takes thread
dumps on any stall. Worth checking against newer Besu releases / reporting upstream.

## Run log

| Run | Outcome |
|---|---|
| n4-20261008-224521 | SMOKE (30–60 s tests) — completed, validated the driver |
| n4-20261008-225230 | SMOKE stress — `CONSENSUS_STALL`: validators 2+4 deadlocked at block #11 |
| n4-20261008-225553 | SMOKE stress retry — validator4 deadlocked at #11 (752 sends lost); thread dump captured |
| n4-20261008-230215 | Full sequence — load ran ~9 min, then `CONSENSUS_STALL` from validator memory exhaustion |
| n4-20261008-232149 | Spike — COMPLETED |
| n4-20261008-233320 | Stress — COMPLETED |

Harness changes for Area 4: read-call latency recording in the connector; registration 40 → ~115/s
(ethers polling 4 s → 250 ms); submitted-vs-confirmed timeline with generic phases; staircase stress
instead of Caliper's `linear-rate` (which ramps sleep time, not TPS); per-node lag detection and thread
dumps in the watchdog.
