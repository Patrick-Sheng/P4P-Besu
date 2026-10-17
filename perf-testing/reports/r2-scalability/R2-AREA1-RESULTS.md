# Round 2 — Area 1: Scalability ladder

Election-scale test plan, Section 5. Run 2026-10-15 on the upgraded VM.

## Environment

| Item | Value |
| --- | --- |
| VM | VirtualBox, 6 vCPU (Intel Core Ultra 5 125H host), 15.6 GiB RAM, no swap, 200 GB disk |
| Besu | 24.12.0, IBFT 2.0, 2 s blocks, BONSAI, SEQUENCED pool (`--profile=ENTERPRISE`) |
| Per node, every n | 1 GiB heap (`-Xmx1024m`), 1.8 GB cgroup cap, `--tx-pool-max-size=16384` |
| Load | `loadgen/p4p-gen.js`: open-loop fixed rate, one fresh registered voter per vote, sent round-robin to all validators |
| Steps | 5 min idle baseline, then 5 min each at 50 / 100 / 150 / 200 votes/s; stop at the first unsustainable step |
| Sustainable | success ≥ 99.9 %, p95 ≤ 6 s, pool not trending up, mean block time 2.0–2.2 s |

All validators, the load generator, the desktop session and the editor share the same 6 vCPUs.

## Results log

| n | Max sustainable (votes/s) | p95 at 100 votes/s (s) | Block time at 100 votes/s (s) | Idle Besu CPU (% of 1 vCPU) | Idle RSS (GiB) | Round changes | First resource to saturate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | **150** | 2.84 | 2.000 | 19 | 1.6 | 0 | CPU (tail latency at 200/s, host 70 % busy) |
| 7 | **< 50** | — | — | 53 | 2.8 | 0 | CPU (host 79 % busy at 50/s, p95 6.6 s) |
| 10 | not measured | — | — | 89 | 4.3 | 1 | Validator 8 deadlocked during registration (see below) |
| 13 | idle only | — | — | 154 | 5.7 | 0 | — |
| 16 | idle only | — | — | 373 | 11.7 | 0 | CPU + memory while idle (block time 2.244 s, 1.9 GB RAM left) |
| 19 | not run | — | — | — | ~14 projected | — | Memory: idle RSS would exceed available RAM |

**Breaking point: n = 7** under the plan's stop rule (max sustainable below 50 votes/s). Validators 10, 13 and 16 were
added afterwards (user decision) with idle baselines only, to give the curve fit five points.

### n = 4 detail

| Step | Success | p50 / p95 / p99 (s) | Block time (s) | Host CPU | Besu RSS (all nodes) |
| --- | --- | --- | --- | --- | --- |
| idle | — | — | 2.000 | 5 % | 1.6 GB |
| 50/s | 100 % | 1.55 / 2.50 / 3.32 | 2.000 | 35 % | 2.5 GB |
| 100/s | 100 % | 1.82 / 2.84 / 3.15 | 2.000 | 48 % | 4.5 GB |
| 150/s | 100 % | 2.25 / 3.42 / 4.10 | 2.000 | 62 % | 5.2 GB |
| 200/s | 100 % | 2.61 / **9.01** / 17.07 | 2.033 | 70 % | 6.3 GB |

At 200 votes/s every vote still succeeded and the pool did not grow; a tail of slow blocks pushed p95 over 6 s.
Round 1 measured 130+ votes/s on 4 validators; round 2 sustains 150.

## Curve fits (idle baseline vs n)

Idle Besu CPU is pure consensus overhead: IBFT runs a full round for every empty 2 s block.

| Metric | Points | Linear R² | Quadratic R² | Quadratic fit |
| --- | --- | --- | --- | --- |
| Idle Besu CPU (% of 1 vCPU) | n = 4–13 | 0.971 | **0.996** | 0.878 n² − 0.26 n + 7.5 |
| Idle Besu CPU | n = 4–16 | 0.825 | 0.969 | (n = 16 saturated, see below) |
| Idle RSS (MB) | n = 4–13 | **0.999** | 0.999 | linear: ≈ 475 MB per validator |

- **CPU grows quadratically with n.** Up to n = 13 the fit is almost pure n² with a near-zero linear term, and CPU per node
  rises linearly (4.8 % → 7.6 % → 8.8 % → 11.8 %). That is the expected O(n²) IBFT message cost: every validator
  processes a prepare and a commit from every other validator per block.
- **Memory grows linearly** (~475 MB per validator, idle) until n = 16, where per-node RSS jumps to 750 MB.
- **n = 16 is saturated even with no load:** 88.7 % host CPU, idle block time 2.244 s (outside the 2.0–2.2 s band),
  1.9 GB RAM left. Its CPU point (373 %) sits well above the n² trend because contention for 6 vCPUs adds to the
  message cost.

**Caveat (plan Section 5):** all n validators share 6 vCPUs, so these are lower bounds for a real multi-host deployment.
On this VM, CPU contention between co-located JVMs, not IBFT message complexity alone, ends the ladder.

## Findings that affected the method

1. **Caliper's receipt polling stalled the chain (run invalidated).** The first attempt stalled at n = 4, 100 votes/s.
   In Besu 24.12.0, `eth_getBlockReceipts` re-reads the block's whole receipt list once per transaction (O(n²) per
   block), which starved the two validators the Caliper workers polled until the chain lost quorum. Round 2 now tracks
   confirmations with `eth_getBlockByNumber` + one `eth_getLogs` per block. Archived in `invalid/`.
2. **Host CPU slowdown.** For about an hour the VM's single-thread speed fell to roughly a third (a Python reference
   loop went from 1.15 s to 4.3 s; idle chain CPU from 28 % to 80 %), consistent with Windows scheduling the VM onto
   efficiency cores. Fixed on the host (Best performance power mode, VirtualBox efficiency mode off). Every run now
   records a CPU probe and refuses to start above 2.5 s; the sampler logs a probe every minute during runs.
3. **A 384 MiB heap is too small for sustained load.** Heap after GC climbs ~15–20 MB/min under load; at n = 4, 100 votes/s
   it reached the ceiling after ~2.5 min, causing 1.2–1.6 s full GCs on every validator (block time 3.7 s, p95 101 s).
   This matches round 1's "memory growth to the per-node cap". The ladder was rerun with a 1 GiB heap (user decision).
   Archived in `heap384/`.
4. **Besu 24.12.0 deadlock at n = 10.** During registration, validator 8 stopped importing (block 199 vs 220). Thread dumps
   show a three-way lock cycle: a network thread holds `SyncState` and waits for the BFT processor to stop; the BFT
   processor waits for the `MainnetBlockImporter` lock; a block-propagation thread holds that lock and waits for
   `SyncState`. It is triggered when a validator briefly falls behind under CPU contention and flips into sync mode.
   The node stays wedged until restarted. `n10-*/threaddump-v8.txt`.

## Files

- `n<N>-<timestamp>/steps.csv`: one row per phase (idle / each load step) with every metric above
- `n<N>-<timestamp>/samples.csv`: 5 s samples (host CPU, iowait, memory, Besu RSS and CPU, pool, height, CPU probe)
- `n<N>-<timestamp>/step-<rate>.csv`: per-vote send/confirm times and status; `.summary.json` per step
- `r2-area1-index.log`: one line per size
