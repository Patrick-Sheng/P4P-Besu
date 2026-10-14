#!/bin/bash
# Additional tests T1 (tally audit across validators) and T2 (tx-pool eviction
# and client retry) - see docs/Additional Test Plan Infrastructure Evaluation.md.
# ONE scenario per invocation, same shape as area2-crash.sh: native network ->
# deploy -> register voters -> background castVote load -> optional crash-fault
# script while the load runs -> wait for the load -> analysis -> teardown.
#
#   T1 S1  n=4, no fault: T1_VOTES votes, close voting, audit every validator
#   T1 S2  n=4, crash f=1 (crash-fault.sh) during voting, resync, close, audit
#   T1 S3  n=7, crash f=2 (staggered) during voting, resync, close, audit (optional)
#   T2 V0  n=4 over-tolerance halt, repeating run n4-over-20261008-042837 (Besu default pool)
#   T2 V1  as V0 with --tx-pool-max-size=16384
#   T2 V2  as V0 with --tx-pool-max-size=65536 (watchdog stops it on HOST_MEMORY_PRESSURE)
#   T2 V3  as V0 (default pool), client resends a vote with no receipt after
#          T2_RETRY_BLOCKS new blocks, up to T2_RETRY_MAX times
#
# Launch via scripts/run-additional.sh (detached systemd unit), not an editor terminal.
# Usage: additional-fault.sh <T1|T2> <variant>
# Env (defaults):
#   all  P4P_LOAD_TPS (25) P4P_HOLD_SECS (60) P4P_STAGGER_SECS (5) P4P_BASELINE_SECS (40)
#        P4P_RUN_LABEL (empty; appended to the run id, e.g. run2)
#   T1   T1_VOTES (10000)
#   T2   P4P_LOAD_SECS (300 = the original run) T2_RECEIPT_TIMEOUT_SECS (900)
#        T2_DRAIN_TIMEOUT_SECS (900) T2_POOL_SAMPLE_SECS (2) T2_RETRY_BLOCKS (15) T2_RETRY_MAX (3)
#        memory pinned to the original run unless overridden: P4P_NODE_MEM_MB (914)
#        P4P_NODE_HEAP_MB (365) P4P_LOAD_MEM_MB (600) P4P_SLICE_MEM_MB (4359)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"
source scripts/additional-lib.sh

TEST="${1:?Usage: additional-fault.sh <T1|T2> <variant>}"
VARIANT="${2:?Usage: additional-fault.sh <T1|T2> <variant>}"
POOL_SIZE=""
RETRY=""
case "${TEST}-${VARIANT}" in
T1-S1) N=4; SCENARIO=none ;;
T1-S2) N=4; SCENARIO=within ;;
T1-S3) N=7; SCENARIO=within ;;
T2-V0) N=4; SCENARIO=over ;;
T2-V1) N=4; SCENARIO=over; POOL_SIZE=16384 ;;
T2-V2) N=4; SCENARIO=over; POOL_SIZE=65536 ;;
T2-V3) N=4; SCENARIO=over; RETRY=1 ;;
*) echo "Unknown test/variant '${TEST} ${VARIANT}' (T1: S1 S2 S3, T2: V0 V1 V2 V3)" >&2; exit 1 ;;
esac

if [ "$TEST" = T2 ]; then
    # same per-node caps as n4-over-20261008-042837, so V0 is comparable with the 31% result
    : "${P4P_NODE_MEM_MB:=914}" "${P4P_NODE_HEAP_MB:=365}" "${P4P_LOAD_MEM_MB:=600}" "${P4P_SLICE_MEM_MB:=4359}"
fi

LOAD_TPS="${P4P_LOAD_TPS:-25}"
HOLD="${P4P_HOLD_SECS:-60}"
STAGGER="${P4P_STAGGER_SECS:-5}"
BASELINE="${P4P_BASELINE_SECS:-40}"
F=$(( (N - 1) / 3 ))
case "$SCENARIO" in
none)   VICTIMS_COUNT=0; FAULT_SCRIPT="" ;;
within) VICTIMS_COUNT=$F; FAULT_SCRIPT="fault-injection/crash-fault.sh"; RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}" ;;
over)   VICTIMS_COUNT=$((F + 1)); FAULT_SCRIPT="fault-injection/crash-fault-over-tolerance.sh"; RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-600}" ;;
esac
if [ "$TEST" = T1 ]; then
    VOTES="${T1_VOTES:-10000}"
    LOAD_SECS=$(( (VOTES + LOAD_TPS - 1) / LOAD_TPS ))
    NVOTERS=$(( VOTES + 10 ))   # margin so an uneven split across the 2 workers can't exhaust one
    RECEIPT_TIMEOUT_SECS=120   # connector default; T1 has no halt
else
    LOAD_SECS="${P4P_LOAD_SECS:-300}"
    NVOTERS=$(( LOAD_TPS * (LOAD_SECS + 5) ))   # as area2-crash.sh
    RECEIPT_TIMEOUT_SECS="${T2_RECEIPT_TIMEOUT_SECS:-900}"
fi
VICTIMS=""
for ((v = N - VICTIMS_COUNT + 1; v <= N; v++)); do VICTIMS+="${v} "; done
VICTIMS="${VICTIMS% }"
SURVIVORS=$((N - VICTIMS_COUNT))

RUN_ID="${TEST}-${VARIANT}-n${N}-$(date '+%Y%m%d-%H%M%S')${P4P_RUN_LABEL:+-${P4P_RUN_LABEL}}"
RUN_DIR="${ADDITIONAL_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
CALIPER_DIR="${PERF_DIR}/caliper"
EVENTS="${RUN_DIR}/fault-events.csv"

SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
POOL_UNIT="p4p-txpool-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ---------- memory budget (same split as area1-sweep.sh / area2-crash.sh) ----------
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
TEST_RESULT="NOT RUN"   # T1: audit verdict, T2: loss summary

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
    systemctl --user stop "$WATCH_UNIT" "$LOAD_UNIT" "$POOL_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" "$POOL_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    # per-run Caliper config embeds the admin key; a key-free copy is in the run dir
    [ -n "${NET_CFG:-}" ] && rm -f "${CALIPER_DIR}/${NET_CFG}"
    cp "${PERF_DIR}"/network/generated/n"${N}"/validator*.log "$RUN_DIR/" 2>/dev/null
    if [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ]; then
        ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    fi
    if [ -z "$ABORTED" ] && [ "$rc" -ne 0 ]; then
        local cause
        cause=$(grep -vE 'JsonRpcProvider failed to detect' "$LOG" | grep -oE "(Error: .*|code: '[A-Z_]+'|ECONN[A-Z]+|TIMEOUT.*|reverted.*)" | tail -2 | tr '\n' ' ' | cut -c1-200)
        ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited with code ${rc}${cause:+ - cause: ${cause}}; ${host_state}"
        log "CRASH_REASON=${ABORTED}"
    fi
    if [ -n "$ABORTED" ]; then
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED} (fault-test=${FAULT_RESULT}, state=${STATE_RESULT}, ${TEST}=${TEST_RESULT})"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' fault-test=${FAULT_RESULT} ${TEST}='${TEST_RESULT}' dir=${RUN_DIR}" >> "$ADDITIONAL_INDEX"
    else
        log "RESULT: COMPLETED - fault-test=${FAULT_RESULT}, state-consistency=${STATE_RESULT}, ${TEST}=${TEST_RESULT}"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED fault-test=${FAULT_RESULT} state=${STATE_RESULT} ${TEST}='${TEST_RESULT}' dir=${RUN_DIR}" >> "$ADDITIONAL_INDEX"
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
pool_at() { local p; p=$(rpc_at "$1" txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1' 2>/dev/null); echo "${p:--1}"; }

# Waits until every validator reports an empty tx pool on 2 consecutive polls.
drain_pools() {  # <timeoutSecs>
    local deadline=$(( $(date +%s) + $1 )) streak=0 busy sizes u s
    while [ "$(date +%s)" -lt "$deadline" ]; do
        busy=0; sizes=""
        for u in "${RPC_URLS[@]}"; do
            s=$(pool_at "$u"); sizes+="${s} "
            [ "$s" -ne 0 ] && busy=$((busy + 1))
        done
        if [ "$busy" -eq 0 ]; then
            streak=$((streak + 1))
            if [ "$streak" -ge 2 ]; then log "Tx pools empty on all ${N} validators"; return 0; fi
        else
            streak=0
        fi
        check_abort
        sleep 3
    done
    log "WARNING: tx pools not empty after $1s (sizes: ${sizes% })"
    return 1
}

log "=== ${TEST} ${VARIANT} ${RUN_ID}: n=${N}, f=${F}, scenario=${SCENARIO}${VICTIMS:+ -> crash validator(s) ${VICTIMS} (SIGKILL, ${STAGGER}s stagger), hold ${HOLD}s} ==="
log "Load: ${LOAD_TPS} TPS castVote for ${LOAD_SECS}s ($([ "$TEST" = T1 ] && echo "exactly ${VOTES} votes" || echo "time-based")), sent to validator(s) 1..${SURVIVORS}; ${NVOTERS} voters; receipt timeout ${RECEIPT_TIMEOUT_SECS}s"
[ -n "$POOL_SIZE" ] && log "Change under test: --tx-pool-max-size=${POOL_SIZE} on every validator"
[ -n "$RETRY" ] && log "Change under test: client retry after ${T2_RETRY_BLOCKS:-15} blocks without receipt, max ${T2_RETRY_MAX:-3} resends"
log "Host: $(nproc) cores, MemTotal ${MEM_TOTAL_MB}MB, MemAvailable ${MEM_AVAIL_START_MB}MB"
log "Memory budget: slice ${SLICE_MEM_MB}MB = ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB) + loadgen ${LOAD_MEM_MB}MB"
record_run_metadata

CURRENT_STEP="preflight"
if [ "$SCENARIO" != none ] && { [ "$VICTIMS_COUNT" -lt 1 ] || [ "$SURVIVORS" -lt 1 ]; }; then
    ABORTED="BAD_SCENARIO :: n=${N} ${SCENARIO} would crash ${VICTIMS_COUNT} of ${N} validators"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ "$TEST" = T1 ] && [ "$SCENARIO" = within ] && [ "$LOAD_SECS" -lt $(( BASELINE + 2 * STAGGER * F + HOLD + 90 )) ]; then
    ABORTED="BAD_SCENARIO :: ${VOTES} votes at ${LOAD_TPS} TPS last ${LOAD_SECS}s, shorter than baseline+crash+hold+resync ($(( BASELINE + 2 * STAGGER * F + HOLD + 90 ))s) - raise T1_VOTES"
    log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ "$NODE_HEAP_MB" -lt 128 ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: per-validator heap would be ${NODE_HEAP_MB}MB for n=${N}"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
NEEDED_MB=$(( N * NODE_MEM_MB + LOAD_MEM_MB ))
if [ "$MEM_AVAIL_START_MB" -lt $(( NEEDED_MB * 60 / 100 )) ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: MemAvailable ${MEM_AVAIL_START_MB}MB is far below the ${NEEDED_MB}MB budget"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ -n "$POOL_SIZE" ] && ! besu --help 2>/dev/null | grep -q -- '--tx-pool-max-size'; then
    ABORTED="CONFIG_UNSUPPORTED :: 'besu --help' does not list --tx-pool-max-size - check the option name for this Besu version"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 'p4p-txpool-*' 2>/dev/null | awk '{print $1}'); do
    log "Stopping stale unit ${stale}"
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

CURRENT_STEP="start-network"
log "Step: starting native ${N}-validator network..."
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" P4P_TX_POOL_MAX_SIZE="$POOL_SIZE" \
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
log "Watchdog ${WATCH_UNIT} started${VICTIMS:+ (fault victims exempt: ${VICTIMS})}"

CURRENT_STEP="deploy"
log "Step: deploying VotingSystem..."
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort

CURRENT_STEP="check-txpool-config"
# record the pool limit each validator actually runs with (the plan: confirm, don't assume)
for i in "${!RPC_URLS[@]}"; do
    log "  validator$((i + 1)) txpool_besuStatistics: $(rpc_at "${RPC_URLS[$i]}" txpool_besuStatistics | jq -c '.result // .error' 2>/dev/null)"
done
MAX_SIZE=$(rpc_at "$SURVIVOR_URL" txpool_besuStatistics | jq -r '.result.maxSize // empty' 2>/dev/null)
if [ -n "$POOL_SIZE" ] && [ "$MAX_SIZE" != "$POOL_SIZE" ]; then
    ABORTED="CONFIG_NOT_APPLIED :: requested --tx-pool-max-size=${POOL_SIZE} but txpool_besuStatistics reports maxSize='${MAX_SIZE}'"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
if [ "$TEST" = T2 ] && [ -z "$POOL_SIZE" ] && [ "$MAX_SIZE" != 4096 ]; then
    log "WARNING: default pool reports maxSize='${MAX_SIZE}', not the 4096 behind the original 31% result - V0 may not be comparable"
fi

CURRENT_STEP="voters"
POOL="seed/generated/${RUN_ID}-voters.json"
log "Step: generating + registering ${NVOTERS} voters..."
run_load node seed/generate-voters.js "$NVOTERS" "$POOL" >> "$LOG" 2>&1 || { check_abort; exit 1; }
run_load node seed/register-voters.js "networks/besu-n${N}.json" "$POOL" --concurrency=200 >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort

# Load only targets validators that are never crashed (as in Area 2). T2 adds
# the client settings; the chain-side configuration is unaffected by them.
NET_CFG="networks/besu-n${N}-${RUN_ID}.json"
jq --argjson k "$SURVIVORS" --argjson rt $((RECEIPT_TIMEOUT_SECS * 1000)) --arg t2 "$TEST" \
   --argjson rb "${T2_RETRY_BLOCKS:-15}" --argjson rm "${T2_RETRY_MAX:-3}" --arg retry "$RETRY" '
    .voting.rpcUrls |= .[0:$k]
    | if $t2 == "T2" then .voting.receiptTimeoutMs = $rt | .voting.txLogDir = "reports/txlog" else . end
    | if $retry != "" then .voting.retry = { afterBlocks: $rb, maxRetries: $rm } else . end' \
    "caliper/networks/besu-n${N}.json" > "caliper/${NET_CFG}" || exit 1
jq 'del(.voting.adminPrivateKey)' "caliper/${NET_CFG}" > "${RUN_DIR}/network-config.json"   # record, minus the key

BENCH="benchmarks/additional/${RUN_ID}.yaml"
mkdir -p caliper/benchmarks/additional
LENGTH_LINE="txDuration: ${LOAD_SECS}"
[ "$TEST" = T1 ] && LENGTH_LINE="txNumber: ${VOTES}"
# label in round-summary.js's "sweep-n<N>-<X>tps" form so its parser works unchanged
cat > "${CALIPER_DIR}/${BENCH}" <<EOF
## Generated by scripts/additional-fault.sh for ${RUN_ID}
test:
  workers:
    number: 2
  rounds:
    - label: sweep-n${N}-${LOAD_TPS}tps
      description: ${TEST} ${VARIANT} background castVote load (${SCENARIO})
      ${LENGTH_LINE}
      rateControl:
        type: fixed-rate
        opts:
          tps: ${LOAD_TPS}
      workload:
        module: workloads/cast-vote.js
        arguments:
          votersFile: ${POOL}
          numCandidates: 3
EOF
cp "${CALIPER_DIR}/${BENCH}" "${RUN_DIR}/benchmark.yaml"
rm -rf "${CALIPER_DIR}/reports/latency" "${CALIPER_DIR}/reports/txlog"

if [ "$TEST" = T2 ]; then
    systemctl --user reset-failed "$POOL_UNIT" 2>/dev/null
    systemd-run --user --quiet --unit="$POOL_UNIT" --slice="$SLICE" -p MemoryMax=32M --setenv=PATH="$PATH" \
        bash "${PERF_DIR}/monitoring/txpool-sampler.sh" "$N" "$RUN_DIR" "${T2_POOL_SAMPLE_SECS:-2}"
    log "Tx-pool sampler ${POOL_UNIT} started -> txpool.csv"
fi

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
log "Background load started (block ${FROM_BLOCK})"

if [ "$SCENARIO" = none ]; then
    FAULT_RESULT="N/A"
else
    log "Baseline ${BASELINE}s before injecting faults"
    sleep "$BASELINE"
    check_abort
    log "Step: ${FAULT_SCRIPT} ${N} ${HOLD} ${STAGGER}"
    # background, so a watchdog abort ends the run immediately (as in area2-crash.sh)
    RECOVERY_TIMEOUT="$RECOVERY_TIMEOUT" FAULT_EVENTS_FILE="$EVENTS" bash "$FAULT_SCRIPT" "$N" "$HOLD" "$STAGGER" \
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
fi

CURRENT_STEP="wait-load"
log "Waiting for background load to finish (Caliper waits up to ${RECEIPT_TIMEOUT_SECS}s for each outstanding receipt)..."
waited=0
while systemctl --user is-active --quiet "$LOAD_UNIT"; do
    sleep 5; waited=$((waited + 5))
    check_abort
    if [ "$waited" -ge $((LOAD_SECS + RECEIPT_TIMEOUT_SECS + 300)) ]; then
        log "Load unit still running ${waited}s later - stopping it"; systemctl --user stop "$LOAD_UNIT"; break
    fi
done
if [ "$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)" = "oom-kill" ]; then
    ABORTED="LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during background load"; log "CRASH_REASON=${ABORTED}"; exit 2
fi
mkdir -p "${RUN_DIR}/latency"
mv "${CALIPER_DIR}"/reports/latency/*.ndjson "${RUN_DIR}/latency/" 2>/dev/null
if [ "$TEST" = T2 ]; then
    mkdir -p "${RUN_DIR}/txlog"
    mv "${CALIPER_DIR}"/reports/txlog/*.ndjson "${RUN_DIR}/txlog/" 2>/dev/null
fi

CURRENT_STEP="drain-pools"
drain_pools "${T2_DRAIN_TIMEOUT_SECS:-900}"
TO_BLOCK=$(height_at "$SURVIVOR_URL")
[ "$TEST" = T2 ] && sleep $(( ${T2_POOL_SAMPLE_SECS:-2} * 2 ))   # let the sampler record the empty pool
systemctl --user stop "$POOL_UNIT" 2>/dev/null

CURRENT_STEP="analysis"
node monitoring/round-summary.js "${RUN_DIR}/latency" "${RUN_DIR}/caliper.log" "${RUN_DIR}/summary.csv" "$N" 0 "$LOAD_TPS" "${TEST} ${VARIANT}; ${SCENARIO}${VICTIMS:+; victims ${VICTIMS}}; fault-test ${FAULT_RESULT}" \
    | grep -v '^ROUND_RESULT' | while read -r l; do log "$l"; done
grep -E 'Failed tx' "${RUN_DIR}/caliper.log" | sed -E 's/.*Failed tx [^:]*: //; s/0x[0-9a-fA-F]{64}/<hash>/g' | sort | uniq -c | sort -rn | head -5 | while read -r l; do log "  send failure: $l"; done
[ -f "$EVENTS" ] || : > "$EVENTS"
NODE_PATH="${CALIPER_DIR}/node_modules" node monitoring/fault-timeline.js "${RUN_DIR}/latency" "$EVENTS" "$SURVIVOR_URL" "$FROM_BLOCK" "$TO_BLOCK" 5 "${RUN_DIR}/timeline.csv" 2>&1 | tee -a "$LOG"

if [ "$TEST" = T1 ]; then
    CURRENT_STEP="audit"
    CONFIRMED=$(tail -1 "${RUN_DIR}/summary.csv" | cut -d, -f5)
    log "Step: close voting + audit all ${N} validators (Caliper confirmed votes: ${CONFIRMED:-unknown})"
    NODE_PATH="${CALIPER_DIR}/node_modules" node monitoring/audit-tally.js "caliper/networks/besu-n${N}.json" \
        "network/generated/n${N}/network-meta.json" "$RUN_DIR" --close-voting --expected="${CONFIRMED}" 2>&1 | tee -a "$LOG"
    case "${PIPESTATUS[0]}" in
    0) TEST_RESULT="audit PASS" ;;
    1) TEST_RESULT="audit MISMATCH (finding - see audit.csv)" ;;
    *) TEST_RESULT="audit ERROR" ;;
    esac
    if [ -f "${RUN_DIR}/audit.csv" ]; then
        [ -f "${ADDITIONAL_DIR}/T1-audit-all.csv" ] || sed -n '1s/^/run_id,/p' "${RUN_DIR}/audit.csv" > "${ADDITIONAL_DIR}/T1-audit-all.csv"
        tail -n +2 "${RUN_DIR}/audit.csv" | sed "s#^#${RUN_ID},#" >> "${ADDITIONAL_DIR}/T1-audit-all.csv"
    fi
else
    CURRENT_STEP="eviction-summary"
    NODE_PATH="${CALIPER_DIR}/node_modules" node monitoring/eviction-summary.js "$RUN_DIR" "caliper/${NET_CFG}" "$VARIANT" 2>&1 | tee -a "$LOG"
    if [ -f "${RUN_DIR}/eviction-summary.csv" ]; then
        [ -f "${ADDITIONAL_DIR}/T2-summary.csv" ] || head -1 "${RUN_DIR}/eviction-summary.csv" > "${ADDITIONAL_DIR}/T2-summary.csv"
        tail -1 "${RUN_DIR}/eviction-summary.csv" >> "${ADDITIONAL_DIR}/T2-summary.csv"
        TEST_RESULT="lost $(jq -r '"\(.votesLost)/\(.votesSent) (\(.lossPct)%)"' "${RUN_DIR}/eviction-summary.json")"
    else
        TEST_RESULT="summary ERROR"
    fi
fi
check_abort

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
