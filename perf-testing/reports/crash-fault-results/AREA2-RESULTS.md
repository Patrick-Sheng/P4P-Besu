# Area 2 — Crash-fault tolerance results (2026-10-08)

Host: single dev box, 4 cores, 7.7 GB RAM, no swap (same as Area 1). Besu 24.12.0, IBFT 2.0,
blockperiod 2 s, requesttimeoutseconds 4. Native network (no Docker): validators are memory-capped
systemd user units; a crash is `SIGKILL` (unclean), restart re-launches on the existing data dir
(`network/node-ctl.sh`). A constant 25 TPS `castVote` load (10 TPS planned for n=10) runs throughout,
sent only to validators that are never crashed. Driver: `scripts/area2-crash.sh <n> within|over`.

- **within** = crash f = ⌊(n−1)/3⌋ validators, staggered 5 s, hold 60 s, restart. Expect liveness, resync, identical state.
- **over** = crash f+1. Expect the chain to halt (no fork), then resume once nodes return.

## Results

| n | scenario | BFT property | Result | Detail |
|---|---|---|---|---|
| 4 | within (crash 1) | liveness | **PASS** | 23 blocks / 60 s with 3/4 live (vs 30 nominal) |
| 4 | within | resync + state | **PASS** | caught up in 9 s; all 4 nodes identical hash at #199 |
| 4 | over (crash 2) ×3 runs | halt (no fork) | **PASS ×3** | 0 blocks in 60 s every time |
| 4 | over | resume after quorum restored | **PASS, slow** | 135 s, 266 s, 135 s after restart |
| 7 | within (crash 2) | liveness | **PASS** | 15 blocks / 60 s with 5/7 live |
| 7 | within | resync + state | **PASS** | caught up in 5 s and 11 s; all 7 identical at #198 |
| 7 | over (crash 3) | halt | **PASS** | 0 blocks in 60 s |
| 7 | over | resume | **NOT MEASURED** | survivor validator1 OOM-killed (521 MB cap) holding the halt backlog |
| 10 | within / over | — | **NOT RUN** | validator1 OOM-killed (~381 MB cap) during voter registration, host load 30–37 |

No fork and no state divergence was observed in any run that reached the consistency check.

### Throughput/latency while nodes are down and catching up (25 TPS offered)

| n | phase | confirmed TPS | p50 (s) | p95 (s) | mean / max block gap (s) |
|---|---|---|---|---|---|
| 4 | baseline | 23.7 | 1.41 | 2.31 | 2.00 / 2 |
| 4 | 1 node down | 25.3 | 1.68 | 4.20 | 2.67 / 4 |
| 4 | resyncing | 25.8 | 1.97 | 4.55 | 2.80 / 4 |
| 4 | after | 24.9 | 1.34 | 2.26 | 2.00 / 2 |
| 7 | baseline | 24.7 | 1.80 | 2.83 | 2.00 / 2 |
| 7 | 2 nodes down | 24.9 | 3.03 | 13.48 | 3.50 / 12 |
| 7 | resyncing | 21.3 | 5.29 | 15.96 | 3.50 / 12 |
| 7 | after | 25.8 | 1.56 | 2.69 | 2.00 / 2 |

Throughput held at the offered load; the cost of f crashed validators is **latency**. Each time a
dead validator's turn as proposer comes up, IBFT waits out a round timeout (4 s, then 8 s if the
next proposer is also dead) — hence the 12 s max gap and ~13–16 s p95 at n=7. All zero failed txs.

## Findings that matter for the voting system

1. **Recovery after quorum loss takes minutes, not seconds.** Round-change timeouts double every
   failed round (4→8→16→…→256 s). While quorum is gone each validator keeps escalating on its own
   timer; restarted nodes start lower. The chain only resumes when 2f+1 validators happen to be in
   the same round. Observed directly in validator logs (v1/v2 round 6, v3/v4 round 5; block #137
   produced 5 s after v4 entered round 6). Recovery was 135–266 s after the nodes were already back.
   A ~1 min quorum outage costs 3–5 min of downtime.

2. **Votes accepted during an outage are silently dropped beyond 4,096.** Besu's default
   `--tx-pool-max-size` is 4096. In run n4-over-…042837, 7,503 votes were accepted (each got a tx hash)
   but only 5,163 reached the chain — **2,340 (31%) evicted without any error to the sender**. The
   backlog was flushed in exactly 4,096 txs (blocks #137–139: 2051 + 1676 + 369). The first over run
   (shorter halt) lost ~1,180 the same way. A client that trusts the returned hash would believe
   those votes were cast. Mitigations to evaluate: larger tx pool, client-side confirmation +
   resubmit, or rejecting submissions when the chain is not advancing.

3. **Flushing the post-outage backlog is the most fragile moment.** The same scenario ended three
   ways at n=4: RPC wedged (vert.x worker blocked >60 s, `RPC_UNRESPONSIVE`), clean flush, or
   validator OOM at 906 MB with a 600 MB heap (≈410 MB retained live heap, blocks of only ~50 tx
   because tx selection kept hitting Besu's 1.5 s limit). At n=7 the survivor OOM'd during the halt
   itself. These are bounded by this host's per-node memory, so treat as "needs headroom", not as
   absolute Besu limits — but an election-day node needs memory for a full tx pool plus flush.

4. **JVM picks the Serial GC** under these memory caps (<1.8 GB); production nodes should set
   G1 explicitly. GC logs: `validator*-gc.log` in each run dir.

## Run log

| Run | Outcome | Reason |
|---|---|---|
| n4-within-20261008-041053 | COMPLETED | fault PASS, state PASS |
| n4-over-20261008-041835 | CRASHED in wait-load | `RPC_UNRESPONSIVE` — validator1 RPC wedged flushing backlog (halt PASS, resume 135 s) |
| n4-over-20261008-042837 | COMPLETED | halt PASS; resume 266 s (> then-180 s limit → "FAIL"); state PASS; 2,340 votes dropped |
| n4-over-20261008-044052 (600 MB heap) | CRASHED in wait-load | `VALIDATOR_OOM_KILLED` validator1 at 906 MB during flush (halt PASS, resume 135 s) |
| n7-within-20261008-045210 | COMPLETED | fault PASS, state PASS |
| n7-over-20261008-050028 | CRASHED in load+fault | `VALIDATOR_OOM_KILLED` validator1 at 521 MB during halt (halt PASS) |
| n10-within-20261008-051949 | CRASHED in voters | validator1 OOM-killed at ~381 MB (logged as DRIVER_ERROR/ECONNRESET; root cause from journal) |
| n10-over-20261008-052328 | CRASHED in voters | validator1 OOM-killed at ~381 MB (logged as DRIVER_ERROR/ECONNREFUSED; root cause from journal) |

No host-level (kernel) OOM occurred; every OOM stayed inside one validator's cgroup and VS Code was unaffected.

## Harness changes for Area 2

- `network/node-ctl.sh` — start / crash (SIGKILL) / stop one native validator; `start-native.sh` uses it. GC logging per node.
- `fault-injection/lib.sh` — `node_crash` / `node_start` for native or Docker backends; fault events logged for timeline analysis.
- `crash-fault-over-tolerance.sh` — recovery timeout configurable (`RECOVERY_TIMEOUT`, driver uses 600 s); the old 60 s was shorter than IBFT's own backoff.
- `monitoring/fault-timeline.js` — per-phase throughput/latency/block-gap from latency logs + fault events.
- Watchdog exempts deliberately crashed validators; drivers now report a validator OOM as the root cause instead of the client-side connection error it causes, and stop immediately on a watchdog abort during the fault script.
