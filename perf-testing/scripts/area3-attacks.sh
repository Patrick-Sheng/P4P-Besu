#!/bin/bash
# Area 3 application-layer attack driver for ONE node count: start native
# network -> deploy -> run double-vote / equivocation / replay REPS times each
# -> per-attempt PASS/FAIL into summary.csv -> teardown. Each attack script
# also checks that every validator reports identical tallies + block hash.
#
# These are client-level attacks (a rogue voter account), not a rogue
# validator: consensus wire-protocol attacks need the patched Besu build in
# ibft-fuzzing/, which isn't built.
#
# Launch via scripts/run-area3.sh (detached systemd unit), not an editor terminal.
# Usage: area3-attacks.sh <nodeCount> [reps=3]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:?Usage: area3-attacks.sh <nodeCount> [reps]}"
REPS="${2:-3}"
ATTACKS=(double-vote equivocation replay)

RUN_ID="n${N}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${PERF_DIR}/reports/malicious-results/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
CSV="${RUN_DIR}/summary.csv"
INDEX="${PERF_DIR}/reports/malicious-results/area3-index.log"
CALIPER_DIR="${PERF_DIR}/caliper"
SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# same memory split as area1-sweep.sh
MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
MEM_AVAIL_START_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
SLICE_MEM_MB=$((MEM_TOTAL_MB - ${P4P_DESKTOP_RESERVE_MB:-3000}))
[ $((MEM_AVAIL_START_MB - 900)) -lt "$SLICE_MEM_MB" ] && SLICE_MEM_MB=$((MEM_AVAIL_START_MB - 900))
LOAD_MEM_MB=600
NODE_MEM_MB=$(( (SLICE_MEM_MB - LOAD_MEM_MB - 100) / N ))
[ "$NODE_MEM_MB" -gt 1200 ] && NODE_MEM_MB=1200
NODE_HEAP_MB=$(( NODE_MEM_MB * 40 / 100 ))

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ABORTED=""
CURRENT_STEP="init"
PASSES=0
FAILS=0

finish() {
    local rc=$?
    set +e
    local host_state
    host_state="MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, load $(cut -d' ' -f1 /proc/loadavg)"
    [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ] && ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    if [ -z "$ABORTED" ] && [ "$rc" -ne 0 ]; then
        local u
        for u in $(systemctl --user list-units --all --plain --no-legend "p4p-besu-n${N}-v*" 2>/dev/null | awk '{print $1}'); do
            if [ "$(systemctl --user show -p Result --value "$u")" = "oom-kill" ]; then
                ABORTED="VALIDATOR_OOM_KILLED :: ${u%.service} exceeded its cgroup MemoryMax (surfaced as step '${CURRENT_STEP}' exit ${rc}); ${host_state}"
                break
            fi
        done
        [ -z "$ABORTED" ] && ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited with code ${rc}; ${host_state}"
        log "CRASH_REASON=${ABORTED}"
    fi
    systemctl --user stop "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    if [ -n "$ABORTED" ]; then
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED} (attempts so far: ${PASSES} pass, ${FAILS} fail)"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' pass=${PASSES} fail=${FAILS} dir=${RUN_DIR}" >> "$INDEX"
    else
        log "RESULT: COMPLETED - ${PASSES} pass, ${FAILS} fail"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED pass=${PASSES} fail=${FAILS} dir=${RUN_DIR}" >> "$INDEX"
    fi
}
trap finish EXIT

check_abort() {
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"; exit 2; fi
}

run_load() {  # <workdir> <cmd...> : node command in the memory-capped load unit
    local wd="$1"; shift
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --wait --pipe --quiet --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$wd" \
        -p MemoryMax="${LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
}

log "=== Area 3 ${RUN_ID}: n=${N}, attacks ${ATTACKS[*]} x ${REPS} ==="
log "Memory budget: ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB), slice ${SLICE_MEM_MB}MB"

CURRENT_STEP="preflight"
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

CURRENT_STEP="start-network"
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" \
    bash network/start-native.sh "$N" --light >> "$LOG" 2>&1 || exit 1
RPC_URL=$(jq -r '.validators[0].rpcUrl' "network/generated/n${N}/network-meta.json")
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"

CURRENT_STEP="deploy"
run_load "$CALIPER_DIR" node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort

echo "nodes,attack,attempt,result,seconds" > "$CSV"
NET_CFG="${CALIPER_DIR}/networks/besu-n${N}.json"
for attack in "${ATTACKS[@]}"; do
    for rep in $(seq 1 "$REPS"); do
        CURRENT_STEP="${attack} #${rep}"
        log "--- ${attack} attempt ${rep}/${REPS} ---"
        t0=$(date +%s)
        run_load "${PERF_DIR}/fault-injection" node "malicious/${attack}.js" "$NET_CFG" > "${RUN_DIR}/${attack}-${rep}.log" 2>&1
        rc=$?
        sed 's/^/    /' "${RUN_DIR}/${attack}-${rep}.log" | grep -vE '^\s+at ' | tee -a "$LOG" >/dev/null
        check_abort
        result=$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)
        [ "$result" = PASS ] && PASSES=$((PASSES + 1)) || FAILS=$((FAILS + 1))
        echo "${N},${attack},${rep},${result},$(( $(date +%s) - t0 ))" >> "$CSV"
        log "${attack} attempt ${rep}: ${result}"
    done
done
CURRENT_STEP="teardown"
