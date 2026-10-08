# Area 4 — Throughput (load / stress / spike / endurance / volume): NOT RUN

Status as of 2026-10-08: **no Area 4 test has been executed.** There are no results to report.
The only throughput artefact in the repo is `caliper/reports/smoke-test.html` — a 200-transaction,
20 TPS pipeline check from an earlier session, which is not any of the tests below.

## What exists (ready to run on adequate hardware)

| Test | Config | Design | Voter pool needed |
|---|---|---|---|
| Load | `caliper/benchmarks/throughput/load.yaml` | n=7, 300 then 400 TPS, 10 min each | 420,000 |
| Stress | `…/stress.yaml` | n=7, ramp 200 → 1,200 TPS over 20 min to find the ceiling | 900,000 |
| Spike | `…/spike.yaml` | n=7, baseline → 500 TPS burst → baseline (recovery check) | 100,000 |
| Endurance | `…/endurance.yaml` | n=7, 300 TPS for 4 h (memory, disk, latency creep) | ~4,300,000 |
| Volume | `…/volume.yaml` | n=7, 5 × ~580k-vote write phases at 400 TPS, read-latency probes between | ~2,900,000 |

Each file's header lists its exact prerequisites and run command.

## Why it was not run on the dev box

Measured in Area 1 (`reports/scalability-results/AREA1-RESULTS.md`) on this 4-core / 7.7 GB host:

- **n=7 saturates at ≈ 80 TPS** and was OOM-killed at 200 TPS. Every Area 4 test targets 300–1,200 TPS
  at n=7, so every result would just be "the host saturated" — a measurement of the rig, not IBFT.
- **Voter registration** runs at roughly 30–60 registrations/s here (single admin sender), so
  pre-registering 0.1–4.3M voters would take hours to a day before a test even starts, and
  the per-node memory budget (~520 MB at n=7) was exceeded by far smaller backlogs in Area 2.

## What could run here (if wanted)

A scaled-down **n=4 load + spike** below the measured ≈120 TPS saturation point (e.g. 60 TPS steady,
100 TPS spike) would exercise the spike-recovery logic and validate the configs end to end, but
would not answer the 300–500 TPS question.

## To run for real

- One VM per validator (≥ 4 cores, ≥ 4 GB RAM each) plus a separate load-generator host.
- Use the native or Docker network; launch via a detached runner like `scripts/run-area1.sh`
  so long runs survive an editor crash, with `monitoring/resource-watchdog.sh` labelling aborts.
- Before endurance/volume: raise `--tx-pool-max-size` above the 4,096 default — Area 2 showed
  backlogs beyond it are silently evicted (`reports/crash-fault-results/AREA2-RESULTS.md`, finding 2).
