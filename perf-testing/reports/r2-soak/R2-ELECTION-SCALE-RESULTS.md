# P4P Round 2: Election-Scale Test Results

Hyperledger Besu IBFT 2.0 e-voting (P4P Project 68). Tests run 2026-10-15 to 2026-10-16 against the
*P4P Election-Scale Test Plan*. This document covers every area, what was changed from the plan and why,
and how each test went. Area 1 has its own detailed write-up: [`../r2-scalability/R2-AREA1-RESULTS.md`](../r2-scalability/R2-AREA1-RESULTS.md).

## 1. Summary

| Area | Planned | What ran | Result |
| --- | --- | --- | --- |
| **1. Scalability** | Validator ladder 4 → 19+ until the network breaks | n = 4 and 7 with load; n = 10, 13, 16 idle baselines | **Breaking point n = 7** (CPU contention). n = 4 sustains **150 votes/s**. Idle consensus CPU grows **≈ n²**; memory ≈ 475 MB per validator |
| **4. Throughput soak** | 5M votes at a sustained rate, 20 rounds | **1,000,000 votes** on a chain with **3.3M registered voters**: 2 rounds at 120 votes/s, 3 at 90 votes/s | **Zero votes lost**, 100 % success every round, heap flat. Latency and block-time criteria **not met** in 4 of 5 rounds, driven by host CPU starvation and two Besu stalls |
| **3. Malicious voters** | 27 attacks at 1M, 3M, 5M + mass double vote | 27 attacks at 1M + mass double vote (1,000 voters) | **27 / 27 blocked**; **1,000 / 1,000 double votes reverted**, tallies unchanged |
| **2. Fault tolerance** | Crash f, quorum loss on full state | Both tests on the 1M-vote chain at 30 votes/s, shortened holds | **Live with f down, 0 failed votes**; **safe halt, no fork, 0 votes lost** (5,406 sent during the halt, all confirmed). Recovery: first block **286 s** after quorum restored; rejoin **48 s** |
| **Verification** | Heads agree, exact tallies | Full scan of all 3.3M voters | **Passed**: heads agree; tallies exact over all 1,205,694 voted voters + 28 attack votes; 0 of 1,155,705 confirmed votes missing |

**Bottom line.** At election-scale state the system stayed **correct** throughout: no lost votes, no fork,
no divergent tallies, every attack blocked, safe halt and full recovery from quorum loss. What did **not**
hold up on this single VM is **steady performance**: the host repeatedly halved the VM's CPU for minutes at a
time, and under that pressure Besu 24.12.0 twice stopped producing blocks until validators were restarted.
The 5M-vote soak was cut to 1M by decision once that pattern was clear.

## 2. Environment and configuration

| Item | Value |
| --- | --- |
| VM | VirtualBox on a Windows laptop (Intel Core Ultra 5 125H), **6 vCPU, 15.6 GiB RAM, no swap, 200 GB disk** |
| OS / Java | Ubuntu 24.04.4, OpenJDK 21.0.12.1 |
| Besu | 24.12.0, IBFT 2.0, chainId 1337, 2 s blocks, BONSAI, SEQUENCED pool (`--profile=ENTERPRISE`, as round 1) |
| Contract | `VotingSystem.sol` unchanged (no batch registration, by decision); 3 candidates |
| Soak chain | 4 validators, **1 GiB heap**, 2.6 GB cgroup cap each, **`--tx-pool-max-size=65536`**, metrics enabled |
| Load generator | `loadgen/p4p-gen.js` (new): deterministic voter keys `keccak256(seed, i)`, voter *i* votes for *i* mod 3, open-loop fixed rate, sends round-robin to all validators, per-transaction CSV |
| Monitoring | Prometheus + Grafana (dashboards 16455, 1860) + node_exporter; collector CSV (Section 11 of the plan); 5–15 s sampler with an in-run CPU-speed probe |
| Safety | Each validator in its own memory-capped systemd unit; watchdog for crash / OOM / stall / stuck node / memory pressure |

### Deviations from the plan, and why

| Change | Reason | Decided by |
| --- | --- | --- |
| Caliper replaced by `p4p-gen.js` | Voters are `msg.sender`, so 5.5M signing keys; Caliper loads them all into each worker. Later also: Caliper's `eth_getBlockReceipts` polling is O(n²) in Besu 24.12 and stalled the chain on its own | Plan allows it; tool bug found in testing |
| Area 1 heap 384 MiB → **1 GiB** | 384 MiB filled under sustained load and caused 1.5 s full GCs | User |
| Area 1 extended past the stop rule with idle-only points (n = 10, 13, 16) | Two loaded points are too few for a curve fit | User |
| Soak target 5M → **2.8M** → **1M** votes; seeding 5.5M → **3.3M** | Time; then repeated host-induced aborts | User |
| Soak heap 2 GiB → **1 GiB** | 2 GiB heap + ~1.2 GB off-heap per node does not fit 4 nodes in 15.6 GB; 1 GiB also *doubled* calibrated capacity | User |
| Soak rate 150 → 120 → **90 votes/s** | Host CPU instability (section 6.3) | User |
| Slow-block / pool-growth periods logged as **episodes**, not aborts | Host-induced; abort kept for pool > 50,000, lost votes, hash mismatch, crash | User |
| Warm-up ramp before each soak start (30/60/90 votes/s, "round 0") | Freshly started JVMs need ~2× CPU for a few minutes | User |
| Rolling validator restarts during **seeding** only (memory > 2.5 GB, or stuck node) | Off-heap memory grows with DB size; seeding is unmeasured | Operational |
| Area 3 checkpoints at 2M / 2.8M dropped | Soak ended at 1M | User |
| Area 2 at **30 votes/s**, crash hold **5 min** (plan 10), quorum hold **3 min** (plan 5) | Simplified finish | User |

## 3. Timeline (UTC)

| When | What |
| --- | --- |
| 15 Oct 02:40–06:50 | Area 1 ladder; two invalid attempts (Caliper polling bug; host slowdown), 384 MiB run superseded |
| 06:51–07:00 | Smoke test passed |
| 07:01–17:22 | Seeding 3.3M voters (paused 07:08–11:31 offline), snapshot saved |
| 17:22–22:11 | Calibration (2 GiB heap, then 1 GiB); host paused the VM for ~4 h in between |
| 23:53–02:00 | Soak attempts at 150 / 120 votes/s aborted by host slowdowns; diagnosis |
| 16 Oct 02:18–06:30 | Soak to 1M votes (rounds 1–5, with resumes) |
| 06:30–06:54 | Area 3 checkpoint at 1M (rerun after a tooling error) and mass double vote |
| 06:55–07:24 | Area 2 crash and quorum-loss tests |
| 09:48–11:25 | Verification (attempts 1–3 interrupted: VM power-off, then two verifier bugs); passed at 11:25 |

## 4. Area 1: Scalability ladder

Full details, tables and the four method findings: [`R2-AREA1-RESULTS.md`](../r2-scalability/R2-AREA1-RESULTS.md).

| n | Max sustainable | Idle Besu CPU (% of 1 vCPU) | Idle RSS | Note |
| --- | --- | --- | --- | --- |
| 4 | **150 votes/s** (p95 2.8 s at 100/s) | 19 | 1.6 GB | Round 1: 130+ |
| 7 | **< 50 votes/s** (p95 6.6 s at 50/s) | 53 | 2.8 GB | CPU-bound: 79 % host CPU |
| 10 | not measured | 89 | 4.3 GB | Validator deadlock during registration |
| 13 | idle only | 154 | 5.7 GB | |
| 16 | idle only | 373 | 11.7 GB | Saturated while idle (2.24 s blocks) |

Idle consensus CPU fits **0.88 n²** (R² 0.996 for n ≤ 13, vs 0.971 linear), the expected IBFT message
cost. On one 6-vCPU host, CPU contention between co-located validators ends the ladder at n = 7.

## 5. Shared setup

### Smoke test (Section 6.2): passed
10,000 registrations + 10,000 votes at 50/s: 100 % success, tallies **3334 / 3333 / 3333 exactly as expected on all
4 nodes**, collector and Prometheus (5/5 targets) working. The disk projection could not be measured at that
size (RocksDB pre-allocates); it was redone from seeding data (below).

### Seeding (Section 6.3)
- **3,300,000 voters registered**, 0 reverted, mean block time 2.064 s, 134–243 registrations/s (single admin account,
  500 transactions in flight; a larger window was slower).
- Per validator after seeding: **≈ 2.75 GB** (≈ 870 B per registration). Snapshot 11 GB, 112 s.
- 10 validator restarts during seeding (9 memory, 1 stuck node): Besu's **off-heap memory grows with database size**
  (~1–1.2 GB per node at 3.3M voters, not bounded by `-Xmx`), and G1 expands the committed heap toward `-Xmx`
  although live data is only ~0.4 GB.

### Calibration (Section 6.4), seeded 3.3M-voter state, 5 min per step

| Rate (votes/s) | 1 GiB heap: p95 / block time | Verdict | 2 GiB heap: p95 / block time | Verdict |
| --- | --- | --- | --- | --- |
| 50 | 3.2 s / 2.026 s | sustainable | 5.2 s / 2.074 s | sustainable |
| 75 | 2.5 s / 2.000 s | sustainable | 3.7 s / 2.000 s | sustainable |
| 100 | 2.6 s / 2.000 s | sustainable | **7.3 s** / 2.097 s | unsustainable |
| 125 | 2.8 s / 2.000 s | sustainable | — | — |
| 150 | 3.0 s / 2.000 s | **sustainable (max)** | — | — |
| 200 | **6.2 s** / 2.054 s | unsustainable | — | — |

All steps: 100 % success. **The smaller heap doubled capacity**: 150 vs 75 votes/s. Fresh-chain capacity at n = 4
was also 150 votes/s, so a 3.3M-voter state did not lower the calibrated maximum.

## 6. Area 4: Throughput soak

### 6.1 Per round

Every round's 200,000 voters are accounted for; "resumed" rounds skip voters already confirmed in an interrupted
attempt (a scan of on-chain voter state before resuming).

| Round | Cumulative | Rate | Votes in final run | Success | Throughput | p50 / p95 / p99 (s) | Mean block | Heap after GC |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 200k | 120 | 200,000 | 100 % | 118.0 | 3.8 / **35.0** / 42.9 | 2.579 s | 425 MB |
| 2 | 400k | 120 | 174,480 (resumed) | 100 % | 119.5 | 4.5 / **11.7** / 15.3 | 2.490 s | 411 MB |
| 3 | 600k | 90 | 58,253 (resumed) | 100 % | 89.7 | 2.2 / **3.6** / 4.2 | **2.000 s** | 352 MB |
| 4 | 800k | 90 | 28,623 (resumed) | 100 % | 89.4 | 3.1 / **6.8** / 8.4 | 2.174 s | 344 MB |
| 5 | 1M | 90 | 200,000 | 100 % | 89.2 | 3.1 / **9.3** / 28.5 | 2.271 s | 441 MB |

Each soak start was preceded by a warm-up (30/60/90 votes/s, 3 min each): every warm-up step 100 % success.

### 6.2 Pass criteria (Section 12)

| Criterion | Result |
| --- | --- |
| Success ≥ 99.9 % every round | **PASS**: 100 % in every round and every warm-up; **0 dropped, 0 send errors** |
| Heap after GC flat | **PASS**: 344–441 MB on a 1 GiB heap, no upward trend |
| Zero swap | **PASS**: none configured, none used |
| Disk | **PASS**: final DB ≈ 2.6 GB per validator (compaction); 136 GB free |
| p95 ≤ 6 s every round | **FAIL** in rounds 1, 2, 4, 5 (only round 3 passed) |
| Block time 2.0–2.2 s every round | **FAIL** in rounds 1, 2, 5; pass in 3, 4 |
| Throughput within 10 % of round 1 | Not comparable: the rate was lowered to 90/s for host reasons |

The latency and block-time failures line up with the episodes below.

### 6.3 Why the soak was interrupted

Ten soak runs were needed to reach 1M votes. Every interruption is logged in `r2-index.log`.

| Cause | Occurrences | Evidence |
| --- | --- | --- |
| **Host CPU starvation** | Repeatedly from ~00:20 on 16 Oct | In-run CPU probe went from ~100 ms to 500–1,430 ms (and to 7–12 s freezes in a loaded test) while the VM was not yet saturated. At 150 and 120 votes/s the network fell behind; at 90/s a 15-minute episode in round 4 still pushed the pool to the 50,000 safety cap |
| **Cold start** | Every soak start | Freshly started validators need ~2× CPU for the first minutes; without warm-up a 120/s start spiralled (13 s blocks). Fixed with the warm-up ramp |
| **Besu 24.12.0: validator deadlock** | 04:00, round 3 | Validator 2's BFT processor blocked on `MainnetBlockImporter` while another node synced a 5,407-transaction catch-up block; the others escalated to IBFT round 5; chain halted 3 min. Same lock cycle as Area 1 at n = 10 |
| **Besu 24.12.0: validators stop participating after sync** | 06:38, during the attack checkpoint | Validators 1 and 4 fell behind, imported block 15,991 through the sync path and **stopped taking part in IBFT** (sync status stops the BFT coordinator); 2 of 4 cannot reach quorum; chain halted until restart |

Also observed: **validator 2's JVM segfaulted inside RocksDB's native library** (`librocksdbjni`, SIGSEGV) during a
graceful shutdown at 03:04 on 16 Oct, while the chain was being stopped after the round 2 abort. Its data was intact
on restart and the soak resumed normally, but it is another Besu 24.12.0 robustness issue under heavy state.

**Episodes recorded** (`episodes.csv`, run continued): 5 slow-block periods (≤ 43 blocks per 5 min) and one
10-minute pool-growth period in round 4 (logged each minute, 8 entries), all with CPU-probe evidence of host
slowdown except two in round 3 (probe 130–177 ms), where 120 votes/s itself was too much for the host's
reduced capacity.

In every case: **no fork, no divergent state, no vote lost**. Restarting the validators recovered the chain each
time (chain data intact, including after an unclean VM power-off).

## 7. Area 3: Malicious voters at scale

### Attack replay at 1M votes: **27 / 27 blocked**

| Attack | Blocked | How |
| --- | --- | --- |
| Double vote | 9 / 9 | Second `castVote` from the same voter reverted by the contract; tally +1 exactly once |
| Equivocation | 9 / 9 | Two conflicting same-nonce votes to two different validators: exactly one included |
| Replay | 9 / 9 | Re-broadcast of a mined transaction rejected (`nonce too low`), tally unchanged |

Every attempt also checked that **all 4 validators report identical tallies and block hash**. The scripts were
adapted for concurrent traffic: tally changes are netted against `VoteCast` events from other voters, so
checks are exact under load; with no other traffic the check is identical to round 1's.

**Traffic conditions, stated precisely:** attacks 1–8 ran alongside **real 90 votes/s on-chain traffic**
(40,094 confirmed votes, p95 33.5 s as the chain degraded before the 06:38 stall). Attacks 9–27 ran on the
1M-vote state after a restart; their background traffic re-used voters that had already voted and was
rejected at submission (12,056 `nonce too low`), so **blocks were effectively idle** for those 19.

The first 1M attempt (06:13) is **invalid**: the scripts could not find the contract ABI (path resolved relative
to the new state directory), so no attack was sent. It is kept as `ATTACKS-INVALID.txt` in
`soak-20261016-053204/`.

Round 1 comparison: round 1 blocked 27 / 27 on an idle, near-empty chain (9 at each of n = 4, 7, 10).
Round 2 blocks 27 / 27 at n = 4 on a chain holding 3.3M registrations and 1M votes.

### Mass double vote: **1,000 / 1,000 reverted**
1,000 random soak voters (0–1M), each first confirmed in `Voted` state, each sent a second vote for a different
candidate: **all 1,000 reverted**, tallies **389,920 / 389,904 / 389,898 before and after**, 0 send errors.

## 8. Area 2: Crash and fault tolerance on full state

Run on the 1M-vote chain at 30 votes/s from reserve voters (3.3M-voter state). Votes sent only to validators
that stay up.

### Crash f = 1 (validator 4, SIGKILL, 5 min)

| Measure | Round 1 (n = 4, empty chain) | **Round 2 (1M votes)** |
| --- | --- | --- |
| Live with f down | 23 blocks / 60 s | **111 blocks / 300 s** (≈ 2.7 s per block) |
| Failed votes | 0 | **0 of 18,000** |
| p95 before / down / after | 2.3 / 4.2 / 2.3 s | **4.0 / 5.2 / 5.1 s** |
| Rejoin to chain head | 9 s | **48 s** |

### Quorum loss (validators 3 + 4, SIGKILL, 3 min)

| Measure | Round 1 | **Round 2 (1M votes)** |
| --- | --- | --- |
| Halt on quorum loss | Safe halt | **Safe halt**: 0 blocks during the hold; validators 1 and 2 at the same height and hash |
| Fork | None | **None** |
| Recovery: first block after quorum restored | 135–266 s | **286 s** |
| Pool backlog cleared | — | **454 s** after restart (peak 5,431) |
| Restarted nodes rejoin | — | 3 s |
| Votes lost during the halt | **2,340 of 7,503 (31 %) silently evicted** at the default 4,096 pool | **0 of 5,406**: every vote sent during the halt was confirmed |
| Failed votes overall | — | **0 of 18,000** |

**The enlarged pool (65,536) fixes round 1's silent vote loss.** Recovery after quorum loss is still slow
(minutes), for the same reason as round 1: IBFT round timers double while quorum is gone, and the chain resumes
only when a quorum lands in the same round.

## 9. Verification: **passed**

Run `verify-20261016-102811`, chain idle (pools empty), all 3,300,000 voter indices scanned (57 min).

| Check | Result |
| --- | --- |
| All 4 validators report the same head | **PASS**: block 18,251, identical hash |
| On-chain tallies = deterministic candidate (*i* mod 3) of **every voter in Voted state** + attack votes | **PASS, exact**: 401,920 / 401,904 / 401,898 |
| Every vote the generator saw confirmed is still in Voted state | **PASS**: 1,155,705 of 1,155,705 (0 missing) |
| State unchanged during the scan (tallies re-read at the end) | **PASS** |

**Reconciliation.** 1,205,694 voters are in Voted state:

| Source | Votes |
| --- | --- |
| Soak rounds 1–5 | 1,000,000 |
| Warm-up ramps (round 0, five soak starts) | 129,600 |
| Background traffic of the first 1M attack-checkpoint run | 40,094 |
| Area 2 (crash + quorum-loss tests) | 36,000 |
| **Total** | **1,205,694** |

Adding the 28 legitimate first votes cast by attack accounts (10 double-vote, 9 replay, 9 equivocation) gives
**1,205,722 = the sum of the on-chain tallies**. Mass-double-vote attempts (1,000) and attack second votes added nothing.

49,989 of those votes were confirmed on chain after an aborted run's generator had stopped watching, so they have
no confirmation row in the generator CSVs. This is exactly the number predicted from the resume scans
(6,977 in round 2 + 17,403 in round 3 + 25,609 in round 4). They are listed in
`verify-20261016-102811/verify-voted-without-ok-row.txt`. A tally check against generator rows alone therefore
reads 49,989 short by design (`talliesMatch: false` in `verify.json`); the voted-set check above is the complete one.

Verification tooling notes: three earlier attempts did not complete, none because of the chain. One was
interrupted by a VM power-off. Two failed in the verifier: first a missing retry, then reads pinned to the start
height, but **BONSAI keeps only about 512 blocks (~17 min) of historical state**, shorter than the scan. Any audit tool reading historical state on this chain must
finish within that window or read the latest state of an idle chain.

## 10. Key findings

1. **Correctness holds at election scale.** Across 1M votes on a 3.3M-voter chain: zero lost votes, zero forks,
   identical tallies on all validators, every attack blocked, safe halt and full recovery from quorum loss.
2. **The pool-size fix works.** Round 1 silently lost 31 % of votes accepted during an outage; with a 65,536 pool,
   0 of 5,406 were lost.
3. **Besu 24.12.0 has two liveness bugs that surface under sustained load:** a validator deadlock
   (`SyncState` / BFT processor / `MainnetBlockImporter` lock cycle, first seen in round 1's Area 4 and reproduced here
   at n = 4 and in Area 1 at n = 10) and validators that stop participating in IBFT after catching up through the
   sync path (new in round 2). With 4 validators, one or two affected nodes halt the chain until
   restarted. Both are worth raising upstream or checking against a newer Besu release.
4. **Capacity is CPU-bound on one host**, and smaller heaps helped: 1 GiB doubled capacity versus 2 GiB at the
   same state size. Idle consensus CPU grows with n², which caps a single-host network at n ≈ 7 under load.
5. **Memory:** off-heap (RocksDB) memory grows with database size, ~1–1.2 GB per node at 3.3M voters, on top
   of the heap. Plan production memory per validator as heap + ≥ 1.5 GB.
6. **Recovery is the weak point**, as in round 1: minutes after quorum loss (286 s), and 48 s for a crashed
   node to rejoin at 1M votes (9 s on an empty chain).
7. **BONSAI keeps only ~512 blocks (~17 min) of historical state.** Audits that read state "as of" a block must
   finish within that window, or run against the latest state of a quiesced chain (as the final verification does).
8. **A single laptop VM is not a stable platform for multi-hour soaks.** Host CPU throttling and VM freezes
   dominated the soak; all performance numbers are lower bounds for dedicated hardware.

## 11. Not covered

- The full 5M-vote soak (stopped at 1M by decision) and Area 3 checkpoints at 2M / 2.8M.
- Area 1 loaded measurements beyond n = 7 (CPU contention on one host).
- Rogue-validator (consensus message) attacks: still unbuilt (`ibft-fuzzing/`), as in round 1.
- Multi-host deployment and real network latency (out of scope in the plan).

## 12. Files and how to reproduce

| Path | Contents |
| --- | --- |
| `reports/r2-soak/r2-index.log` | One line per phase, abort and decision, in order |
| `reports/r2-soak/run-notes.md` | Git commit, Besu version, launch flags, genesis and VM specs per phase |
| `reports/r2-soak/soak-*/` | Per round: `soak-rNN.csv` (one row per vote), `checkpoints.csv`, `samples.csv`, `episodes.csv`, `soak-metrics.csv` (collector), attack logs |
| `reports/r2-soak/soak-attacks-*/` | Area 3 checkpoint: `attacks-1M.csv`, per-attack logs, thread dumps of the 06:38 stall |
| `reports/r2-soak/double-*/`, `area2-*/`, `verify-*/` | Mass double vote, Area 2, verification |
| `reports/r2-soak/calibrate-*/` | Calibration (1 GiB; `-heap2g-` = 2 GiB reference) |
| `reports/r2-soak/aborted-*/` | Interrupted attempts, kept as evidence |
| `reports/r2-scalability/` | Area 1 |

Drivers: `scripts/run-r2.sh <phase…>` (smoke, seed, calibrate, soak, soak-attacks, double, area2, verify) and
`scripts/run-r2-area1.sh`. Everything runs as memory-capped systemd user units; the seeded snapshot is in
`~/p4p-snapshots/seeded`.
