# Area 3 — Malicious-node behaviour results (rounds 1–3; round 1 run 2026-10-08)

Host: same dev box as Areas 1–2 (4 cores, 7.7 GB, no swap). Besu 24.12.0, IBFT 2.0, native network,
idle except for the attack traffic. Driver: `scripts/run-area3.sh` → `scripts/area3-attacks.sh <n>`,
3 attempts per attack per node count. Per-attempt output: `<run>/<attack>-<k>.log`; tallies in `<run>/summary.csv`.

**Scope: client-level attacks only** — a rogue *voter account* misbehaving. Consensus-level attacks by a
rogue *validator* (malformed / conflicting PRE-PREPARE, PREPARE, COMMIT messages) need the patched Besu
build in `ibft-fuzzing/`, which is design + starter patches only and has **not been run**. So these
results do not show that "a quorum prevents a malicious validator from influencing consensus alone".

## Current findings (all rounds, updated 2026-10-17)

**Voter attacks have now been tested at up to 13 validators, and every attempt was blocked.**

| Round | Where | Attempts | Result |
| --- | --- | --- | --- |
| 1 (8 Oct) | n = 4, 7, 10; idle, empty chain | 3 per attack per size (27) | **27 / 27 blocked** |
| 2 (16 Oct) | n = 4; chain with 1M votes and 3.3M registered voters, 8 of 27 with live 90 votes/s traffic | 9 per attack (27) + 1,000-voter mass double vote | **27 / 27 blocked; 1,000 / 1,000 double votes reverted** ([R2 report §7](../r2-soak/R2-ELECTION-SCALE-RESULTS.md)) |
| **3 (17 Oct)** | **n = 13**, fresh chain | 3 per attack (9), then 9 per attack (27) | **9 / 9 and 27 / 27 blocked** |

After every attempt, **every validator reported identical tallies and the same block hash** (13 of 13 in round 3).
Still not covered: rogue-validator (consensus-message) attacks.

## Round 1 results (2026-10-08) — 27 / 27 PASS

| Attack | n=4 | n=7 | n=10 | How it was stopped (all attempts) |
|---|---|---|---|---|
| Double-vote | 3/3 | 3/3 | 3/3 | Second `castVote` from the same voter was mined and **reverted by the contract** (`CALL_EXCEPTION`, status 0); tally +1 exactly once; voter state `Voted` |
| Equivocation | 3/3 | 3/3 | 3/3 | Two conflicting votes (candidate 0 vs 1, same nonce) sent simultaneously to two different validators: **exactly one** included every time (B won 7×, A won 2× — a real race, not one endpoint always winning); the other dropped as same-nonce replacement; total tally +1 |
| Replay | 3/3 | 3/3 | 3/3 | Rebroadcast of the exact mined raw transaction **rejected at submission** (`Nonce too low`, -32001); tally unchanged |

Every attempt also passed a **network-wide check**: after the attack, *every* validator (4, 7 or 10)
reported identical tallies and an identical block hash at a common height — no node counted differently.

| Run | Outcome |
|---|---|
| n4-20261008-221839 | COMPLETED — 9 pass, 0 fail |
| n7-20261008-222211 | COMPLETED — 9 pass, 0 fail |
| n10-20261008-222544 | COMPLETED — 9 pass, 0 fail (first Area-to-date test to complete at n=10: idle network, tiny tx volume fits in the ~380 MB/validator budget) |

## What protects against each

- **Double-vote** — application layer: `VotingSystem.castVote()` requires `voterState == NotVoted`.
- **Equivocation / replay** — protocol layer: per-account nonces (one tx per nonce, ever) plus IBFT's single
  total order of blocks, so all validators agree which of two conflicting txs won.

## Changes vs. the earlier (unrecorded) run

The earlier session's 3 PASSes at n=4 were never saved to disk; these runs replace them with stored evidence.
The attack scripts were strengthened first:
- `double-vote.js` logs *why* the second vote failed — previously any error (including a network error)
  would have counted as "rejected".
- All three scripts now check tallies and block hash on **every** validator (`assertAllNodesAgree` in
  `fault-injection/malicious/lib.js`), not just validator1.

## Not covered

- Rogue-validator / wire-protocol attacks (`ibft-fuzzing/`, unbuilt).
- Attacks under load or during crash faults (all runs here were on an otherwise idle network).
- n=13.

## Round 3 results (2026-10-17): 13 validators

Plan: *Round 3 Test Plan: Validator Count Gaps*, Test 4. Script `scripts/area3-attacks.sh 13 <reps>` (unchanged
from round 1 apart from round 2's concurrency-safe tally checks, which reduce to round 1's checks on an idle chain)
on the round 2 VM (6 vCPU, 15.6 GiB). Per validator: 900 MB cgroup cap, 360 MB heap (the script's own split for n = 13).

The plan asked for "three times each (27 in total)". Three attempts per attack is 9; 27 matches round 1's total and
round 2's 9-per-attack set. Both were run:

| Run | Attempts | Double vote | Equivocation | Replay | All 13 validators agree after every attempt |
| --- | --- | --- | --- | --- | --- |
| `n13-20261017-075748` | 3 per attack | 3 / 3 | 3 / 3 | 3 / 3 | yes |
| `n13-20261017-080200` | 9 per attack | 9 / 9 | 9 / 9 | 9 / 9 | yes |
| **Total at n = 13** | **36** | **12 / 12** | **12 / 12** | **12 / 12** | **yes** |

- **Double vote:** the second `castVote` from the same voter was mined and reverted by the contract; tally +1 exactly once.
- **Equivocation:** of two conflicting same-nonce votes sent to two different validators, exactly one was included every
  time (in the 27-attempt run, vote B won 5 times and vote A 4 times: a real race, not one endpoint always winning).
- **Replay:** re-broadcast of a mined transaction rejected at submission (`nonce has already been used`); tally unchanged.

No lock-up or restart occurred in either run.
