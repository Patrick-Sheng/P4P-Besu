# Additional infrastructure-evaluation tests (T0–T3) — results (2026-10-14)

Plan: `docs/Additional Test Plan Infrastructure Evaluation.md`. Scripts written by Eason, run on
Patrick's VM using Patrick's harness. Every run folder below is in `reports/additional/`; the
outcome of every launch is in `additional-index.log`. T4 was not run (time), see "Not done".

All times are the VM clock (UTC).

## T0 — Environment (`env.txt`)

| Item | Value |
|---|---|
| Hypervisor | Oracle VirtualBox (Guest Additions 7.2.8 r173730; `systemd-detect-virt` = `oracle`) |
| VM allocation | 4 vCPU, 8 GB RAM (guest MemTotal 7.66 GB), **no swap** |
| VM disk | 40 GB dynamically allocated (≈30 GB used on host), `/dev/sda2`, 11 GB free at start |
| Host | Intel Core Ultra 5 125H (14 cores / 18 threads), 32 GB RAM, Windows; no other heavy load |
| Guest OS | Ubuntu 24.04, kernel 7.0.0-38-generic, cgroup v2 with memory controller |
| Software | Besu 24.12.0, OpenJDK 21.0.12.1, Node 22.23.2 |
| Besu config | `--profile=ENTERPRISE` (tx-pool = SEQUENCED, so `--tx-pool-max-size` applies, default 4096), `--data-storage-format=BONSAI`, IBFT 2.0, 2 s blocks |

**Decision point from the plan:** the VM gets 4 of the host's 18 threads and 8 of its 32 GB. This is
the same 4-core / 7.7 GB environment as Areas 1–4, so the throughput ceilings (≈120–135 TPS at n=4,
≈80 TPS at n=7) are a **lower bound** set by the VM allocation, not by the system. T4 would test
this; it was not run, so state it as a limitation.

Per-validator memory in each run is in its `run.log` ("Memory budget" line) and `run-meta.txt`.

## Code changes made during the runs (uncommitted; full diff in `code-changes.diff`)

Every run records these in `run-meta.txt` (git commit `2ab828d` + uncommitted files).

1. **`scripts/additional-fault.sh` — analysis steps moved into the 600 MB load unit.**
   `audit-tally.js` and `eviction-summary.js` ran inside the driver unit `p4p-additional`
   (MemoryMax 256 MB, same cap as the Area 1–4 drivers). At 10,000 votes the recount exceeded it
   and systemd OOM-killed the whole driver (journal: `p4p-additional.service: Failed with result
   'oom-kill'`, 16:09:14 and 16:18:48), which also cancelled the remaining repeats. Now run through
   the existing `run_load` helper like every other Node step. Measurement unchanged.
2. **`scripts/additional-fault.sh` — keep client logs on abort.** If a run aborted before
   `wait-load` finished, `caliper/reports/{latency,txlog}/*.ndjson` stayed behind and the next run's
   `rm -rf` deleted them. `finish()` now moves whatever was flushed into the run folder.
3. **`caliper/connector/voting-connector.js` — receipt watcher failure handling** (agreed with
   Patrick). Old behaviour: the first failed `eth_getBlockReceipts` (HTTP 408 on a ~2,000-tx
   post-outage block) switched the connector **permanently** to per-tx mode and fired ~2,000
   concurrent `eth_getTransactionReceipt` calls. Besu decodes the whole block's receipt list for each
   of those calls (`DefaultBlockchain.getTxReceipts` in the thread dump), so validator1 ended with
   900+ open connections, every RPC worker busy and a full-GC loop (`RPC_UNRESPONSIVE`). The original
   Area 2 over-tolerance runs logged the same fallback. New behaviour: retry the same block with
   backoff (1 s doubling to 10 s); after 3 failures read **that block only** per tx with at most 8
   calls in flight; partial failures keep what was found and rescan only the rest; per-block mode is
   never switched off by a timeout. Verified offline against a fake provider (all receipts resolved,
   max 8 in flight). It never activated in any T1 or T3 run (no watcher warnings in their Caliper
   logs), so those runs are unaffected.

Config deviation agreed with Patrick: **T2 heap 500 MB instead of 365 MB** (cgroup cap kept at the
original 914 MB) for the final T2 runs — see T2.

## Run log

| Run ID | Outcome | Reason / note |
|---|---|---|
| T1-S1-n4-20261014-150405-smoke | COMPLETED | smoke, 500 votes, audit PASS |
| T2-V0-n4-20261014-150621-smoke | CRASHED | `RPC_UNRESPONSIVE` (connector per-tx fallback storm, heap 365 MB) |
| T2-V3-n4-20261014-151519-smoke | CRASHED | `RPC_UNRESPONSIVE` (same) |
| T3-n4-20261014-152441-smoke | INTERRUPTED | VM powered off abruptly at 15:30:52 (no OOM/panic in the journal; host-side stop); no index line |
| T3-n4-20261014-155209-smoke | COMPLETED | smoke, 500 voters |
| T1-S1-n4-20261014-155943-run1 | INVALID | driver OOM-killed during audit (fix 1); index says COMPLETED/T1=NOT RUN — mislabel, see NOTE.txt |
| T1-S2-n4-20261014-160919-run1 | INVALID | same; no index line; see NOTE.txt |
| T3-n4-20261014-161855 | STOPPED | stopped by operator: auto-sized to 168 MB heaps after a too-quick launch; index says COMPLETED phases='' — mislabel, see NOTE.txt |
| T1-S1-n4-20261014-163012-run1 | COMPLETED | audit PASS |
| T1-S1-n4-20261014-164018-run2 | COMPLETED | audit PASS |
| T1-S1-n4-20261014-165024-run3 | COMPLETED | audit PASS |
| T1-S2-n4-20261014-170030-run1 | COMPLETED | fault PASS, audit PASS |
| T1-S2-n4-20261014-171036-run2 | COMPLETED | fault PASS, audit PASS |
| T1-S2-n4-20261014-172042-run3 | COMPLETED | fault PASS, audit PASS |
| T3-n4-20261014-173048-run1 | COMPLETED | idle + registration + voting |
| T2-V0-n4-20261014-181812-smoke2 | CRASHED | `VALIDATOR_JVM_HEAP_OOM` validator2 (connector fix worked; heap 365 MB) |
| T2-V0-n4-20261014-183145-smoke3-heap500 | COMPLETED | smoke at heap 500 MB, 0/3002 lost |
| T2-V0-n4-20261014-184038-heap500 | CRASHED | `VALIDATOR_JVM_HEAP_OOM` validator2, 107 s after resume |
| T2-V1-n4-20261014-185114-heap500 | CRASHED | `VALIDATOR_JVM_HEAP_OOM` validator2, 112 s after resume |
| T2-V3-n4-20261014-190151-heap500 | CRASHED | `VALIDATOR_JVM_HEAP_OOM` validator2, 104 s after resume |

No host-level (kernel) OOM in any run; the editor was unaffected. The run-mislabel (a killed
driver's exit handler writes COMPLETED) is a harness bug that was not fixed; the affected folders
carry a `NOTE.txt`.

## T1 — Tally audit across validators (n=4, 10,000 votes at 25 TPS, 3 repeats each)

S1 = no fault. S2 = validator4 SIGKILLed during voting (`crash-fault.sh`, 60 s hold), restarted,
resynced, then voting closed and all four audited. Source: `T1-audit-all.csv` (smoke and invalid
runs excluded), `*/audit.json`.

| Run | Audit height | Block hash (all 4 identical) | Tally = recount (all 4) | Events / unique voters | Caliper confirmed = contract total | Recount ms/10k (mean) | 2.9M estimate | Resync | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| S1 run1 | 275 | 0xcb1cf8cd…26312da9 | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 1899 | 551 s | – | PASS |
| S1 run2 | 276 | 0x369fdb10…4099ed58 | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 1951 | 566 s | – | PASS |
| S1 run3 | 276 | 0x5a2cbd2f…b1cb471c | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 1987 | 576 s | – | PASS |
| S2 run1 | 264 | 0x48e07726…0f89aff0 | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 2030 | 589 s | 8.5 s | PASS |
| S2 run2 | 266 | 0x51e03fa3…3ad14692 | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 1924 | 558 s | 7.7 s | PASS |
| S2 run3 | 266 | 0xe0df3a3b…7c0018dd | 3334/3334/3332 ✓ | 10000 / 10000 | 10000 ✓ | 1867 | 541 s | 8.5 s | PASS |

- **6/6 PASS.** On every validator, including the one that crashed and resynced, the contract's
  `getTally` equals an independent recount of `VoteCast` events; events = unique voters (nobody
  counted twice); all validators report the same block hash at the audit height; totals equal
  Caliper's confirmed count. No mismatch was found.
- **Recount time:** 1.87–2.03 s per 10,000 votes per validator (mean 1.94 s; per-validator values
  1.72–2.21 s). Linear estimate for a full independent audit of 2.9M votes: **≈541–589 s
  (≈9–10 min) per validator** on this VM (assumption: linear in vote count, `eth_getLogs` in 5,000-
  block chunks, one validator at a time).
- **Ballot secrecy evidence:** every `VoteCast` event carries the voter address and the candidate
  (`audit.json` → `sampleVoteLinks`), so the public chain links each vote to a voter.
- S3 (n=7, two staggered crashes) was optional and not run.

## T2 — Transaction-pool eviction and client retry (n=4, original over-tolerance scenario)

Scenario identical to `crash-fault-results/n4-over-20261008-042837` (the 31% run): 25 TPS castVote
for 300 s sent to validators 1–2; after 40 s, validators 3 and 4 SIGKILLed 5 s apart (quorum lost),
held 60 s, restarted. Per-validator cgroup cap 914 MB as in the original; **JVM heap 500 MB**
(original 365 MB — see below). One run per variant (time); V2 and the planned repeats not run.

**`eviction-summary` did not run in any real T2 run**: validator2 died of a Java heap OOM ~105 s
after the chain resumed every time, which aborts the run. The figures below are therefore
**reconstructed** from data the runs kept, not produced by the harness:

- votes mined = transactions in validator1's block log (`validator1.log`, deduplicated by block)
  minus the 7,627 setup transactions (deploy + openVoting + 7,625 registrations);
- votes sent = nominal 25 TPS × 300 s ≈ 7,500 (the completed smoke measured 3,002 for 120 s, i.e.
  25.0 TPS, so the nominal value is within ~0.1%);
- pool sizes from `txpool.csv` (2 s samples); outage from `run.log` / `fault-events.csv`.

| Variant | Outage (crash→resume) | Restart→resume | Peak pool (all 4) | Flush after resume | Votes mined / ~sent | Lost (≈) | Peak validator mem (MB) | Outcome |
|---|---|---|---|---|---|---|---|---|
| V0 pool 4,096 | 339 s | 258 s | **4,096 (full)** | 4,096 in #73–74 (3,071 + 1,025) | 5,140 / 7,500 | **≈2,360 (≈31.5%)** | v1 841, v2 838, v3 436, v4 467 | heap OOM v2 |
| V1 pool 16,384 | 337 s | 257 s | 6,463 | 6,463 in #73–74 (3,015 + 3,448) | 7,502 / 7,500 | **≈0** | v1 840, v2 851, v3 472, v4 469 | heap OOM v2 |
| V3 retry (pool 4,096) | 211 s | 130 s | **4,096 (full)** | 4,096 in #71 | 6,307 / 7,500 at crash | not measurable | v1 846, v2 828, v3 436, v4 464 | heap OOM v2 |

Not measurable without `eviction-summary`: outage-vote p50/p95/p99, pool-empty time, retries (V3).
The completed smoke at heap 500 MB (120 s load, backlog 1,949 < 4,096) gives the shape:
3,002 sent, 3,002 confirmed, 0 lost; outage 333 s (restart→resume 258 s); 2,022 votes sent during
the outage waited p50/p95/p99 = 305/324/327 s; pool empty 5.5 s after the chain resumed; on-chain
tally = confirmed.

Findings:
1. **V0 reproduces the ≈31% loss.** Same signature as the original (2,340 of 7,503 lost, flushed in
   exactly 4,096): this run flushed exactly 4,096 and mined ≈5,140 of ≈7,500.
2. **A 16,384-tx pool removes the loss in this scenario** (peak backlog 6,463; every vote mined), at
   the cost of more memory per node during the flush.
3. **Recovery after a quorum outage is memory-bound on this VM.** With the original 365 MB heap the
   node wedged (RPC) or ran out of heap while serving receipts for the 2,000–4,000-tx flush blocks;
   with 500 MB heap validator2 still died every time ~105 s after resume, while the cgroup peak
   stayed below 914 MB. Even a single `eth_getBlockReceipts` for a ~2,000-tx block took >30 s and
   timed out right after a flush. An election-day node needs memory headroom for a full pool plus
   the flush plus serving receipts for it.
4. **V3 (client retry) is untested** — the run crashed before retries could complete. Needs more
   memory per node (or more VM resources).
5. **Restart→resume** was 130 s or ≈257 s in every T2 run (smokes included), consistent with Area 2
   (135/266/135 s): IBFT round-change backoff, not load.

## T3 — Storage growth (n=4, fresh network, `T3-n4-20261014-173048-run1`)

30 min idle (931 empty blocks), then 10,000 registrations (106 s, ≈94 TPS), then 10,000 votes at
25 TPS (409 s; p50 1.24 s, p95 2.14 s, 0 failed). `du -sb` of each validator's data directory after
a 60 s settle. All four validators agree within a few hundred bytes; **no shrink warnings**;
`database_bytes` is filled in (Besu's `database/` sub-directory). Source: `storage.csv`,
`storage-summary.json`.

| Per validator | Idle-corrected | Raw |
|---|---|---|
| Per empty block | **1,961 B** | – |
| Per registration | **1,309 B** | 1,325 B |
| Per vote | **3,480 B** | 3,527 B |

(validator1: 413,614 B → 2,238,901 B idle; → 15,549,720 B after registration; → 50,869,525 B after voting.)

**Election-scale estimate** (linear; 2.9M registrations + 2.9M votes + 21 days of 2 s blocks =
907,200 blocks): **≈15.7 GB per validator**, of which empty blocks ≈1.78 GB. For 3.5M voters the
same rates give ≈18.5 GB per validator. Assumptions: linear growth (BONSAI, RocksDB compaction state
at measurement time), registration/vote figures corrected for idle block growth during each phase,
10,000-tx sample extrapolated ×290.

**Read latency** (`read-probes.csv`, 250 calls each at 50 TPS):

| Probe | State | getTally p50 / p95 / p99 | getVoterState p50 / p95 / p99 |
|---|---|---|---|
| start | 0 voters | 15 / 35 / 66 ms | 15 / 33 / 84 ms |
| end | 10,000 registered + 10,000 votes | 8 / 17 / 21 ms | 9 / 15 / 21 ms |

No slowdown with state size at this scale; the lower end values are likely JVM warm-up (the start
probe runs ~1 min after the network starts), not a real speed-up.

## Not done

- **T4 (hardware sensitivity)**: not run — would need the VM's CPU/RAM raised. State as a limitation:
  all throughput figures are a lower bound for a 4-vCPU / 8 GB VirtualBox guest on a
  14-core / 32 GB host.
- **T1 S3** (n=7) — optional, not run.
- **T2 repeats, V2, and a usable V3** — not run / not measurable (time, and the heap OOM above).

## Anomalies and caveats

- VM powered off abruptly at 15:30:52 (journal ends mid-run, zero-filled log tails, 3.8 GB free and
  load 2.3 a second earlier) — external to the tests; one T3 smoke lost.
- A killed driver writes `COMPLETED` to `additional-index.log` (exit-handler mislabel); the three
  affected folders have `NOTE.txt`. Read the run table above, not the raw index, for outcomes.
- The T2 loss figures are reconstructions (see T2) and rest on single runs.
- Each Caliper worker watches receipts on its own validator (worker 0 → v1, worker 1 → v2); the
  validator that crashed in T2 was always one of those two, never the restarted ones.
- Smoke rows are included in `T1-audit-all.csv` and `T2-summary.csv`; filter by run ID.
