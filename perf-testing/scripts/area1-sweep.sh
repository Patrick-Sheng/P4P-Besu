#!/bin/bash
# Area 1 scalability sweep driver for ONE node count: native network start ->
# contract deploy -> per-round (register that round's voters -> drain txpool ->
# Caliper single-round launch -> percentile summary) up the TPS ladder ->
# block-time drift -> teardown.
#
# Don't run this from an editor terminal directly - use scripts/run-area1.sh,
# which launches it as a detached systemd --user unit so neither side can take
# the other down. Every heavy process runs in its own memory-capped unit under
# p4p-perf.slice (validators: p4p-besu-n<N>-v<i>, Caliper/registration:
# p4p-load-n<N>), plus a watchdog unit (p4p-watchdog-n<N>) that aborts the run
# with a labelled CRASH_REASON before the host can hit the kernel OOM killer.
#
# Usage: area1-sweep.sh <nodeCount> [tps1 tps2 ...]
#
# Each TPS level is its own Caliper launch (not one multi-round launch) so a
# crash in round k still leaves rounds 0..k-1 fully summarised, and so the
# ladder can stop once the network is clearly saturated (2 consecutive rounds
# under 80% of target) instead of piling unconfirmed backlog into later rounds.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:?Usage: area1-sweep.sh <nodeCount> [tps ...]}"
shift
TPS_LIST=("$@")
[ "${#TPS_LIST[@]}" -eq 0 ] && TPS_LIST=(10 25 50 100 150 200 250 300 400 500)

DURATION="${P4P_ROUND_SECS:-30}"
WORKERS="${P4P_WORKERS:-2}"
SAT_RATIO="${P4P_SAT_RATIO:-0.8}"

RUN_ID="n${N}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${PERF_DIR}/reports/scalability-results/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/sweep.log"
CSV="${RUN_DIR}/summary.csv"
INDEX="${PERF_DIR}/reports/scalability-results/area1-index.log"
CALIPER_DIR="${PERF_DIR}/caliper"

SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ---------- memory budget ----------
# Reserve RAM for the desktop/VS Code/Claude, cap the whole test slice at the
# rest, and split it: load generator gets a fixed share, validators split the
# remainder evenly. Heap is ~40% of each validator's cap; the rest covers
# RocksDB native memory, metaspace, code cache, Netty direct buffers, threads.
MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
DESKTOP_RESERVE_MB="${P4P_DESKTOP_RESERVE_MB:-3000}"
MEM_AVAIL_START_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
SLICE_MEM_MB=$((MEM_TOTAL_MB - DESKTOP_RESERVE_MB))
# never budget more than what is actually free now minus headroom, so a full
# slice still leaves the watchdog's MemAvailable threshold untouched
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
    systemctl --user stop "$WATCH_UNIT" 2>/dev/null
    systemctl --user stop "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
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
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED}"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' dir=${RUN_DIR}" >> "$INDEX"
    else
        log "RESULT: COMPLETED - summary: ${CSV}"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED dir=${RUN_DIR}" >> "$INDEX"
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

# Runs a node command in the memory-capped load unit, synchronously.
run_load() {
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --wait --pipe \
        --unit="$LOAD_UNIT" --slice="$SLICE" \
        --working-directory="$CALIPER_DIR" \
        -p MemoryMax="${LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
        "$@"
    local rc=$?
    local result
    result=$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)
    if [ "$result" = "oom-kill" ]; then
        echo "LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during step '${CURRENT_STEP}'" > "${RUN_DIR}/ABORT_REASON"
        log "CRASH_REASON=LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during step '${CURRENT_STEP}'"
    fi
    return $rc
}

rpc() {  # <method> [paramsJson]
    curl -s -m 5 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":${2:-[]},\"id\":1}" "$RPC_URL"
}
block_height() { rpc eth_blockNumber | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(parseInt(JSON.parse(d).result,16))}catch{console.log(-1)}})"; }
txpool_size() { rpc txpool_besuStatistics | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const r=JSON.parse(d).result;console.log(r.localCount+r.remoteCount)}catch{console.log(-1)}})"; }

log "=== Area 1 sweep ${RUN_ID}: n=${N}, TPS ladder ${TPS_LIST[*]}, ${DURATION}s/round, ${WORKERS} workers ==="
log "Host: $(nproc) cores, MemTotal ${MEM_TOTAL_MB}MB, MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, no swap"
log "Memory budget: slice ${SLICE_MEM_MB}MB = ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB) + loadgen ${LOAD_MEM_MB}MB; desktop reserve ${DESKTOP_RESERVE_MB}MB"

# ---------- preflight ----------
CURRENT_STEP="preflight"
NEEDED_MB=$(( N * NODE_MEM_MB + LOAD_MEM_MB ))
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if [ "$NODE_HEAP_MB" -lt 128 ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: per-validator heap would be ${NODE_HEAP_MB}MB (<128MB) for n=${N} within a ${SLICE_MEM_MB}MB slice - this host cannot run n=${N}"
    log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ "$AVAIL_MB" -lt $(( NEEDED_MB * 60 / 100 )) ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: MemAvailable ${AVAIL_MB}MB is far below the ${NEEDED_MB}MB budget - close other apps first"
    log "CRASH_REASON=${ABORTED}"; exit 3
fi
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 2>/dev/null | awk '{print $1}'); do
    log "Stopping stale unit ${stale}"
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

# ---------- network ----------
CURRENT_STEP="start-network"
log "Step: starting native ${N}-validator network..."
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" \
    bash network/start-native.sh "$N" --light 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1

RPC_URL=$(node -e "console.log(require('./network/generated/n${N}/network-meta.json').validators[0].rpcUrl)")

CURRENT_STEP="start-watchdog"
systemctl --user reset-failed "$WATCH_UNIT" 2>/dev/null
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M \
    --setenv=PATH="$PATH" \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"
log "Watchdog ${WATCH_UNIT} started -> ${RUN_DIR}/resources.csv"

CURRENT_STEP="deploy"
log "Step: deploying VotingSystem..."
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort
NET_CFG="networks/besu-n${N}.json"

FROM_BLOCK=$(block_height)
log "Starting block height: ${FROM_BLOCK}"

CURRENT_STEP="generate-voters"
POOL_SIZE=0
for tps in "${TPS_LIST[@]}"; do POOL_SIZE=$((POOL_SIZE + tps * (DURATION + 3))); done
POOL_FILE="seed/generated/${RUN_ID}-pool.json"
log "Step: generating voter pool (${POOL_SIZE} accounts, registered lazily per round)..."
run_load node seed/generate-voters.js "$POOL_SIZE" "$POOL_FILE" >> "$LOG" 2>&1 || { check_abort; exit 1; }
ROUND_ARGS=()
for tps in "${TPS_LIST[@]}"; do ROUND_ARGS+=("${tps}:$((DURATION + 3))"); done
run_load node seed/slice-voters.js "$POOL_FILE" "seed/generated/${RUN_ID}" "${ROUND_ARGS[@]}" >> "$LOG" 2>&1 || { check_abort; exit 1; }
rm -f "${CALIPER_DIR}/${POOL_FILE}"

# ---------- TPS ladder ----------
SATURATED_STREAK=0
for i in "${!TPS_LIST[@]}"; do
    tps="${TPS_LIST[$i]}"
    slice_file="seed/generated/${RUN_ID}-r${i}.json"

    CURRENT_STEP="round ${i} (${tps} TPS): register voters"
    log "--- Round ${i}: target ${tps} TPS --- registering $(node -e "console.log(require('./caliper/${slice_file}').length)") voters"
    run_load node seed/register-voters.js "$NET_CFG" "$slice_file" --concurrency=200 >> "$LOG" 2>&1 || { check_abort; exit 1; }
    check_abort

    CURRENT_STEP="round ${i} (${tps} TPS): drain txpool"
    for _ in $(seq 1 30); do
        [ "$(txpool_size)" -le 0 ] && break
        sleep 2
    done
    log "txpool before round: $(txpool_size) pending; MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB"

    CURRENT_STEP="round ${i} (${tps} TPS): caliper"
    bench="benchmarks/scalability/${RUN_ID}-r${i}.yaml"
    (cd "$CALIPER_DIR" && node seed/gen-sweep-yaml.js "$N" "$bench" "$DURATION" "$WORKERS" "$tps" >/dev/null)
    # gen-sweep-yaml numbers voter files by position; point this single round at its own slice
    sed -i "s#votersFile: .*#votersFile: ${slice_file}#" "${CALIPER_DIR}/${bench}"
    rm -rf "${CALIPER_DIR}/reports/latency"
    r_start=$(block_height)
    run_load npx caliper launch manager --caliper-workspace . \
        --caliper-networkconfig "$NET_CFG" --caliper-benchconfig "$bench" \
        --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
        --caliper-report-path "${RUN_DIR}/caliper-r${i}-${tps}tps.html" \
        > "${RUN_DIR}/caliper-r${i}-${tps}tps.log" 2>&1
    caliper_rc=$?
    r_end=$(block_height)
    mkdir -p "${RUN_DIR}/latency/r${i}"
    mv "${CALIPER_DIR}"/reports/latency/*.ndjson "${RUN_DIR}/latency/r${i}/" 2>/dev/null

    note="blocks ${r_start}..${r_end}"
    [ "$caliper_rc" -ne 0 ] && note="${note}; caliper exit ${caliper_rc}"
    [ -f "${RUN_DIR}/ABORT_REASON" ] && note="${note}; ABORTED: $(cut -d: -f1 "${RUN_DIR}/ABORT_REASON")"
    out=$(node monitoring/round-summary.js "${RUN_DIR}/latency/r${i}" "${RUN_DIR}/caliper-r${i}-${tps}tps.log" "$CSV" "$N" "$i" "$tps" "$note")
    echo "$out" | grep -v '^ROUND_RESULT' | while read -r l; do log "$l"; done
    check_abort
    [ "$caliper_rc" -ne 0 ] && { log "Caliper exited ${caliper_rc} - see caliper-r${i}-${tps}tps.log"; exit 1; }

    observed=$(echo "$out" | grep '^ROUND_RESULT' | sed -E 's/.*observed_tps=([0-9.]+).*/\1/')
    if node -e "process.exit(${observed:-0} < ${tps} * ${SAT_RATIO} ? 0 : 1)"; then
        SATURATED_STREAK=$((SATURATED_STREAK + 1))
        log "Round ${i} SATURATED: observed ${observed} TPS < ${SAT_RATIO} x ${tps} target (streak ${SATURATED_STREAK})"
        if [ "$SATURATED_STREAK" -ge 2 ]; then
            log "Two consecutive saturated rounds - stopping ladder at ${tps} TPS (higher targets would only grow the backlog)"
            break
        fi
    else
        SATURATED_STREAK=0
    fi
    rm -f "${CALIPER_DIR}/${slice_file}"
done

# ---------- whole-run block-time drift ----------
CURRENT_STEP="block-time-drift"
TO_BLOCK=$(block_height)
log "Block-time drift over block ${FROM_BLOCK}..${TO_BLOCK}:"
(cd "$CALIPER_DIR" && NODE_PATH="${CALIPER_DIR}/node_modules" node ../monitoring/block-time-drift.js "$RPC_URL" "$FROM_BLOCK" "$TO_BLOCK") 2>&1 | tee -a "$LOG"
check_abort
CURRENT_STEP="teardown"
log "=== n=${N} sweep finished ==="
