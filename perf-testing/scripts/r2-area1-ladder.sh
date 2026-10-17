#!/bin/bash
# Round 2 (election-scale plan, Section 5) Area 1 scalability ladder for ONE
# validator count: fresh chain -> wait for n-1 peers -> 5 min idle baseline ->
# 5 min load steps (50/100/150/200 votes/s by default), each with its voters
# registered beforehand and the pool drained afterwards -> per-step
# sustainability verdict -> teardown.
#
# Unlike round 1's area1-sweep.sh (heap scaled with n, 30 s rounds, default
# pool), every size here gets the SAME fixed heap, cgroup cap and enlarged
# pool, so points on the curve are comparable.
#
# A step is sustainable (plan Section 6.4) if success >= 99.9 %, p95 <= 6 s,
# the pool does not trend upward (least-squares slope <= P4P_POOL_SLOPE_MAX
# tx/s) and mean block time is within 2.0-2.2 s. Load steps stop at the first
# unsustainable step.
#
# Exit codes: 0 = size passed, keep climbing; 10 = breaking point reached
# (stop climbing); anything else = driver error.
#
# Launch via scripts/run-r2-area1.sh (detached systemd unit), never from an
# editor terminal (see the OOM notes in scripts/run-area1.sh).
# Usage: r2-area1-ladder.sh <nodeCount>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:?Usage: r2-area1-ladder.sh <nodeCount>}"
read -r -a STEPS <<< "${P4P_STEPS:-50 100 150 200}"
STEP_SECS="${P4P_STEP_SECS:-300}"
IDLE_SECS="${P4P_IDLE_SECS:-300}"
WORKERS="${P4P_WORKERS:-2}"
HEAP_MB="${P4P_NODE_HEAP_MB:-1024}"
NODE_MEM_MB="${P4P_NODE_MEM_MB:-1800}"
POOL_SIZE="${P4P_TX_POOL_MAX_SIZE:-16384}"
LOAD_MEM_MB="${P4P_LOAD_MEM_MB:-1536}"
POOL_SLOPE_MAX="${P4P_POOL_SLOPE_MAX:-1.0}"
REG_WINDOW="${P4P_REG_WINDOW:-500}"

RESULTS_DIR="${PERF_DIR}/reports/r2-scalability"
RUN_ID="n${N}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
STEPS_CSV="${RUN_DIR}/steps.csv"
INDEX="${RESULTS_DIR}/r2-area1-index.log"
CALIPER_DIR="${PERF_DIR}/caliper"
GEN_DIR="${PERF_DIR}/network/generated/n${N}"

SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
SAMPLER_UNIT="p4p-sampler-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
phase() { echo "$1" > "${RUN_DIR}/phase"; }

MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SLICE_MEM_MB="${P4P_SLICE_MEM_MB:-$((MEM_TOTAL_MB - ${P4P_DESKTOP_RESERVE_MB:-2500}))}"

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ABORTED=""
BREAK_REASON=""
CURRENT_STEP="init"
MAX_SUSTAINABLE=0

finish() {
    local rc=$?
    set +e
    phase teardown
    local host_state u
    host_state="MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, load $(cut -d' ' -f1 /proc/loadavg)"
    [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ] && ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    if [ -z "$ABORTED" ] && [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]; then
        for u in $(systemctl --user list-units --all --plain --no-legend "p4p-besu-n${N}-v*" 2>/dev/null | awk '{print $1}'); do
            if [ "$(systemctl --user show -p Result --value "$u")" = "oom-kill" ]; then
                ABORTED="VALIDATOR_OOM_KILLED :: ${u%.service} hit MemoryMax=${NODE_MEM_MB}MB during '${CURRENT_STEP}'"
                break
            fi
        done
        [ -z "$ABORTED" ] && ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited with code ${rc}; ${host_state}"
        log "CRASH_REASON=${ABORTED}"
    fi
    # round changes over the whole run, per validator
    local rc_total=0 c
    for ((k = 1; k <= N; k++)); do
        c=$(grep -c -E 'round [0-9]+ expired' "${GEN_DIR}/validator${k}.log" 2>/dev/null); rc_total=$((rc_total + ${c:-0}))
    done
    log "Round expiries (all validators, whole run): ${rc_total}"
    systemctl --user stop "$SAMPLER_UNIT" "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$SAMPLER_UNIT" "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    mkdir -p "${RUN_DIR}/node-logs"
    for ((k = 1; k <= N; k++)); do
        grep -E 'WARN|ERROR|expired' "${GEN_DIR}/validator${k}.log" 2>/dev/null | tail -200 > "${RUN_DIR}/node-logs/validator${k}-warn.log"
    done
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    # crash/OOM/stall/memory pressure (watchdog ABORT_REASON or a validator
    # oom-kill) count as the breaking point (plan Section 5); a driver/config
    # error does not - it stops the ladder as an ERROR to be fixed and rerun
    if [ -n "$ABORTED" ] && [[ "$ABORTED" == DRIVER_ERROR* || "$ABORTED" == CONFIG_* ]]; then
        log "RESULT: ERROR during '${CURRENT_STEP}' - ${ABORTED}"
        echo "$(date '+%F %T') ${RUN_ID} ERROR step='${CURRENT_STEP}' reason='${ABORTED}' dir=${RUN_DIR}" >> "$INDEX"
        exit 1
    elif [ -n "$ABORTED" ]; then
        BREAK_REASON="${BREAK_REASON:-$ABORTED}"
        log "RESULT: BREAKING POINT at n=${N} during '${CURRENT_STEP}' - ${BREAK_REASON}; max sustainable ${MAX_SUSTAINABLE} votes/s"
        echo "$(date '+%F %T') ${RUN_ID} BREAK step='${CURRENT_STEP}' max_sustainable=${MAX_SUSTAINABLE} reason='${BREAK_REASON}' dir=${RUN_DIR}" >> "$INDEX"
        exit 10
    elif [ -n "$BREAK_REASON" ]; then
        log "RESULT: BREAKING POINT at n=${N} - ${BREAK_REASON}; max sustainable ${MAX_SUSTAINABLE} votes/s"
        echo "$(date '+%F %T') ${RUN_ID} BREAK max_sustainable=${MAX_SUSTAINABLE} reason='${BREAK_REASON}' dir=${RUN_DIR}" >> "$INDEX"
        exit 10
    else
        log "RESULT: PASSED - max sustainable ${MAX_SUSTAINABLE} votes/s"
        echo "$(date '+%F %T') ${RUN_ID} PASS max_sustainable=${MAX_SUSTAINABLE} dir=${RUN_DIR}" >> "$INDEX"
        exit 0
    fi
}
trap finish EXIT

check_abort() {
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"; exit 2; fi
}

run_load() {
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --wait --pipe --quiet \
        --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$CALIPER_DIR" \
        -p MemoryMax="${LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
    local rc=$?
    if [ "$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)" = "oom-kill" ]; then
        echo "LOADGEN_OOM_KILLED :: ${LOAD_UNIT} hit MemoryMax=${LOAD_MEM_MB}MB during '${CURRENT_STEP}'" > "${RUN_DIR}/ABORT_REASON"
    fi
    return $rc
}

rpc_at() {  # <url> <method> [params]
    curl -s -m 5 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" "$1"
}
height() { local h; h=$(rpc_at "$RPC_URL" eth_blockNumber | jq -r '.result // empty'); [ -n "$h" ] && printf '%d' "$h" || echo -1; }
block_ts() { printf '%d' "$(rpc_at "$RPC_URL" eth_getBlockByNumber "[\"$(printf '0x%x' "$1")\",false]" | jq -r '.result.timestamp')"; }
pool_size() { rpc_at "$RPC_URL" txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1'; }
round_expiries() {
    local t=0 c
    for ((k = 1; k <= N; k++)); do c=$(grep -c -E 'round [0-9]+ expired' "${GEN_DIR}/validator${k}.log" 2>/dev/null); t=$((t + ${c:-0})); done
    echo "$t"
}
mean_block_time() {  # <fromBlock> <toBlock>
    local a="$1" b="$2"
    [ "$b" -le "$a" ] && { echo 0; return; }
    echo "scale=3; ($(block_ts "$b") - $(block_ts "$a")) / ($b - $a)" | bc
}
kv() { echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2}'; }

log "=== Round 2 Area 1 ${RUN_ID}: n=${N}, idle ${IDLE_SECS}s, steps ${STEPS[*]} votes/s x ${STEP_SECS}s ==="
log "Fixed per node: heap ${HEAP_MB}MB, MemoryMax ${NODE_MEM_MB}MB, --tx-pool-max-size=${POOL_SIZE}; slice ${SLICE_MEM_MB}MB; loadgen ${LOAD_MEM_MB}MB"
log "Host: $(nproc) vCPU, MemTotal ${MEM_TOTAL_MB}MB, MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB, disk free $(df -BG --output=avail / | tail -1 | tr -dc 0-9)GB"

# ---------- preflight ----------
CURRENT_STEP="preflight"
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 'p4p-sampler-*' 'p4p-txpool-*' 2>/dev/null | awk '{print $1}'); do
    log "Stopping stale unit ${stale}"
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done
if [ ! -f "${GEN_DIR}/config/genesis.json" ]; then
    log "Generating n=${N} genesis + keys..."
    node network/generate-network.mjs "$N" >> "$LOG" 2>&1 || exit 1
fi

CPU_BENCH=$(bash monitoring/cpu-bench.sh)
log "CPU probe: ${CPU_BENCH}s (normal ~1.15s)"
if [ "$(echo "$CPU_BENCH > ${P4P_CPU_BENCH_MAX:-2.5}" | bc)" -eq 1 ]; then
    ABORTED="CONFIG_HOST_SLOW :: CPU probe ${CPU_BENCH}s > ${P4P_CPU_BENCH_MAX:-2.5}s - host throttled or power-limited; fix the host and rerun"; exit 3
fi

# ---------- network ----------
CURRENT_STEP="start-network"
log "Starting fresh ${N}-validator chain..."
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" P4P_TX_POOL_MAX_SIZE="$POOL_SIZE" \
    bash network/start-native.sh "$N" >> "$LOG" 2>&1 || exit 1
RPC_URL=$(jq -r '.validators[0].rpcUrl' "${GEN_DIR}/network-meta.json")
mapfile -t RPC_URLS < <(jq -r '.validators[].rpcUrl' "${GEN_DIR}/network-meta.json")

systemctl --user reset-failed "$WATCH_UNIT" "$SAMPLER_UNIT" 2>/dev/null
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M \
    --setenv=PATH="$PATH" --setenv=P4P_ABORT_MEM_MB=1024 --setenv=P4P_STALL_SECS=30 --setenv=P4P_STARTUP_SECS=300 \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"
phase startup
systemd-run --user --quiet --unit="$SAMPLER_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    bash "${PERF_DIR}/monitoring/r2-sampler.sh" "$N" "$RUN_DIR" "$RPC_URL"

CURRENT_STEP="wait-peers"
log "Waiting for every validator to report $((N - 1)) peers..."
deadline=$(( $(date +%s) + 300 ))
while true; do
    check_abort
    all=1; counts=""
    for u in "${RPC_URLS[@]}"; do
        p=$(rpc_at "$u" net_peerCount | jq -r '.result // empty' 2>/dev/null)
        p=$([ -n "$p" ] && printf '%d' "$p" || echo -1)
        counts+="${p} "
        [ "$p" -ne $((N - 1)) ] && all=0
    done
    [ "$all" -eq 1 ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
        BREAK_REASON="PEERING_FAILED :: not every node reached $((N - 1)) peers within 300s (counts: ${counts})"; exit 10
    fi
    sleep 5
done
log "All ${N} validators report $((N - 1)) peers; height $(height)"

# besu txpool config actually applied?
max_size=$(rpc_at "$RPC_URL" txpool_besuStatistics | jq -r '.result.maxSize // empty')
log "txpool_besuStatistics maxSize=${max_size}"
if [ "$max_size" != "$POOL_SIZE" ]; then
    ABORTED="CONFIG_NOT_APPLIED :: requested --tx-pool-max-size=${POOL_SIZE}, node reports maxSize='${max_size}'"; exit 3
fi

CURRENT_STEP="deploy"
log "Deploying VotingSystem..."
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort
NET_CFG="networks/besu-n${N}.json"
log "Contract: $(jq -r '.voting.contracts.VotingSystem.address' "${CALIPER_DIR}/${NET_CFG}")"

# ---------- idle baseline ----------
CURRENT_STEP="idle-baseline"
log "Idle baseline: ${IDLE_SECS}s, no load..."
sleep 15   # let deploy's block settle
phase idle
b0=$(height); rc0=$(round_expiries)
sleep "$IDLE_SECS"
b1=$(height); rc1=$(round_expiries)
check_abort
sleep 6   # let the sampler record the final idle sample
IDLE_STATS=$(bash monitoring/r2-phase-stats.sh "${RUN_DIR}/samples.csv" idle)
IDLE_BT=$(mean_block_time "$b0" "$b1")
log "Idle: blocks ${b0}..${b1}, mean block time ${IDLE_BT}s, round expiries $((rc1 - rc0)); ${IDLE_STATS}"
echo "n,phase,target_tps,submitted,succeeded,failed,success_pct,send_tps,observed_tps,p50_ms,p95_ms,p99_ms,mean_block_s,blocks,round_expiries,host_cpu_pct,iowait_pct,besu_cpu_pct,besu_rss_end_mb,mem_avail_min_mb,swap_max_mb,pool_start,pool_end,pool_max,pool_slope,drain_s,verdict,reasons" > "$STEPS_CSV"
echo "${N},idle,0,,,,,,,,,,${IDLE_BT},$((b1 - b0)),$((rc1 - rc0)),$(kv "$IDLE_STATS" cpu_busy),$(kv "$IDLE_STATS" iowait),$(kv "$IDLE_STATS" besu_cpu),$(kv "$IDLE_STATS" rss_end),$(kv "$IDLE_STATS" mem_avail_min),$(kv "$IDLE_STATS" swap_max),$(kv "$IDLE_STATS" pool_start),$(kv "$IDLE_STATS" pool_end),$(kv "$IDLE_STATS" pool_max),$(kv "$IDLE_STATS" pool_slope),,baseline," >> "$STEPS_CSV"
rss_end=$(kv "$IDLE_STATS" rss_end)
log "Idle RSS ${rss_end}MB total = $(( rss_end / N ))MB/node -> projected at n=19: $(( rss_end / N * 19 ))MB (plan budget ~12288MB)"

# ---------- load steps ----------
# Load and registration use loadgen/p4p-gen.js, not Caliper: the Caliper
# connector polls eth_getBlockReceipts, which is O(n^2) in Besu 24.12.0 and
# stalled the chain in the first run (reports/r2-scalability/invalid/). Voters
# are deterministic (seeded keys), so each step just takes the next index range.
GENJS="${PERF_DIR}/loadgen/p4p-gen.js"
cursor=0
for idx in "${!STEPS[@]}"; do
    tps="${STEPS[$idx]}"
    count=$(( tps * STEP_SECS ))

    CURRENT_STEP="step ${tps} votes/s: register ${count} voters"
    phase "register-${tps}"
    log "--- Step ${idx}: ${tps} votes/s --- registering voters ${cursor}..$((cursor + count))"
    t0=$(date +%s)
    run_load node "$GENJS" register --net="$NET_CFG" --from="$cursor" --to=$((cursor + count)) --window="$REG_WINDOW" \
        --state="${RUN_DIR}/register-s${idx}.progress" >> "$LOG" 2>&1 || { check_abort; exit 1; }
    check_abort
    log "Registered ${count} voters in $(( $(date +%s) - t0 ))s ($(( count / ( $(date +%s) - t0 + 1 ) )) regs/s)"
    for _ in $(seq 1 60); do [ "$(pool_size)" -le 0 ] && break; sleep 2; done

    CURRENT_STEP="step ${tps} votes/s: load"
    phase "load-${tps}"
    out="${RUN_DIR}/step-${tps}.csv"
    s0=$(height); rc0=$(round_expiries)
    run_load node "$GENJS" vote --net="$NET_CFG" --from="$cursor" --count="$count" --rate="$tps" --out="$out" \
        --label="n${N}-${tps}" --drain-secs=180 >> "$LOG" 2>&1
    gen_rc=$?
    s1=$(height); rc1=$(round_expiries)
    cursor=$((cursor + count))
    sleep 6
    STATS=$(bash monitoring/r2-phase-stats.sh "${RUN_DIR}/samples.csv" "load-${tps}")

    CURRENT_STEP="step ${tps} votes/s: drain"
    phase "drain-${tps}"
    d0=$(date +%s)
    for _ in $(seq 1 90); do [ "$(pool_size)" -le 0 ] && break; sleep 2; done
    drain_s=$(( $(date +%s) - d0 )); left=$(pool_size)
    check_abort

    sj="${out}.summary.json"
    IFS='|' read -r submitted succeeded failed succ_pct send_tps observed p50 p95 p99 <<< "$(jq -r \
        '[.sent, .ok, (.reverted + .dropped + .sendErrors), .successPct, .sendRate, .throughput, .latencyMs.p50, .latencyMs.p95, .latencyMs.p99] | map(if . == null then "" else tostring end) | join("|")' "$sj" 2>/dev/null)"
    log "n=${N} ${tps} votes/s: $(jq -c '{sent, ok, reverted, dropped, sendErrors, successPct, sendRate, throughput, latencyMs, sendLagMs}' "$sj" 2>/dev/null)"
    bt=$(mean_block_time "$s0" "$s1")
    slope=$(kv "$STATS" pool_slope)

    reasons=""
    [ "$gen_rc" -ne 0 ] && reasons+="generator_exit_${gen_rc};"
    [ -z "$succ_pct" ] || [ "$(echo "$succ_pct < 99.9" | bc)" -eq 1 ] && reasons+="success_${succ_pct:-none}pct;"
    [ -z "$p95" ] || [ "$(echo "${p95} > 6000" | bc)" -eq 1 ] && reasons+="p95_${p95:-none}ms;"
    [ "$(echo "$slope > $POOL_SLOPE_MAX" | bc)" -eq 1 ] && reasons+="pool_rising_${slope}tx/s;"
    [ "$(echo "$bt < 2.0 || $bt > 2.2" | bc)" -eq 1 ] && reasons+="block_time_${bt}s;"
    [ "$left" -gt 0 ] && reasons+="pool_not_drained_${left};"
    lag=""; [ -n "$send_tps" ] && [ "$(echo "$send_tps < $tps * 0.95" | bc)" -eq 1 ] && lag="loadgen_send_${send_tps}tps"
    verdict=$([ -z "$reasons" ] && echo SUSTAINABLE || echo UNSUSTAINABLE)

    echo "${N},load,${tps},${submitted},${succeeded},${failed},${succ_pct},${send_tps},${observed},${p50},${p95},${p99},${bt},$((s1 - s0)),$((rc1 - rc0)),$(kv "$STATS" cpu_busy),$(kv "$STATS" iowait),$(kv "$STATS" besu_cpu),$(kv "$STATS" rss_end),$(kv "$STATS" mem_avail_min),$(kv "$STATS" swap_max),$(kv "$STATS" pool_start),$(kv "$STATS" pool_end),$(kv "$STATS" pool_max),${slope},${drain_s},${verdict},\"${reasons}${lag}\"" >> "$STEPS_CSV"
    log "Step ${tps} votes/s: ${verdict} ${reasons}${lag} | success ${succ_pct}% p95 ${p95}ms block ${bt}s round-expiries $((rc1 - rc0)) | ${STATS} | drain ${drain_s}s"

    if [ "$verdict" = SUSTAINABLE ]; then
        MAX_SUSTAINABLE=$tps
    else
        log "Stopping load steps at first unsustainable step (${tps} votes/s)"
        break
    fi
done

CURRENT_STEP="verdict"
# plan Section 5 "stop climbing" conditions not already covered by the watchdog
[ "$MAX_SUSTAINABLE" -lt 50 ] && BREAK_REASON="MAX_SUSTAINABLE_BELOW_50 :: no load step passed (lowest ${STEPS[0]:-none} votes/s)"
swap_peak=$(awk -F, 'NR > 1 && $6 > m {m = $6} END {print m + 0}' "${RUN_DIR}/samples.csv")
[ "$swap_peak" -gt 0 ] && BREAK_REASON="${BREAK_REASON:+${BREAK_REASON}; }SWAP_USED :: ${swap_peak}MB"
mem_floor=$(awk -F, 'NR > 1 && ($5 < m || m == "") {m = $5} END {print m + 0}' "${RUN_DIR}/samples.csv")
[ "$mem_floor" -lt 1024 ] && BREAK_REASON="${BREAK_REASON:+${BREAK_REASON}; }LOW_MEMORY :: MemAvailable fell to ${mem_floor}MB"
log "Run min MemAvailable ${mem_floor}MB, swap peak ${swap_peak}MB"
CURRENT_STEP="teardown"
