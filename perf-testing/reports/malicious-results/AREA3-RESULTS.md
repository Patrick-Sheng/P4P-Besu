# Area 3 — Malicious-node behaviour results (2026-10-08)

Host: same dev box as Areas 1–2 (4 cores, 7.7 GB, no swap). Besu 24.12.0, IBFT 2.0, native network,
idle except for the attack traffic. Driver: `scripts/run-area3.sh` → `scripts/area3-attacks.sh <n>`,
3 attempts per attack per node count. Per-attempt output: `<run>/<attack>-<k>.log`; tallies in `<run>/summary.csv`.

**Scope: client-level attacks only** — a rogue *voter account* misbehaving. Consensus-level attacks by a
rogue *validator* (malformed / conflicting PRE-PREPARE, PREPARE, COMMIT messages) need the patched Besu
build in `ibft-fuzzing/`, which is design + starter patches only and has **not been run**. So these
results do not show that "a quorum prevents a malicious validator from influencing consensus alone".

## Results — 27 / 27 PASS

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
