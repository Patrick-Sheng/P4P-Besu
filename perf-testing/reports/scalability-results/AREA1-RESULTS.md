# Area 1 — Scalability results (rounds 1–3; round 1 run 2026-10-08)

Host: single dev box, 4 cores, 7.7 GB RAM, no swap. All validators, Caliper and
the desktop share this machine. Besu 24.12.0, IBFT 2.0, blockperiod 2 s.
Workload: `castVote` from distinct pre-registered voters, 30 s per TPS step, 2 Caliper workers,
sends round-robined across all validators. Ladder stops after 2 consecutive rounds below 80% of target.

Driver: `scripts/run-area1.sh` → `scripts/area1-sweep.sh` (per-run dirs below hold
`summary.csv`, `resources.csv`, per-round Caliper logs/HTML, raw latency NDJSON).

## Current findings (all rounds, updated 2026-10-17)

| Round | Host | What was measured | Result |
| --- | --- | --- | --- |
| 1 (8 Oct) | 4 vCPU, 7.7 GB | Load ladder at n = 4, 7, 10 | n=4 ≈ 120–135 TPS, n=7 ≈ 80 TPS; n=10 OOM-killed at 50 TPS (152 MB heaps) |
| 2 (15 Oct) | 6 vCPU, 15.6 GiB | Load ladder at n = 4, 7; idle at 10, 13, 16 | n=4 sustains 150 votes/s; n=7 failed 50 votes/s (p95 6.6 s); idle CPU ≈ 0.88·n² ([R2 write-up](../r2-scalability/R2-AREA1-RESULTS.md)) |
| **3 (17 Oct)** | 6 vCPU, 15.6 GiB | **Light-load ladder at n = 4, 7, 10, 13; measured agreement time at n = 4–16** | See below |

- **Latency at light load (round 3, 1 GiB heap, 65,536 pool):** n = 4 and 7 sustain 10, 25 and 50 votes/s
  (p95 2.2–3.0 s). **n = 10 sustains 25 votes/s** (p95 3.9 s) and fails 50 (p95 11.4 s, CPU 96 %).
  **n = 13 sustains 10 votes/s** (p95 3.5 s); at 25 votes/s the VM ran out of memory (Besu ≈ 13 GB) and three
  validators were OOM-killed.
- **Agreement time is far below the projection.** Measured with a 100 ms block period (time between
  blocks minus the 100 ms floor, median): **≈ 16 ms at n = 4, 77 ms at 7, 120 ms at 10, 220 ms at 13,
  560 ms at 16**, idle — against projected 0.2, 0.6, 1.2, 2.1 and 3.1 s. It grows faster than linearly with n.
- **Load matters only once the host is busy:** 10 votes/s adds nothing at n = 4 and 7, ~100 ms at n = 10,
  and ~0.8 s at n = 13, where it pushes the VM to 99 % CPU.
- **On one 6-vCPU VM, CPU contention (n ≥ 10) and then memory (n = 13 under load) set the limit**, not IBFT
  message cost; all figures are lower bounds for one validator per machine.
- **No vote failed** in any step that the host could hold; the only failures (n = 13 at 25 votes/s, 94.4 %
  success) came from validators being OOM-killed.

## Round 1 results (2026-10-08)

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

## Round 3 results (2026-10-17): light-load ladder and agreement time

Plan: *Round 3 Test Plan: Validator Count Gaps* (Tests 1 and 2). Host: round 2 VM (6 vCPU, 15.6 GiB, no swap),
Besu 24.12.0, IBFT 2.0. Runs: `round3/` (ladder) and `round3-agreement/` (agreement time); every launch is logged
in `../round3-index.log`.

### Test 1: latency ladder (10 / 25 / 50 votes/s, 5 min each, fresh chain per size)

Settings as round 2: 1 GiB heap and 1.8 GB cgroup cap per validator, `--tx-pool-max-size=65536`, 2 s blocks,
load from `loadgen/p4p-gen.js` (fixed rate, one fresh voter per vote, sent round-robin to all validators).
Driver `scripts/r2-area1-ladder.sh`, run for every size via `scripts/run-r3.sh`.

| n | Votes/s | Success | p50 (s) | p95 (s) | p99 (s) | Mean block (s) | Round changes | Host CPU | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 10 | 100 % | 1.29 | 2.21 | 2.40 | 2.000 | 0 | 16 % | sustainable |
| 4 | 25 | 100 % | 1.27 | 2.19 | 2.36 | 2.000 | 0 | 16 % | sustainable |
| 4 | 50 | 100 % | 1.30 | 2.21 | 2.35 | 2.000 | 0 | 19 % | sustainable |
| 7 | 10 | 100 % | 1.30 | 2.21 | 2.39 | 2.000 | 0 | 19 % | sustainable |
| 7 | 25 | 100 % | 1.35 | 2.25 | 2.43 | 2.000 | 0 | 27 % | sustainable |
| 7 | 50 | 100 % | 1.91 | 3.04 | 3.44 | 2.000 | 0 | 65 % | sustainable |
| 10 | 10 | 100 % | 1.71 | 2.79 | 4.18 | 2.000 | 0 | 55 % | sustainable |
| 10 | 25 | 100 % | 2.65 | 3.94 | 4.48 | 2.000 | 0 | 92 % | sustainable |
| 10 | 50 | 100 % | 5.13 | **11.41** | 13.25 | 2.140 | 0 | 96 % | unsustainable (p95) |
| 13 | 10 | 100 % | 2.06 | 3.53 | 5.61 | 2.013 | 0 | 75 % | sustainable |
| 13 | 25 | **94.4 %** | 49.5 | **259.6** | 271.4 | **8.063** | **141** | 94 % | failed: memory exhausted |
| 13 | 50 | — | — | — | — | — | — | — | not run (stops after first failed step) |

Idle baselines (5 min): host CPU 5 % (n = 4), 8 % (7), 19 % (10), 28 % (13); Besu RSS 1.7, 2.8, 4.2 and 6.3 GB.

- **Max sustainable at light load: n = 4 and 7 ≥ 50 votes/s, n = 10: 25 votes/s, n = 13: 10 votes/s.**
- **n = 13 at 25 votes/s ran the VM out of memory.** Total Besu RSS reached ≈ 13 GB of 15.6 GB; validator 9 was
  killed by systemd-oomd at 05:38 and validators 2 and 3 by the kernel OOM killer at 05:39 and 05:48 (all
  contained: the editor and VM were unaffected). The step's latency and 141 round changes follow from losing
  three of 13 validators. The run's index line reads "no load step passed"; that wording is a driver bug, as the
  10 votes/s step did pass. The watchdog did not abort the step (its per-sample checks of 13 nodes were too slow
  at 94 % CPU); kernel and cgroup containment did the job instead.
- **n = 7 passed 50 votes/s this time** (p95 3.0 s, CPU 65 %), where round 2 failed it (p95 6.6 s, CPU 79 %). Same
  settings; the difference is the host's state on the day. Round 2's "n = 7 breaking point" was at the margin.
- No Besu lock-up occurred in Test 1 (round 2 had one at n = 10).

### Test 2: agreement time (100 ms block period, 5 min per size after 60 s settling)

With Besu's test-only `xblockperiodmilliseconds: 100` (genesis `ibft2`, round timer 4 s), a new round starts
100 ms after the previous block, so **time between blocks = 100 ms + agreement time** (proposal, prepare, commit,
import). Block timestamps have 1 s resolution, so intervals come from the validators' millisecond log timestamps.
Driver `scripts/r3-agreement.sh`; results in `round3-agreement/agreement.csv` and
`round3-agreement/agreement-recomputed.csv`.

| n | Load | Blocks in 5 min | Median interval | p95 interval | **Agreement (median − 100 ms)** | p95 − 100 ms | Projected | Host CPU |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | idle | 2,250 | 116 ms | 141 ms | **16 ms** | 41 ms | 0.2 s | 17 % |
| 7 | idle | 1,645 | 177 ms | 246 ms | **77 ms** | 146 ms | 0.6 s | 52 % |
| 10 | idle | 929 | 222 ms | 374 ms | **122 ms** | 274 ms | 1.2 s | 65 % |
| 13 | idle | 715 | 323 ms | 463 ms | **223 ms** | 363 ms | 2.1 s | 84 % |
| 16 | idle | 256 | 658 ms | 945 ms | **558 ms** | 845 ms | 3.1 s | 96 % |
| 4 | 10 votes/s | 2,125 | 125 ms | 155 ms | 25 ms | 55 ms | — | 25 % |
| 7 | 10 votes/s | 640 | 175 ms | 248 ms | 75 ms | 148 ms | — | 58 % |
| 10 | 10 votes/s | 816 | 327 ms | 663 ms | 227 ms | 563 ms | — | 90 % |
| 13 | 10 votes/s | 265 | 1,092 ms | 1,660 ms | 992 ms | 1,560 ms | — | 99 % |

No IBFT round changes in any Test 2 run.

- **Measured agreement time is 6–13× below the projection** at every size (16 ms vs 0.2 s at n = 4; 223 ms vs
  2.1 s at n = 13). The projection overestimates the consensus cost on this setup by roughly an order of magnitude.
- **It still grows faster than linearly** (16 → 77 → 122 → 223 → 558 ms), consistent with IBFT's O(n²) message
  count plus CPU contention between co-located validators: at n = 16 the VM is at 96 % CPU while idle.
- **A light load (10 votes/s) leaves agreement time unchanged at n = 4 and 7**, adds ~100 ms at n = 10 and ~0.8 s at
  n = 13, where it saturates the VM (99 % CPU). The n = 13 loaded figure measures CPU contention, not IBFT.
- With the normal 2 s block period, agreement fits comfortably inside the block time up to at least n = 13 at light
  load, which matches Test 1 (2.000–2.013 s blocks).

**Method notes.** The n = 4, 7, 10, 13 idle rows use validator 1's consensus log lines; the other rows take each
block's earliest appearance across all validators (`scripts/r3-agreement-recompute.py`, full logs kept in
`node-logs-full/`). Where both were available the medians agree to within 1–3 %. Means are not used: the host
paused the whole VM three times during Test 2 (≈ 55 s at n = 10 idle, 28 s at n = 13 idle, 182 s at n = 7 loaded;
all processes, including the resource sampler, went silent), which inflates means but not medians or p95.
The first n = 10 loaded attempt hit the Besu 24.12.0 sync/import deadlock (validator 3's BFT processor blocked on
`SyncState`; thread dump in `round3-agreement/n10-r10-20261017-065231/`) and was rerun once as the plan says;
the rerun completed. The 16 idle and n = 13 loaded runs had too few measurable intervals for tight percentiles
(255 and 264) and saturated the CPU, so read them as upper bounds.
