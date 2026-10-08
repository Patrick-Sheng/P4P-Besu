#!/bin/bash
# Area 2 crash-fault driver for ONE node count and ONE scenario, on the native
# network: start network -> deploy -> register voters -> start a constant
# background castVote load -> run the fault script (SIGKILL f or f+1
# validators, hold, restart) while the load runs -> wait for the load to
# finish -> per-phase throughput/latency timeline + all-node state check ->
# teardown.
#
#   within : crash f = floor((n-1)/3) validators. Expect liveness (blocks keep
#            coming), restarted nodes resync, identical state everywhere.
#   over   : crash f+1. Expect the chain to HALT (no fork, no blocks without
#            2f+1 quorum), then resume once the nodes are restarted.
#
# Launch through scripts/run-area2.sh (detached systemd unit), not from an
# editor terminal - same containment as Area 1 (see run-area1.sh).
#
# Usage: area2-crash.sh <nodeCount> <within|over>
# Env:   P4P_HOLD_SECS (60) P4P_STAGGER_SECS (5) P4P_LOAD_TPS (25) P4P_BASELINE_SECS (40)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:?Usage: area2-crash.sh <nodeCount> <within|over>}"
SCENARIO="${2:?Usage: area2-crash.sh <nodeCount> <within|over>}"
case "$SCENARIO" in within|over) ;; *) echo "scenario must be within|over" >&2; exit 1 ;; esac

HOLD="${P4P_HOLD_SECS:-60}"
STAGGER="${P4P_STAGGER_SECS:-5}"
LOAD_TPS="${P4P_LOAD_TPS:-25}"
BASELINE="${P4P_BASELINE_SECS:-40}"
F=$(( (N - 1) / 3 ))
if [ "$SCENARIO" = "within" ]; then
    VICTIMS_COUNT=$F
    FAULT_SCRIPT="fault-injection/crash-fault.sh"
    # baseline + kills + hold + restarts + resync (<=180s/node budget, usually far less) + after
    LOAD_SECS="${P4P_LOAD_SECS:-$(( BASELINE + 2 * STAGGER * F + HOLD + 90 + 30 ))}"
else
    VICTIMS_COUNT=$((F + 1))
    FAULT_SCRIPT="fault-injection/crash-fault-over-tolerance.sh"
    # extra room: after quorum loss the validators' IBFT round timers (4s doubling
    # per round) drift out of step, and the chain can't resume until 2f+1 of them
    # land in the same round - observed 135s and >200s after restart at n=4
    RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-600}"
    LOAD_SECS="${P4P_LOAD_SECS:-$(( BASELINE + 2 * STAGGER * (F + 1) + HOLD + 400 + 30 ))}"
fi
VICTIMS=""
for ((v = N - VICTIMS_COUNT + 1; v <= N; v++)); do VICTIMS+="${v} "; done
VICTIMS="${VICTIMS% }"
SURVIVORS=$((N - VICTIMS_COUNT))

RUN_ID="n${N}-${SCENARIO}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${PERF_DIR}/reports/crash-fault-results/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
INDEX="${PERF_DIR}/reports/crash-fault-results/area2-index.log"
CALIPER_DIR="${PERF_DIR}/caliper"
EVENTS="${RUN_DIR}/fault-events.csv"

SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ---------- memory budget (same split as area1-sweep.sh) ----------
MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
MEM_AVAIL_START_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
DESKTOP_RESERVE_MB="${P4P_DESKTOP_RESERVE_MB:-3000}"
SLICE_MEM_MB=$((MEM_TOTAL_MB - DESKTOP_RESERVE_MB))
[ $((MEM_AVAIL_START_MB - 900)) -lt "$SLICE_MEM_MB" ] && SLICE_MEM_MB=$((MEM_AVAIL_START_MB - 900))
SLICE_MEM_MB="${P4P_SLICE_MEM_MB:-$SLICE_MEM_MB}"
LOAD_MEM_MB="${P4P_LOAD_MEM_MB:-600}"
NODE_MEM_MB="${P4P_NODE_MEM_MB:-$(( (SLICE_MEM_MB - LOAD_MEM_MB - 100) / N ))}"
[ "$NODE_MEM_MB" -gt 1200 ] && NODE_MEM_MB=1200
NODE_HEAP_MB="${P4P_NODE_HEAP_MB:-$(( NODE_MEM_MB * 40 / 100 ))}"

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ABORTED=""
CURRENT_STEP="init"
FAULT_RESULT="NOT RUN"
STATE_RESULT="NOT RUN"

finish() {
    local rc=$?
    set +e
    local host_state
    host_state="MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, load $(cut -d' ' -f1 /proc/loadavg)"
    # a validator OOM often surfaces first as a client ECONNRESET/ECONNREFUSED in
    # whatever step was running; prefer the real root cause if systemd recorded one
    if [ -z "$ABORTED" ] && [ ! -f "${RUN_DIR}/ABORT_REASON" ] && [ "$rc" -ne 0 ]; then
        local u
        for u in $(systemctl --user list-units --all --plain --no-legend "p4p-besu-n${N}-v*" 2>/dev/null | awk '{print $1}'); do
            if [ "$(systemctl --user show -p Result --value "$u")" = "oom-kill" ]; then
                ABORTED="VALIDATOR_OOM_KILLED :: ${u%.service} exceeded its cgroup MemoryMax=$(( $(systemctl --user show -p MemoryMax --value "$u") / 1048576 ))MB (surfaced as step '${CURRENT_STEP}' exit ${rc}); ${host_state}"
                log "CRASH_REASON=${ABORTED}"
                break
            fi
        done
    fi
    systemctl --user stop "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    cp "${PERF_DIR}"/network/generated/n"${N}"/validator*.log "$RUN_DIR/" 2>/dev/null
    if [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ]; then
        ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    fi
    if [ -z "$ABORTED" ] && [ "$rc" -ne 0 ]; then
        # surface the underlying error (ECONNRESET, revert, timeout...) instead of just the exit code
        local cause
        cause=$(grep -vE 'JsonRpcProvider failed to detect' "$LOG" | grep -oE "(Error: .*|code: '[A-Z_]+'|ECONN[A-Z]+|TIMEOUT.*|reverted.*)" | tail -2 | tr '\n' ' ' | cut -c1-200)
        ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited with code ${rc}${cause:+ - cause: ${cause}}; ${host_state}"
        log "CRASH_REASON=${ABORTED}"
    fi
    if [ -n "$ABORTED" ]; then
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED} (fault-test=${FAULT_RESULT}, state=${STATE_RESULT})"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' fault-test=${FAULT_RESULT} dir=${RUN_DIR}" >> "$INDEX"
    else
        log "RESULT: COMPLETED - fault-test=${FAULT_RESULT}, state-consistency=${STATE_RESULT}"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED fault-test=${FAULT_RESULT} state=${STATE_RESULT} dir=${RUN_DIR}" >> "$INDEX"
    fi
    [ -f "${RUN_DIR}/peak-mem.txt" ] && log "Peak cgroup memory (MB): $(cat "${RUN_DIR}/peak-mem.txt")"
}
trap finish EXIT

check_abort() {
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then
        ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
        exit 2
    fi
}

load_unit_args() {
    echo --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$CALIPER_DIR" \
        -p MemoryMax="${LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800
}

# Runs a node command in the memory-capped load unit, synchronously.
run_load() {
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    # shellcheck disable=SC2046
    systemd-run --user --wait --pipe $(load_unit_args) --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
    local rc=$?
    if [ "$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)" = "oom-kill" ]; then
        echo "LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during step '${CURRENT_STEP}'" > "${RUN_DIR}/ABORT_REASON"
    fi
    return $rc
}

rpc_at() {  # <url> <method> [paramsJson]
    curl -s -m 5 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" "$1"
}
height_at() { local h; h=$(rpc_at "$1" eth_blockNumber | jq -r '.result // empty'); [ -n "$h" ] && printf '%d' "$h" || echo -1; }
hash_at() { rpc_at "$1" eth_getBlockByNumber "[\"$(printf '0x%x' "$2")\", false]" | jq -r '.result.hash // empty'; }

log "=== Area 2 ${RUN_ID}: n=${N}, f=${F}, scenario=${SCENARIO} -> crash validator(s) ${VICTIMS} (SIGKILL, ${STAGGER}s stagger), hold ${HOLD}s ==="
log "Background load: ${LOAD_TPS} TPS castVote for ${LOAD_SECS}s, sent only to the ${SURVIVORS} never-crashed validator(s) (1..${SURVIVORS})"
log "Host: $(nproc) cores, MemTotal ${MEM_TOTAL_MB}MB, MemAvailable ${MEM_AVAIL_START_MB}MB, no swap"
log "Memory budget: slice ${SLICE_MEM_MB}MB = ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB) + loadgen ${LOAD_MEM_MB}MB"

CURRENT_STEP="preflight"
if [ "$VICTIMS_COUNT" -lt 1 ] || [ "$SURVIVORS" -lt 1 ]; then
    ABORTED="BAD_SCENARIO :: n=${N} ${SCENARIO} would crash ${VICTIMS_COUNT} of ${N} validators"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ "$NODE_HEAP_MB" -lt 128 ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: per-validator heap would be ${NODE_HEAP_MB}MB for n=${N}"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 2>/dev/null | awk '{print $1}'); do
    log "Stopping stale unit ${stale}"
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

CURRENT_STEP="start-network"
log "Step: starting native ${N}-validator network..."
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" \
    bash network/start-native.sh "$N" --light >> "$LOG" 2>&1 || exit 1
mapfile -t RPC_URLS < <(jq -r '.validators[].rpcUrl' "network/generated/n${N}/network-meta.json")
SURVIVOR_URL="${RPC_URLS[0]}"

CURRENT_STEP="start-watchdog"
systemctl --user reset-failed "$WATCH_UNIT" 2>/dev/null
# stall threshold must outlast the deliberate over-tolerance halt + IBFT backoff
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M \
    --setenv=PATH="$PATH" --setenv=P4P_FAULT_VICTIMS="$VICTIMS" \
    --setenv=P4P_RPC_FAIL_SAMPLES="${P4P_RPC_FAIL_SAMPLES:-5}" \
    --setenv=P4P_STALL_SECS="$([ "$SCENARIO" = over ] && echo $((HOLD + 2 * STAGGER * (F + 1) + RECOVERY_TIMEOUT + 60)) || echo 60)" \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$SURVIVOR_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"
log "Watchdog ${WATCH_UNIT} started (fault victims exempt: ${VICTIMS})"

CURRENT_STEP="deploy"
log "Step: deploying VotingSystem..."
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort

CURRENT_STEP="voters"
POOL="seed/generated/${RUN_ID}-voters.json"
NVOTERS=$(( LOAD_TPS * (LOAD_SECS + 5) ))
log "Step: generating + registering ${NVOTERS} voters..."
run_load node seed/generate-voters.js "$NVOTERS" "$POOL" >> "$LOG" 2>&1 || { check_abort; exit 1; }
run_load node seed/register-voters.js "networks/besu-n${N}.json" "$POOL" --concurrency=200 >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort

# Load only targets validators that are never crashed: a real client would
# fail over too, and sending to a dead endpoint would only measure connection
# errors, not consensus behaviour.
NET_CFG="networks/besu-n${N}-area2.json"
jq --argjson k "$SURVIVORS" '.voting.rpcUrls |= .[0:$k]' "caliper/networks/besu-n${N}.json" > "caliper/${NET_CFG}"
BENCH="benchmarks/crash-fault/${RUN_ID}.yaml"
mkdir -p caliper/benchmarks/crash-fault
(cd "$CALIPER_DIR" && node seed/gen-sweep-yaml.js "$N" "$BENCH" "$LOAD_SECS" 2 "$LOAD_TPS" >/dev/null)
sed -i "s#votersFile: .*#votersFile: ${POOL}#" "${CALIPER_DIR}/${BENCH}"
rm -rf "${CALIPER_DIR}/reports/latency"

CURRENT_STEP="load+fault"
FROM_BLOCK=$(height_at "$SURVIVOR_URL")
systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
# shellcheck disable=SC2046
systemd-run --user --quiet $(load_unit_args) --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
    -p StandardOutput="file:${RUN_DIR}/caliper.log" -p StandardError="append:${RUN_DIR}/caliper.log" \
    npx caliper launch manager --caliper-workspace . \
    --caliper-networkconfig "$NET_CFG" --caliper-benchconfig "$BENCH" \
    --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
    --caliper-report-path "${RUN_DIR}/caliper.html"
log "Background load started (block ${FROM_BLOCK}); baseline ${BASELINE}s before injecting faults"
sleep "$BASELINE"
check_abort

log "Step: ${FAULT_SCRIPT} ${N} ${HOLD} ${STAGGER}"
# run the fault script in the background so a watchdog abort (e.g. a survivor
# OOM-killed mid-halt) ends the run immediately instead of after the fault
# script's own recovery timeout
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}" FAULT_EVENTS_FILE="$EVENTS" bash "$FAULT_SCRIPT" "$N" "$HOLD" "$STAGGER" \
    > >(tee -a "$LOG" "${RUN_DIR}/fault-script.log") 2>&1 &
fault_pid=$!
while kill -0 "$fault_pid" 2>/dev/null; do
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then
        log "Watchdog abort during fault script - stopping it"
        pkill -P "$fault_pid" 2>/dev/null; kill "$fault_pid" 2>/dev/null
        FAULT_RESULT="INTERRUPTED"
        check_abort
    fi
    sleep 2
done
wait "$fault_pid"
fault_rc=$?
FAULT_RESULT=$([ "$fault_rc" -eq 0 ] && echo PASS || echo FAIL)
log "Fault script finished: ${FAULT_RESULT} (exit ${fault_rc})"
check_abort

CURRENT_STEP="wait-load"
log "Waiting for background load to finish..."
waited=0
while systemctl --user is-active --quiet "$LOAD_UNIT"; do
    sleep 5; waited=$((waited + 5))
    check_abort
    if [ "$waited" -ge $((LOAD_SECS + 300)) ]; then
        log "Load unit still running ${waited}s later - stopping it"; systemctl --user stop "$LOAD_UNIT"; break
    fi
done
if [ "$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)" = "oom-kill" ]; then
    ABORTED="LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during background load"; log "CRASH_REASON=${ABORTED}"; exit 2
fi
TO_BLOCK=$(height_at "$SURVIVOR_URL")
mkdir -p "${RUN_DIR}/latency"
mv "${CALIPER_DIR}"/reports/latency/*.ndjson "${RUN_DIR}/latency/" 2>/dev/null

CURRENT_STEP="analysis"
node monitoring/round-summary.js "${RUN_DIR}/latency" "${RUN_DIR}/caliper.log" "${RUN_DIR}/summary.csv" "$N" 0 "$LOAD_TPS" "${SCENARIO}; victims ${VICTIMS}; fault-test ${FAULT_RESULT}" \
    | grep -v '^ROUND_RESULT' | while read -r l; do log "$l"; done
grep -E 'Failed tx' "${RUN_DIR}/caliper.log" | sed -E 's/.*Failed tx [^:]*: //; s/0x[0-9a-fA-F]{64}/<hash>/g' | sort | uniq -c | sort -rn | head -5 | while read -r l; do log "  send failure: $l"; done
NODE_PATH="${CALIPER_DIR}/node_modules" node monitoring/fault-timeline.js "${RUN_DIR}/latency" "$EVENTS" "$SURVIVOR_URL" "$FROM_BLOCK" "$TO_BLOCK" 5 "${RUN_DIR}/timeline.csv" 2>&1 | tee -a "$LOG"

CURRENT_STEP="state-consistency"
# every validator - including the crashed+restarted ones - must report the
# same block hash at a common recent height (same hash => same state root)
sleep 10
min_h=-1
for u in "${RPC_URLS[@]}"; do
    h=$(height_at "$u")
    if [ "$h" -lt 0 ]; then min_h=-2; log "  ${u}: unreachable"; break; fi
    if [ "$min_h" -lt 0 ] || [ "$h" -lt "$min_h" ]; then min_h=$h; fi
done
if [ "$min_h" -lt 0 ]; then
    STATE_RESULT="FAIL(unreachable node)"
else
    check_h=$((min_h - 2))
    ref=$(hash_at "$SURVIVOR_URL" "$check_h")
    STATE_RESULT="PASS"
    for i in "${!RPC_URLS[@]}"; do
        hsh=$(hash_at "${RPC_URLS[$i]}" "$check_h")
        log "  validator$((i + 1)) block #${check_h} ${hsh}"
        [ "$hsh" = "$ref" ] && [ -n "$ref" ] || STATE_RESULT="FAIL(hash mismatch at #${check_h})"
    done
fi
log "All-node state consistency at block #${check_h:-?}: ${STATE_RESULT}"
CURRENT_STEP="teardown"
