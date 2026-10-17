# Additional Test Plan: Infrastructure Evaluation

Oct 14, 2026 · @Eason

## Purpose and run order

Four additional tests, written by Eason and run on Patrick's machine, plus one analysis that needs no machine, finishing by Thursday night so results can be written up on Friday and Saturday. Each one turns a criterion that the report currently argues into one it can measure, or tests how far the existing results can be trusted.

| Order | Task | Answers | Criterion | Rough time |
| --- | --- | --- | --- | --- |
| 1 | T0 Environment record | Method section | Validity | 15 min |
| 2 | A1 NZ demand and headroom analysis (no machine, start now) | RQ1 | Performance against NZ demand | Half a day |
| 3 | T1 Tally audit across validators | RQ2 | Auditability, ballot integrity | Script: half a day. Runs: 1 to 2 h |
| 4 | T2 Transaction pool eviction and retry | RQ2 | Availability | 3 to 4 h |
| 5 | T3 Storage growth | RQ3 | Deployment cost | 1 to 2 h (skip if endurance or volume data already covers it) |
| 6 | T4 Hardware sensitivity | RQ1 | Validity of throughput claims | 2 h, or state as a limitation instead |

Time estimates are rough guesses. If time runs short, drop T4 first, then T3.

Ground rules for every run:

- Same Besu version (24.12.0), genesis settings and 2 s block period as the existing tests, so results stay comparable.
- n = 4 unless a test says otherwise.
- Start from a fresh network (new data directories) for each scenario, unless the test says to keep state.
- Change one thing per variant, and record every configuration value used.
- Repeat each key run 3 times if time allows, and report the spread, not just one value.

## T0: Record the test environment

Record the exact environment before any run, because the Method section must describe where the tests actually ran. This also settles whether the tests ran in a 7.7 GB environment (as the architecture notes say) or with the full 14 to 16 GB.

Run these on Patrick's machine and save the output to `env.txt` alongside the results:

```bash
nproc
lscpu | grep -E "Model name|^CPU\(s\)"
free -h
uname -a
cat /proc/version          # contains "microsoft" if running in WSL
systemd-detect-virt        # names the VM or container type, or "none"
df -h .                    # disk holding the validator data
java -version
besu --version
systemctl --user show p4p-besu-n4-v1 -p MemoryMax   # per-validator memory cap
```

The tests ran in a virtual machine, so also record the VM's CPU and memory allocation from the hypervisor settings, and the host laptop's total RAM and CPU.

**Decision point:** if the guest had much less memory or CPU than the machine, T4 becomes worth running.

## A1: NZ demand and headroom analysis (no machine needed)

Compare the throughput the infrastructure achieved with what an NZ general election demands, so RQ1 is answered against a yardstick rather than with raw numbers. This needs no test runs, so it can start today, and its figure is likely to be the central figure of the Discussion.

1. **Start from the existing baseline:** last year's reports give about 6.57 votes per second as the average on the final voting day (Kwon), and just over 7 votes per second between 9 am and 7 pm on election day (Browne). Both are averages, not peaks, so never call them peak throughput in the report.
2. **Verify at the source:** check both figures against the Electoral Commission's 2023 general election voting statistics, which both reports cite, and cite that source directly rather than the student reports. Record which votes and which hours the rate covers, plus the source page and access date.
3. **Add peak scenarios:** if hourly figures are published, use them. If not, apply peak multipliers to the verified average (for example 3, 5 and 10 times) and state clearly that these are assumptions.
4. **Optional online share:** not every vote would move online, so a scenario scaled by an online uptake share (for example Estonia's internet voting share, cited from a source) can show a more realistic demand.
5. **Take capacity** from the existing throughput results: maximum sustained TPS at n = 4, 7 and 10.
6. **Calculate headroom** for each scenario: capacity ÷ required rate. As a rough check, 80 TPS at n = 7 is about 12 times the 6.57 average, so the system could absorb a peak up to roughly 12 times the average.

**Figure:** measured capacity for each validator count, with lines marking the average rate and each peak scenario. Note that capacity was measured in a VM, so it is a lower bound (see T4).

## T1: Tally audit across validators

Show that the contract's tally matches an independent recount from the chain's own records, on every validator, including one that crashed and resynced. This turns auditability and ballot integrity from argued properties into measured ones.

**Script (`audit-tally.js`, Node.js + ethers v6).** Read RPC URLs from `network-meta.json` and the contract address from `networks/besu-nN.json`, then:

1. After voting closes, pick an audit height H: the lowest latest block across all validators, so every node is compared at the same point.
2. On each validator, at block H:
   - Read the block hash. All validators must report the same hash.
   - Read `getTally(c)` for every candidate.
   - Recount independently: fetch every `VoteCast` event from the deployment block to H with `eth_getLogs`, in chunks of about 5,000 blocks to avoid range limits, and count votes per candidate.
   - Count unique voter addresses in those events.
   - Time how long the recount takes.
3. Compare across validators, and against Caliper's count of confirmed votes.

**Scenarios**

- **S1 Baseline:** n = 4, cast a known number of votes (for example 10,000), close voting, audit.
- **S2 After crash and resync:** n = 4, crash one validator during voting with `crash-fault.sh`, restart it, wait until it has caught up, close voting, audit all four.
- **S3 Optional:** n = 7 with two staggered crashes, if memory allows.

**Record per validator:** block hash at H, contract tally per candidate, recounted tally per candidate, number of `VoteCast` events, number of unique voters, recount time.

**Pass criteria:** on every validator, the contract tally equals the recount; the event count equals the unique voter count (nobody counted twice); every validator reports identical values and the same block hash; the totals match Caliper's confirmed votes. A mismatch is not a failed test. It is a finding, so keep all raw output.

**Extra value for the report:** the recount time per 10,000 votes lets you estimate how long a full independent audit of about 2.9 million votes would take. The fact that the audit can link each vote to a voter address also gives concrete evidence for the ballot secrecy limitation.

## T2: Transaction pool eviction and client retry

The crash-fault tests (labelled Area 2 in the test harness) found that about 31% of votes sent during an outage were evicted when the transaction pool hit its 4,096 limit. This test checks whether a larger pool, or a client that resends unconfirmed votes, prevents that loss. It covers the availability criterion and turns a weakness into a found, diagnosed and mitigated result.

**Before running**

- Find which crash-fault scenario produced the 31% (n, load, which nodes went down, for how long). Every variant below must repeat that exact scenario.
- Check which pool option sets the 4,096 limit: run `besu --help | grep -i tx-pool` and check the start scripts for any `tx-pool` options already set. Confirm the option name from the help text before changing it.

**Variants** (identical scenario, one change each)

- **V0 Baseline:** original limit. Confirms the roughly 31% eviction is reproducible.
- **V1 Larger pool:** limit × 4 (16,384).
- **V2 Much larger pool:** limit × 16 (65,536), only if memory allows. Stop if the watchdog reports `HOST_MEMORY_PRESSURE`.
- **V3 Client retry:** original limit. After the outage, resend every vote that has no receipt after about 30 s (15 blocks), as the identical signed transaction, up to 3 times.

Resending is safe for two reasons: the identical transaction has the same nonce, so it can only be included once, and the contract rejects a second vote from an address that has already voted.

**Record per run:** votes sent, votes confirmed, votes lost (sent minus confirmed after the pool drains), loss as a percentage, time from outage end until the pool is empty, p95 latency of votes sent during the outage, peak validator memory. For V3, also record the number of retries needed.

**Expected result:** V1 and V2 reduce loss, at the cost of more memory per node. V3 reaches full inclusion, at the cost of extra load during recovery. Both trade-offs are useful material for the Discussion.

## T3: Storage growth per vote and while idle

Estimate how much disk each validator needs for a national election. The network keeps producing empty blocks every 2 s (43,200 blocks per day), so storage grows with time as well as with votes, and both need measuring.

**Note on empty blocks:** they come from how the network is currently configured. Check the Besu documentation for a setting that limits empty blocks before considering a code change, but do not change it now, because the existing results were produced with empty blocks. Measure the idle cost here, then present the fix in the Discussion and Future work.

**First:** check the existing endurance and volume reports. If they already record disk size against votes cast, use that data and skip to the extrapolation.

**Procedure** (fresh n = 4 network; measure every validator's data directory with `du -sb`)

1. **Idle growth:** measure, wait 30 minutes with no transactions (about 900 empty blocks), measure again.
2. **Registration:** measure, register N voters, measure again.
3. **Voting:** measure, cast N votes (as many as practical, for example 50,000), measure again.
4. Wait about a minute before each measurement, since the database compacts in the background and sizes can jump.
5. Also time `getTally` and `getVoterState` calls at the start and the end, to see whether reads slow down as state grows.

**Calculate:** bytes per empty block, bytes per registration, bytes per vote.

**Extrapolate:** disk per validator for about 2.9 million registrations and votes, plus empty blocks over the election period. For example, three weeks is about 907,000 blocks. Present this as an estimate and state the assumptions.

## T4: Hardware sensitivity rerun (the tests ran in a VM)

The tests ran in Patrick's virtual machine, which the architecture notes suggest had about 4 cores and 7.7 GB on a 14 to 16 GB laptop. If so, the existing ceiling (about 120 to 135 TPS at n = 4, about 80 TPS at n = 7) may reflect the VM's allocation rather than the system itself. T0 confirms the allocation. Then choose one:

- **Rerun** with more resources, if time allows (procedure below).
- **State it as a limitation:** the results were measured in a VM with the recorded allocation, so they are a lower bound on the system's capacity.

**Procedure**

1. Raise the VM's CPU and memory allocation in the hypervisor settings, leaving enough for the host system. Raise the per-validator `MemoryMax` if it was the limiting factor. Change nothing else.
2. Rerun the existing Area 1 stress step for n = 4 and n = 7, using the same benchmark files and settings as before.
3. Record maximum sustained TPS and p50, p95 and p99 latency, and compare with the original results.

**How to read it**

- **Throughput rises clearly:** the original results were limited by the host, so they are a lower bound on what the system can do.
- **Throughput barely changes:** the limit lies in the system's configuration (for example the block period, transaction pool or consensus overhead), which points the Discussion and Future work toward tuning rather than hardware.

Either outcome makes the throughput claims in the report more accurate.

## Data to keep for the report

Keep everything from each run in its own folder (for example `reports/additional/T2-V1-run2/`), because the report and the research compendium both draw on it.

For every run, save:

- date and time, n, and every configuration value changed (pool limit, memory caps)
- the git commit hash of the code used
- the benchmark or workload file
- raw Caliper output and the latency NDJSON files
- watchdog and fault timeline logs
- the `env.txt` from T0

Planned figures:

- **T1:** a small table of contract tally against recount for each validator, for S1 and S2.
- **T2:** votes lost (%) for each variant, plus a timeline of pool size during the outage for V0 against the best variant.
- **T3:** storage per vote, per registration and per empty block, with the election-scale estimate.
- **T4:** maximum TPS and p95 latency before and after, at n = 4 and n = 7.

For the Statement of Contribution and Method, note that Eason wrote and ran these tests on Patrick's machine, using the harness Patrick built.
