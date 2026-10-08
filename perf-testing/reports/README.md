# Test results index

All runs on the dev box: 4 cores, 7.7 GB RAM, no swap; Besu 24.12.0, IBFT 2.0, 2 s blocks, native
network (no Docker). Numbers are host-bound — see each area's caveats.

| Area | Status | Summary | Headline |
|---|---|---|---|
| 1 — Scalability | Run (n=4 full, n=7 partial, n=10 partial) | [AREA1-RESULTS.md](scalability-results/AREA1-RESULTS.md) | Saturation ≈120–135 TPS at n=4, ≈80 TPS at n=7 (CPU-bound host); n=7 OOM at 200 TPS, n=10 OOM at 50 TPS; zero failed txs in completed rounds |
| 2 — Crash faults | Run (n=4 full, n=7 partial, n=10 blocked) | [AREA2-RESULTS.md](crash-fault-results/AREA2-RESULTS.md) | f crashed → live, resync 5–11 s, identical state; f+1 → halts, no fork; resume 135–266 s after quorum restored; 31% of votes sent during outage silently evicted (tx pool cap 4,096) |
| 3 — Malicious nodes | Run (n=4, 7, 10; client-level only) | [AREA3-RESULTS.md](malicious-results/AREA3-RESULTS.md) | Double-vote, equivocation, replay: 27/27 PASS, all validators agree; rogue-validator attacks not run |
| 4 — Throughput | **Not run** | [AREA4-STATUS.md](throughput-results/AREA4-STATUS.md) | Every config targets 300–1,200 TPS at n=7; host saturates at ≈80 TPS there |

Per-run detail lives in each area's run directories (`summary.csv`, `sweep.log`/`run.log`, timelines,
resource samples). Every run's outcome — including crashes and their labelled cause — is appended to
`scalability-results/area1-index.log`, `crash-fault-results/area2-index.log` and
`malicious-results/area3-index.log`.

Not yet covered anywhere: the 300–500 TPS target, n=13, Area 4, and IBFT wire-protocol fuzzing.
