#!/bin/bash
# Round 3 (validator count gaps, plan of 17 Oct 2026): runs the four tests one
# after another as ONE detached systemd --user unit (p4p-r3):
#   1. latency ladder      n = 4, 7, 10, 13 at 10/25/50 votes/s (r2-area1-ladder.sh)
#   2. agreement time      n = 4, 7, 10, 13, 16 idle, then 4, 7, 10, 13 at 10 votes/s (r3-agreement.sh)
#   3. f validators down   n = 4, 7, 10, 13, crash f for 60 s at 10 votes/s (area2-crash.sh within)
#   4. voter attacks       n = 13, 3 x 3 attacks (area3-attacks.sh 13 3)
# Every size runs regardless of earlier results; a size that ends in a Besu
# lock-up (stuck node, stall, validator down) is rerun once. Before each run
# the host CPU probe must be healthy (<= 1.5 s), waiting up to 30 min.
#
# Usage: scripts/run-r3.sh [--inner]     Follow: tail -f reports/round3-index.log
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PERF_DIR="$(pwd)"
INDEX="${PERF_DIR}/reports/round3-index.log"

if [ "${1:-}" != "--inner" ]; then
    systemctl --user is-active --quiet p4p-r3 && { echo "p4p-r3 already running" >&2; exit 1; }
    systemctl --user reset-failed p4p-r3 2>/dev/null
    source ~/.nvm/nvm.sh >/dev/null; nvm use 22 >/dev/null
    systemd-run --user --unit=p4p-r3 --slice=p4p-ctl.slice -p MemoryMax=256M --working-directory="$PERF_DIR" \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-r3 \
        -p StandardOutput="append:${PERF_DIR}/reports/round3-driver.out" -p StandardError="append:${PERF_DIR}/reports/round3-driver.out" \
        bash "${PERF_DIR}/scripts/run-r3.sh" --inner
    echo "Launched p4p-r3"; exit 0
fi

note() { echo "$(date '+%F %T') $*" | tee -a "$INDEX"; }
LOCKUP='NODE_STUCK|CONSENSUS_STALL|VALIDATOR_DOWN|RPC_UNRESPONSIVE|VALIDATOR_JVM_HEAP_OOM|VALIDATOR_OOM'

wait_host() {  # healthy CPU probe twice in a row, up to 30 min
    local ok=0 t0; t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        local p; p=$(bash monitoring/cpu-bench.sh)
        if [ "$(echo "$p <= 1.5" | bc)" -eq 1 ]; then ok=$((ok + 1)); [ "$ok" -ge 2 ] && return 0; else ok=0; note "host slow (CPU probe ${p}s) - waiting"; sleep 60; fi
    done
    note "host still slow after 30 min - continuing anyway (noted)"
}

# run_twice <label> <indexFile> <cmd...>: run; if the newest index line shows a lock-up, rerun once
run_twice() {
    local label="$1" idx="$2"; shift 2
    local attempt
    for attempt in 1 2; do
        wait_host
        note "${label}: start (attempt ${attempt})"
        "$@"; local rc=$?
        local last; last=$(tail -1 "$idx" 2>/dev/null)
        note "${label}: exit ${rc} :: $(echo "$last" | cut -c1-240)"
        if [ "$attempt" -eq 1 ] && echo "$last" | grep -q -E "$LOCKUP"; then
            note "${label}: Besu lock-up - rerunning once"; sleep 20; continue
        fi
        break
    done
    sleep 20
}

note "=== Round 3 start: CPU probe $(bash monitoring/cpu-bench.sh)s, MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, disk free $(df -BG --output=avail / | tail -1 | tr -dc 0-9)GB ==="

# ---- Test 1: latency ladder ----
L_DIR="${PERF_DIR}/reports/scalability-results/round3"
mkdir -p "$L_DIR"
for n in 4 7 10 13; do
    [ -f "network/generated/n${n}/config/genesis.json" ] && [ "$(jq -r '.config.ibft2.xblockperiodmilliseconds // empty' "network/generated/n${n}/config/genesis.json")" != "" ] \
        && node network/generate-network.mjs "$n" > /dev/null 2>&1
    run_twice "T1 ladder n=${n}" "${L_DIR}/r2-area1-index.log" \
        env P4P_RESULTS_DIR="$L_DIR" "P4P_STEPS=10 25 50" P4P_TX_POOL_MAX_SIZE=65536 P4P_NODE_HEAP_MB=1024 P4P_NODE_MEM_MB=1800 \
        bash scripts/r2-area1-ladder.sh "$n"
done

# ---- Test 2: agreement time (100 ms block period) ----
A_IDX="${PERF_DIR}/reports/scalability-results/round3-agreement/agreement-index.log"
mkdir -p "$(dirname "$A_IDX")"
for n in 4 7 10 13 16; do run_twice "T2 agreement n=${n} idle" "$A_IDX" bash scripts/r3-agreement.sh "$n" 0; done
for n in 4 7 10 13; do run_twice "T2 agreement n=${n} 10/s" "$A_IDX" bash scripts/r3-agreement.sh "$n" 10; done

# ---- Test 3: f validators offline (normal 2 s genesis again) ----
for n in 4 7 10 13; do node network/generate-network.mjs "$n" > /dev/null 2>&1; done
note "T3: regenerated 2 s genesis for n=4,7,10,13"
for n in 4 7 10 13; do
    run_twice "T3 crash-f n=${n}" "${PERF_DIR}/reports/crash-fault-results/area2-index.log" \
        env P4P_LOAD_TPS=10 P4P_HOLD_SECS=60 P4P_NODE_MEM_MB=900 P4P_NODE_HEAP_MB=512 P4P_TX_POOL_MAX_SIZE=65536 \
        bash scripts/area2-crash.sh "$n" within
done

# ---- Test 4: voter attacks at 13 validators ----
run_twice "T4 attacks n=13" "${PERF_DIR}/reports/malicious-results/area3-index.log" bash scripts/area3-attacks.sh 13 3

note "=== Round 3 complete ==="
