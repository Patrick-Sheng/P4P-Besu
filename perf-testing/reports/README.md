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
