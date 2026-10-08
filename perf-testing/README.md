# Hyperledger Caliper performance test suite

Performance/fault-tolerance test plan and harness for the IBFT2 voting
network in this repo, covering four areas: scalability (node-count sweep),
crash-fault tolerance, malicious-node behaviour, and throughput
(load/stress/spike/endurance/volume).

**Status**: the harness (network generation, Caliper connector/workloads,
seeding, latency/block-time analysis, application-layer attack scripts) was
built and validated end-to-end this session against the repo's existing
native 4-node network - see "What's been validated" below. The Docker-based
multi-size network generator is written and unit-tested for correctness of
its output, but not yet run through `docker compose up`, because Docker
wasn't installed on the dev machine used this session. The IBFT wire-protocol
byzantine fuzzing track (`ibft-fuzzing/`) is a source-verified design + two
starter patch files, not a built/tested artifact - see that directory's own
README for why that one's scoped differently.

## Methodology limitation: the 300-500 TPS target

The load target (sustained 300-400 TPS, stretch goal 500 TPS under burst) is
derived from NZ Electoral Commission daily voting statistics (2017, 2020,
2023) scaled to an estimated 2026 total of ~2.9M votes, adjusted upward from
a flat daily average to account for election-day concentration and removing
paper voting's physical throughput cap (queues, opening hours) once voting is
online. **The multiplier used to go from paper-equivalent peak load to the
online estimate is a reasoned assumption, not a cited figure.** Treat the
300-500 TPS band as a working design target, not a validated requirement -
if better data on expected online-voting concentration curves becomes
available (e.g. from a jurisdiction that already runs online voting), revisit
this number before treating pass/fail against it as conclusive.

## Prerequisites

- Node.js **22+** for `perf-testing/caliper/` specifically (Caliper 0.7.1
  requires it; `perf-testing/caliper/.nvmrc` pins 22). The rest of this repo
  (including `perf-testing/fault-injection/`, which only needs `ethers`) is
  fine on Node 20:
  ```bash
  cd perf-testing/caliper && nvm install 22 && nvm use 22
  ```
- The compiled contract artifact (gitignored, must be built locally):
  ```bash
  cd voting-contract && forge build
  ```
- `npm install` inside both `perf-testing/caliper/` and
  `perf-testing/fault-injection/` (separate node_modules; the former needs
  `@hyperledger/caliper-cli`/`caliper-core`, the latter just `ethers`).
- For Areas 1-2 (node-count sweep, crash faults) and the Docker resource
  monitors on any benchmark: **Docker + Docker Compose**, not required for a
  quick smoke test against the repo's existing native 4-node network.
- jq (for the fault-injection bash scripts).

## Layout

```
perf-testing/
├── network/
│   └── generate-network.mjs     Generates an N-validator IBFT2 network
│                                 (genesis + keys + docker-compose.yml) under
│                                 generated/n<N>/. node generate-network.mjs 7 [--light]
├── caliper/
│   ├── connector/voting-connector.js   Custom Caliper SUT connector (see below - why not
│   │                                    the stock @hyperledger/caliper-ethereum connector)
│   ├── workloads/cast-vote.js          Vote-casting workload (Areas 1 and 4)
│   ├── workloads/read-queries.js       Read-path workload (Area 4 Volume test)
│   ├── seed/generate-voters.js         Generates a pool of voter keypairs
│   ├── seed/register-voters.js         Registers a pool + opens voting (one-time setup)
│   ├── deploy-and-configure.js         Deploys VotingSystem + writes networks/besu-nN.json
│   ├── networks/                       Generated Caliper network configs (gitignored - contain
│   │                                    a private key)
│   └── benchmarks/
│       ├── scalability/scalability-{4,7,10,13}.yaml   Area 1
│       └── throughput/{load,stress,spike,endurance,volume}.yaml   Area 4
├── fault-injection/
│   ├── crash-fault.sh                  Area 2, within-tolerance (kills f nodes)
│   ├── crash-fault-over-tolerance.sh   Area 2, f+1 variant (expects a halt)
│   └── malicious/{double-vote,equivocation,replay}.js   Area 3, application layer
├── ibft-fuzzing/                       Area 3, consensus wire-protocol layer (see its own README)
└── monitoring/
    ├── compute-percentiles.js          p50/p95/p99 latency (Caliper's own report only has min/max/avg)
    └── block-time-drift.js             Block period drift from the 2s genesis target
```

## Why a custom Caliper connector

The stock `@hyperledger/caliper-ethereum` connector binds exactly one
`fromAddress` per worker process for an entire benchmark round (its
`getContext()` sets `context.fromAddress` once from network config). That
fits its usual use case - one hot wallet per worker repeatedly calling the
same method (e.g. token transfers). It does not fit `castVote()`: the
contract's three-state model (`NotVoted -> Processing -> Voted`) means every
vote must come from a **different** account that has never voted before -
modelling real turnout means thousands of distinct one-shot voters, not one
repeatable hot wallet per worker.

`connector/voting-connector.js` instead accepts a `privateKey` on every
individual request and keeps a wallet+nonce cache keyed by address, so each
simulated voter is its own account while transactions still flow through
Caliper's normal `sendRequests()`/`TxStatus` pipeline (and therefore its
normal pass/fail counting and the custom latency capture below). It also logs
Caliper's own throughput reporting gap - see next section.

## Why there's a separate percentile script

Caliper's built-in `report-builder.js` only computes min/max/avg latency, not
percentiles - confirmed by reading the shipped `@hyperledger/caliper-core`
source; there's no config flag that turns percentiles on. Since the test plan
requires p50/p95/p99 vote confirmation latency, `voting-connector.js` records
every transaction's submit-to-confirmation latency to
`reports/latency/round<R>-worker<W>.ndjson`, and
`monitoring/compute-percentiles.js <dir> <roundIndex>` aggregates those files
into p50/p95/p99/min/max/avg after a round finishes.

## Quick start (validated this session against the existing native network)

```bash
# 0. one-time
cd voting-contract && forge build && cd ..
cd perf-testing/caliper && nvm use 22 && npm install && cd ../fault-injection && npm install && cd ../..

# 1. point the harness at the repo's existing 4-node network (network/start-nodes.sh)
#    instead of a Docker-generated one, by hand-writing its network-meta.json once.
#    (Once Docker is set up, use generate-network.mjs + docker compose instead - see below.)
bash network/start-nodes.sh   # from repo root, if not already running

mkdir -p perf-testing/network/generated/n4
cat > perf-testing/network/generated/n4/network-meta.json <<'EOF'
{
  "nodeCount": 4,
  "validators": [
    { "address": "0x2efa683a0439e6ab8f0cb5132a0fcd58b5e285a9", "keyPath": "network/node1/key", "rpcUrl": "http://127.0.0.1:8545" },
    { "address": "0x855eea15ae57a616512490ca9716fb6d8f65a7d7", "keyPath": "network/node2/key", "rpcUrl": "http://127.0.0.1:8546" },
    { "address": "0xb287fc3b3836fdb780ae2eadd47dbc8b89dac097", "keyPath": "network/node3/key", "rpcUrl": "http://127.0.0.1:8547" },
    { "address": "0xe79dc7d4d4c977747007c5c56bd0db73f4a8b1ee", "keyPath": "network/node4/key", "rpcUrl": "http://127.0.0.1:8548" }
  ],
  "adminKeyPath": "network/node1/key",
  "maxTolerableFaults": 1
}
EOF

cd perf-testing/caliper
node deploy-and-configure.js 4                                  # deploys VotingSystem, writes networks/besu-n4.json
node seed/generate-voters.js 500 seed/generated/n4-voters.json  # a small pool for a smoke test
node seed/register-voters.js networks/besu-n4.json seed/generated/n4-voters.json

npx caliper launch manager --caliper-workspace . \
  --caliper-networkconfig networks/besu-n4.json \
  --caliper-benchconfig benchmarks/smoke-test.yaml \
  --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
  --caliper-report-path reports/smoke-test.html

node ../monitoring/compute-percentiles.js reports/latency 0
```

## Running the full Docker-based node-count sweep (once Docker is installed)

```bash
cd perf-testing/network
node generate-network.mjs 7          # writes generated/n7/{genesis, keys, docker-compose.yml, network-meta.json}
docker compose -f generated/n7/docker-compose.yml up -d

cd ../caliper
node deploy-and-configure.js 7
node seed/generate-voters.js 220000 seed/generated/n7-scalability.json
node seed/register-voters.js networks/besu-n7.json seed/generated/n7-scalability.json --concurrency=200

npx caliper launch manager --caliper-workspace . \
  --caliper-networkconfig networks/besu-n7.json \
  --caliper-benchconfig benchmarks/scalability/scalability-7.yaml \
  --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
  --caliper-report-path reports/scalability-7.html

# then, per round, block-time drift over the blocks that round produced:
node ../monitoring/block-time-drift.js http://127.0.0.1:20700 <fromBlock> <toBlock>
```
Repeat for n=4/10/13 (`node generate-network.mjs 10`, etc.) to build the
throughput/latency-vs-n curve for Area 1.

## Area 2 - crash faults

```bash
cd perf-testing/fault-injection
./crash-fault.sh 7                    # kills f=2, holds, reboots, checks resync + state consistency
./crash-fault-over-tolerance.sh 7      # kills f+1=3, expects the chain to halt, then recovers
```
Run a Caliper throughput round concurrently (another terminal) to observe the
"does throughput drop while catching up" question - correlate the scripts'
timestamped kill/reboot log lines against that round's latency NDJSON files.

## Area 3 - malicious nodes

Application-layer attacks (validated this session against a live network):
```bash
cd perf-testing/fault-injection
node malicious/double-vote.js ../caliper/networks/besu-n7.json
node malicious/equivocation.js ../caliper/networks/besu-n7.json
node malicious/replay.js ../caliper/networks/besu-n7.json
```
Consensus wire-protocol attacks (malformed PRE-PREPARE/PREPARE/COMMIT
payloads sent by a validator, as opposed to a client submitting a bad
transaction): see `ibft-fuzzing/README.md` - this requires a patched Besu
build, which is design + starter-patch only this session, not built/tested.

## Area 4 - throughput

Fixed at n=7. See `caliper/benchmarks/throughput/*.yaml` - each file has its
own prerequisites (voter pool size) and run command in its header comment.
Note the endurance and volume tests need very large voter pools (millions of
records); generating/registering those will take a while and is meant to run
unattended.

## Known constraints from the dev machine used this session

Node-count/TPS combinations above roughly n=4 at low TPS were not run live
here: the dev machine (4 cores / 7.7GB RAM) can't credibly sustain 10-13
concurrent Besu JVMs plus a Caliper load generator pushing hundreds of TPS -
numbers from an under-resourced rig would reflect the test rig's limits, not
IBFT's. The harness is built to be portable (parameterized by node count and
target TPS throughout); run the nodeCount=10/13 and high-TPS configs on
adequately sized hardware (more cores/RAM, or one VM per validator) rather
than trusting numbers produced under resource contention.
