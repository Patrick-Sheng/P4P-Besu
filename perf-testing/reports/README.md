# Test results index

All runs on the dev box: 4 cores, 7.7 GB RAM, no swap; Besu 24.12.0, IBFT 2.0, 2 s blocks, native
network (no Docker). Numbers are host-bound — see each area's caveats.

| Area | Status | Summary | Headline |
|---|---|---|---|
| 1 — Scalability | Run (n=4 full, n=7 partial, n=10 partial) | [AREA1-RESULTS.md](scalability-results/AREA1-RESULTS.md) | Saturation ≈120–135 TPS at n=4, ≈80 TPS at n=7 (CPU-bound host); n=7 OOM at 200 TPS, n=10 OOM at 50 TPS; zero failed txs in completed rounds |
| 2 — Crash faults | Run (n=4 full, n=7 partial, n=10 blocked) | [AREA2-RESULTS.md](crash-fault-results/AREA2-RESULTS.md) | f crashed → live, resync 5–11 s, identical state; f+1 → halts, no fork; resume 135–266 s after quorum restored; 31% of votes sent during outage silently evicted (tx pool cap 4,096) |
| 3 — Malicious nodes | Run (n=4, 7, 10; client-level only) | [AREA3-RESULTS.md](malicious-results/AREA3-RESULTS.md) | Double-vote, equivocation, replay: 27/27 PASS, all validators agree; rogue-validator attacks not run |
| 4 — Throughput | Run **scaled** at n=4 (not the 300–1,200 TPS n=7 design) | [AREA4-RESULTS.md](throughput-results/AREA4-RESULTS.md) | Load 60 TPS steady (p95 ≈2.5 s) until validator memory hit its cap after ~70k txs → GC death spiral → stall; spike 150 TPS recovered cleanly; stress knee ≈140 TPS, max ≈150–160 TPS; Besu 24.12.0 SyncState/BftProcessor deadlock found |

Per-run detail lives in each area's run directories (`summary.csv`, `sweep.log`/`run.log`, timelines,
resource samples). Every run's outcome — including crashes and their labelled cause — is appended to
`scalability-results/area1-index.log`, `crash-fault-results/area2-index.log`, `malicious-results/area3-index.log` and
`throughput-results/area4-index.log`.

Not yet covered anywhere: the 300–500 TPS target, n=13, the full-size Area 4 tests (n=7, 0.1–4.3M voters, 4 h endurance), and IBFT wire-protocol fuzzing.

## Round 2: election-scale plan (2026-10-15/16)

Upgraded VM: 6 vCPU, 15.6 GiB RAM, 200 GB disk. Full write-up: [R2-ELECTION-SCALE-RESULTS.md](r2-soak/R2-ELECTION-SCALE-RESULTS.md).

| Area | Status | Summary | Headline |
|---|---|---|---|
| 1 — Scalability | Run: n=4, 7 loaded; n=10, 13, 16 idle | [R2-AREA1-RESULTS.md](r2-scalability/R2-AREA1-RESULTS.md) | Breaking point n=7 (CPU); n=4 sustains 150 votes/s; idle consensus CPU ≈ 0.88·n² |
| 4 — Throughput soak | Run to **1M votes** on a 3.3M-voter chain (plan: 5M) | [R2 results §6](r2-soak/R2-ELECTION-SCALE-RESULTS.md) | 0 lost votes, 100 % success every round, heap flat; latency/block-time criteria missed in 4 of 5 rounds (host CPU starvation, two Besu 24.12 stalls) |
| 3 — Malicious voters | Run at 1M (plan: 1M/3M/5M) | [R2 results §7](r2-soak/R2-ELECTION-SCALE-RESULTS.md) | 27/27 attacks blocked; 1,000/1,000 mass double votes reverted, tallies unchanged |
| 2 — Fault tolerance | Run on the 1M-vote chain (30 votes/s, shortened holds) | [R2 results §8](r2-soak/R2-ELECTION-SCALE-RESULTS.md) | f down: live, 0 failed, rejoin 48 s; quorum loss: safe halt, no fork, 0 of 5,406 votes lost (round 1 lost 31 %); recovery 286 s |

## Round 3: validator count gaps (2026-10-17)

Same VM as round 2. Results added to the Area write-ups above (sections "Round 3"); every launch in
[round3-index.log](round3-index.log).

| Test | Result |
|---|---|
| 1. Latency ladder, n = 4–13 at 10/25/50 votes/s | Max sustainable: n=4 and 7 ≥ 50, n=10 25, n=13 10 votes/s (memory ran out at 25) — [AREA1 §Round 3](scalability-results/AREA1-RESULTS.md) |
| 2. Agreement time, 100 ms blocks, n = 4–16 | Median ≈ 16, 77, 122, 223, 558 ms (projected 0.2–3.1 s) — [AREA1 §Round 3](scalability-results/AREA1-RESULTS.md) |
| 3. f validators offline, n = 4–13 | Live, 0 votes lost, catch-up 1–9 s; worst gap 4/12/28 s for f = 1/2/3, 180 s at n=13 f=4 — [AREA2 §Round 3](crash-fault-results/AREA2-RESULTS.md) |
| 4. Voter attacks, n = 13 | 27/27 (and 9/9) blocked, all 13 validators agree — [AREA3 §Round 3](malicious-results/AREA3-RESULTS.md) |
