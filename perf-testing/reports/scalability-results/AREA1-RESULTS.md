# Area 1 — Scalability sweep results (2026-10-08)

Host: single dev box, 4 cores, 7.7 GB RAM, no swap. All validators, Caliper and
the desktop share this machine. Besu 24.12.0, IBFT 2.0, blockperiod 2 s.
Workload: `castVote` from distinct pre-registered voters, 30 s per TPS step, 2 Caliper workers,
sends round-robined across all validators. Ladder stops after 2 consecutive rounds below 80% of target.

Driver: `scripts/run-area1.sh` → `scripts/area1-sweep.sh` (per-run dirs below hold
`summary.csv`, `resources.csv`, per-round Caliper logs/HTML, raw latency NDJSON).

## Results

| n | target TPS | sent TPS | confirmed TPS | p50 (s) | p95 (s) | p99 (s) | failed |
|---|---|---|---|---|---|---|---|
| 4 | 10 | 10.1 | 9.4 | 1.49 | 2.45 | 2.66 | 0 |
| 4 | 25 | 25.1 | 23.8 | 1.65 | 2.63 | 2.83 | 0 |
| 4 | 50 | 50.1 | 48.2 | 1.86 | 3.16 | 3.59 | 0 |
| 4 | 100 | 99.7 | 96.2 | 2.36 | 4.03 | 4.87 | 0 |
| 4 | 150 | 135.1 | 121.3 | 4.24 | 5.89 | 6.48 | 0 |
| 4 | 200 | 113.9 | 105.7 | 5.35 | 9.20 | 9.86 | 0 (saturated) |
| 4 | 250 | 147.2 | 133.3 | 6.42 | 8.62 | 9.66 | 0 (saturated, ladder stopped) |
| 7 | 10 | 10.1 | 9.3 | 1.89 | 2.89 | 3.29 | 0 |
| 7 | 25 | 25.1 | 23.5 | 1.83 | 2.83 | 3.10 | 0 |
| 7 | 50 | 50.0 | 46.9 | 3.13 | 5.54 | 6.42 | 0 |
| 7 | 100 | 86.1 | 80.4 | 4.58 | 7.24 | 8.40 | 0 |
| 7 | 150 | 71.4 | 66.7 | 4.28 | 9.42 | 10.44 | 0 (saturated) |
| 7 | 200 | — | — | — | — | — | **CRASHED: VALIDATOR_OOM_KILLED** (validator6 hit 528 MB cgroup cap) |
| 10 | 10 | 10.0 | 8.8 | 4.70 | 7.63 | 8.73 | 0 |
| 10 | 25 | 24.5 | 21.4 | 4.55 | 7.35 | 8.50 | 0 |
| 10 | 50 | — | — | — | — | — | **CRASHED: VALIDATOR_OOM_KILLED** (validator6 hit 381 MB cap while registering voters) |

Block-time drift (n=4, blocks 5–491, across saturation): mean 0.004 s, max 1 s — block
production held its 2 s period; saturation showed up as latency, not missed blocks or failed txs.

Peak 1-min load average: n=4 8.5, n=7 15.9, n=10 **46.0** (on 4 cores).

## How to read this

- **Approximate sustained throughput on this host:** n=4 ≈ 120–135 TPS, n=7 ≈ 80 TPS, n=10 not determined (crashed at 50 TPS).
- **These are host-bound numbers, not IBFT limits.** From n=4 at ≥150 TPS onward the send rate
  itself fell below target: the load generator and every validator are contending for 4 cores.
  The n=10 latency at 10 TPS (p50 4.7 s vs 1.5 s at n=4, an idle network) is CPU/GC starvation
  of 10 JVMs with 152 MB heaps, not consensus cost. Read the n-to-n trend as an upper bound on
  degradation; the 300–500 TPS target remains untested and needs one machine (or VM) per validator.
- **No transaction failed in any completed round.** All losses are latency/throughput, not correctness.

## Crash history / labels

| Run | Outcome | Reason |
|---|---|---|
| n4 2026-10-06 (3 attempts) | VS Code crashed | Kernel OOM killed a besu JVM (≈1.2–1.35 GB RSS) inside VS Code's `snap.code` cgroup scope; systemd then killed the whole scope. 4 × `-Xmx2g`/`-Xmx512m` nodes + VS Code + Caliper > 7.7 GB, no swap. |
| n4-20261008-032842 | COMPLETED | — |
| n7-20261008-034602 | CRASHED in round 5 (200 TPS) | `VALIDATOR_OOM_KILLED` — validator6 exceeded its 528 MB cgroup cap; contained, host MemAvailable 2.2 GB |
| n10-20261008-035937 | CRASHED in round 2 (50 TPS, registration) | `VALIDATOR_OOM_KILLED` — validator6 exceeded its 381 MB cgroup cap; contained, host MemAvailable 2.1 GB |

Crash containment now used: each validator, the load generator and the watchdog run as separate
memory-capped `systemd --user` units in `p4p-perf.slice`, outside the editor's cgroup; the driver
runs detached as `p4p-area1`. `monitoring/resource-watchdog.sh` labels aborts with one of:
`HOST_MEMORY_PRESSURE`, `VALIDATOR_OOM_KILLED`, `VALIDATOR_JVM_HEAP_OOM`, `VALIDATOR_DOWN`,
`LOADGEN_OOM_KILLED`, `KERNEL_OOM`, `CONSENSUS_STALL`, `RPC_UNRESPONSIVE`, `NETWORK_NEVER_CAME_UP`,
`DRIVER_DIED`; every run's outcome is appended to `area1-index.log`.

## Harness changes behind these numbers

The earlier n=4 attempt plateaued at ~63 TPS sent for any target ≥100 because the connector made
~12 RPCs per vote (nonce lookup + 250 ms receipt polling). The connector now confirms via one
per-worker block watcher (`eth_getBlockReceipts`), signs fresh voters at nonce 0 without a lookup,
and spreads sends across all validators — n=4 now sends 99.7 TPS at a 100 target.
