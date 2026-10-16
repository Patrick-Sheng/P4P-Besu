#!/bin/bash
# Area 4 driver, SCALED to what one 4-core / 7.7 GB host can measure: all five
# tests run in sequence on ONE native network (default n=4), so contract state
# accumulates and the read probes between tests double as a scaled Volume test:
#
#   probe -> load -> probe -> spike -> probe -> endurance -> probe -> stress -> probe
#
# Rates are set relative to the n=4 saturation measured in Area 1 (~120 TPS),
# not the 300-1,200 TPS of benchmarks/throughput/*.yaml (those need real
# hardware). Stress runs last because it is meant to push past saturation.
#
# Launch via scripts/run-area4.sh (detached systemd unit), not an editor terminal.
# Usage: area4-throughput.sh [nodeCount=4]
# Env (defaults): LOAD_TPS=60 LOAD_SECS=600 | SPIKE_BASE=30 SPIKE_PEAK=150 SPIKE_PRE=120 SPIKE_HOLD=60 SPIKE_POST=180
#                 ENDURANCE_TPS=40 ENDURANCE_SECS=2700 | STRESS_FROM=20 STRESS_TO=250 STRESS_SECS=300 STRESS_STEPS=10 (staircase)
#                 PROBE_READS=500 PROBE_TPS=50 | TESTS="load spike endurance stress"
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:-4}"
LOAD_TPS="${LOAD_TPS:-60}";        LOAD_SECS="${LOAD_SECS:-600}"
SPIKE_BASE="${SPIKE_BASE:-30}";    SPIKE_PEAK="${SPIKE_PEAK:-150}"
SPIKE_PRE="${SPIKE_PRE:-120}";     SPIKE_HOLD="${SPIKE_HOLD:-60}";  SPIKE_POST="${SPIKE_POST:-180}"
ENDURANCE_TPS="${ENDURANCE_TPS:-40}"; ENDURANCE_SECS="${ENDURANCE_SECS:-2700}"
STRESS_FROM="${STRESS_FROM:-20}";  STRESS_TO="${STRESS_TO:-250}";   STRESS_SECS="${STRESS_SECS:-300}"; STRESS_STEPS="${STRESS_STEPS:-10}"
PROBE_READS="${PROBE_READS:-500}"; PROBE_TPS="${PROBE_TPS:-50}"
read -r -a TESTS <<< "${TESTS:-load spike endurance stress}"
WORKERS=2

RUN_ID="n${N}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${PERF_DIR}/reports/throughput-results/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
CSV="${RUN_DIR}/summary.csv"
VOL_CSV="${RUN_DIR}/volume-probes.csv"
INDEX="${PERF_DIR}/reports/throughput-results/area4-index.log"
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
DONE_TESTS=""

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
                ABORTED="VALIDATOR_OOM_KILLED :: ${u%.service} exceeded its cgroup MemoryMax=${NODE_MEM_MB}MB (surfaced as step '${CURRENT_STEP}' exit ${rc}); ${host_state}"
                break
            fi
        done
        [ -z "$ABORTED" ] && ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited with code ${rc}; ${host_state}"
        log "CRASH_REASON=${ABORTED}"
    fi
    log "Disk: $(du -sh "${PERF_DIR}/network/generated/n${N}/data-native" 2>/dev/null | cut -f1) chain data across ${N} validators"
    systemctl --user stop "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    rm -f "${CALIPER_DIR}"/seed/generated/"${RUN_ID}"-*.json
    if [ -n "$ABORTED" ]; then
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED} (completed: ${DONE_TESTS:-none})"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' completed='${DONE_TESTS}' dir=${RUN_DIR}" >> "$INDEX"
    else
        log "RESULT: COMPLETED - ${DONE_TESTS}"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED tests='${DONE_TESTS}' dir=${RUN_DIR}" >> "$INDEX"
    fi
    [ -f "${RUN_DIR}/peak-mem.txt" ] && log "Peak cgroup memory (MB): $(cat "${RUN_DIR}/peak-mem.txt")"
}
trap finish EXIT

check_abort() {
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"; exit 2; fi
}

run_load() {  # node command in the memory-capped load unit, from caliper/
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --wait --pipe --quiet --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$CALIPER_DIR" \
        -p MemoryMax="${LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
}

rpc() { curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":${2:-[]},\"id\":1}" "$RPC_URL"; }
height() { local h; h=$(rpc eth_blockNumber | jq -r '.result // empty'); [ -n "$h" ] && printf '%d' "$h" || echo -1; }
txpool_size() { rpc txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1'; }
votes_cast() {
    (cd "$CALIPER_DIR" && node -e "
const {ethers}=require('ethers');const cfg=require('./networks/besu-n${N}.json').voting;
const a=require(require('path').resolve(cfg.contracts.VotingSystem.abiPath)).abi;
const c=new ethers.Contract(cfg.contracts.VotingSystem.address,a,new ethers.JsonRpcProvider(cfg.rpcUrls[0],undefined,{staticNetwork:true}));
Promise.all([0,1,2].map(i=>c.getTally(i))).then(t=>console.log(t.reduce((x,y)=>x+y,0n).toString())).catch(()=>console.log(-1));")
}

# --- one Caliper round: <name> <yamlRoundBody> <voterCount|0> <votersFileForReads> ---
REGISTERED=0
run_round() {
    local name="$1" body="$2" nvoters="$3" readfile="${4:-}"
    local pool="seed/generated/${RUN_ID}-${name}.json"
    if [ "$nvoters" -gt 0 ]; then
        CURRENT_STEP="${name}: register ${nvoters} voters"
        local t0; t0=$(date +%s)
        log "[${name}] generating + registering ${nvoters} voters..."
        run_load node seed/generate-voters.js "$nvoters" "$pool" >> "$LOG" 2>&1 || { check_abort; exit 1; }
        run_load node seed/register-voters.js "networks/besu-n${N}.json" "$pool" --concurrency=400 >> "$LOG" 2>&1 || { check_abort; exit 1; }
        check_abort
        REGISTERED=$((REGISTERED + nvoters))
        log "[${name}] registered in $(( $(date +%s) - t0 ))s ($(( nvoters / ( $(date +%s) - t0 + 1 ) ))/s)"
    else
        pool="$readfile"
    fi
    CURRENT_STEP="${name}: drain txpool"
    for _ in $(seq 1 60); do [ "$(txpool_size)" -le 0 ] && break; sleep 2; done

    CURRENT_STEP="${name}: caliper"
    local bench="benchmarks/throughput/${RUN_ID}-${name}.yaml"
    printf 'test:\n  workers:\n    number: %s\n  rounds:\n    - label: %s\n%s\n' "$WORKERS" "$name" \
        "$(echo "$body" | sed "s#__POOL__#${pool}#")" > "${CALIPER_DIR}/${bench}"
    rm -rf "${CALIPER_DIR}/reports/latency"
    local from to rc
    from=$(height)
    log "[${name}] running (block ${from}, MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)MB)"
    run_load npx caliper launch manager --caliper-workspace . \
        --caliper-networkconfig "networks/besu-n${N}.json" --caliper-benchconfig "$bench" \
        --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
        --caliper-report-path "${RUN_DIR}/caliper-${name}.html" > "${RUN_DIR}/caliper-${name}.log" 2>&1
    rc=$?
    to=$(height)
    mkdir -p "${RUN_DIR}/latency/${name}"
    mv "${CALIPER_DIR}"/reports/latency/*.ndjson "${RUN_DIR}/latency/${name}/" 2>/dev/null
    rm -f "${CALIPER_DIR}/${bench}"
    check_abort
    [ "$rc" -ne 0 ] && { log "[${name}] Caliper exited ${rc} - see caliper-${name}.log"; exit 1; }
    ROUND_FROM=$from; ROUND_TO=$to; ROUND_POOL=$pool
}

summarize() {  # <name> <targetTpsLabel>
    local name="$1" target="$2"
    # round-summary.js matches Caliper's table row by "sweep-n<N>-<X>tps" labels;
    # Area 4 labels differ, so feed it a copy of the log with the label rewritten
    sed -E "s/^\| ${name} +\|/| sweep-n${N}-0tps |/" "${RUN_DIR}/caliper-${name}.log" > "${RUN_DIR}/.caliper-${name}.tmp"
    node monitoring/round-summary.js "${RUN_DIR}/latency/${name}" "${RUN_DIR}/.caliper-${name}.tmp" "$CSV" "$N" "$name" "$target" "blocks ${ROUND_FROM}..${ROUND_TO}" \
        | grep -v '^ROUND_RESULT' | while read -r l; do log "[${name}] $l"; done
    rm -f "${RUN_DIR}/.caliper-${name}.tmp"
}

timeline() {  # <name> [eventsFile]
    local ev="${2:-/dev/null}"
    NODE_PATH="${CALIPER_DIR}/node_modules" node monitoring/fault-timeline.js "${RUN_DIR}/latency/${1}" "$ev" "$RPC_URL" "$ROUND_FROM" "$ROUND_TO" 10 "${RUN_DIR}/timeline-${1}.csv" > "${RUN_DIR}/timeline-${1}.txt" 2>&1
    sed -n '/Per-phase summary/,$p' "${RUN_DIR}/timeline-${1}.txt" | while read -r l; do log "[${1}] $l"; done
}

PROBE_IDX=0
probe() {  # read-latency probe at current state size (scaled Volume test)
    local readfile="$1" label="probe${PROBE_IDX}"
    PROBE_IDX=$((PROBE_IDX + 1))
    local votes; votes=$(votes_cast)
    run_round "$label" "      txNumber: ${PROBE_READS}
      rateControl: { type: fixed-rate, opts: { tps: ${PROBE_TPS} } }
      workload:
        module: workloads/read-queries.js
        arguments: { votersFile: __POOL__, numCandidates: 3 }" 0 "$readfile"
    local stats
    stats=$(node -e "
const fs=require('fs'),p=require('path');const d='${RUN_DIR}/latency/${label}';let l=[];
for(const f of fs.readdirSync(d))for(const x of fs.readFileSync(p.join(d,f),'utf8').split('\n'))if(x.trim())l.push(JSON.parse(x).latencyMs);
l.sort((a,b)=>a-b);const q=v=>l[Math.max(0,Math.ceil(v/100*l.length)-1)];
console.log([l.length,q(50),q(95),q(99),l[l.length-1]].join(','));")
    [ -f "$VOL_CSV" ] || echo "probe,height,votes_cast,voters_registered,chain_data,reads,p50_ms,p95_ms,p99_ms,max_ms" > "$VOL_CSV"
    echo "${label},${ROUND_TO},${votes},${REGISTERED},$(du -sh "${PERF_DIR}/network/generated/n${N}/data-native" | cut -f1),${stats}" >> "$VOL_CSV"
    log "[${label}] state: height ${ROUND_TO}, ${votes} votes, ${REGISTERED} voters | reads n,p50,p95,p99,max(ms) = ${stats}"
}

# ======================================================================
log "=== Area 4 (scaled) ${RUN_ID}: n=${N}, tests: ${TESTS[*]} ==="
log "load ${LOAD_TPS}TPS/${LOAD_SECS}s | spike ${SPIKE_BASE}->${SPIKE_PEAK}->${SPIKE_BASE}TPS (${SPIKE_PRE}/${SPIKE_HOLD}/${SPIKE_POST}s) | endurance ${ENDURANCE_TPS}TPS/${ENDURANCE_SECS}s | stress ${STRESS_FROM}->${STRESS_TO}TPS in ${STRESS_STEPS} steps/${STRESS_SECS}s"
log "Memory budget: ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB), slice ${SLICE_MEM_MB}MB"

CURRENT_STEP="preflight"
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

CURRENT_STEP="start-network"
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" \
    bash network/start-native.sh "$N" --light >> "$LOG" 2>&1 || exit 1
RPC_URL=$(jq -r '.validators[0].rpcUrl' "network/generated/n${N}/network-meta.json")
# stress deliberately overloads: give RPC more slack before calling a node wedged
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    --setenv=P4P_RPC_FAIL_SAMPLES=20 \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"

CURRENT_STEP="deploy"
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort
# Warm-up: both Besu 24.12.0 SyncState/BftProcessor deadlocks seen here hit a
# validator ~40s after start, when it briefly fell behind under JIT-warm-up CPU
# load just as a big registration block arrived. Let the JVMs settle first.
CURRENT_STEP="warm-up"
log "Warm-up: ${WARMUP_SECS:-60}s idle before load"
sleep "${WARMUP_SECS:-60}"
check_abort

LAST_POOL=""
for t in "${TESTS[@]}"; do
    case "$t" in
    load)
        run_round load "      txDuration: ${LOAD_SECS}
      rateControl: { type: fixed-rate, opts: { tps: ${LOAD_TPS} } }
      workload:
        module: workloads/cast-vote.js
        arguments: { votersFile: __POOL__, numCandidates: 3 }" $(( LOAD_TPS * (LOAD_SECS + 10) ))
        summarize load "$LOAD_TPS"; timeline load
        ;;
    spike)
        run_round spike "      txDuration: $((SPIKE_PRE + SPIKE_HOLD + SPIKE_POST))
      rateControl:
        type: composite-rate
        opts:
          weights: [${SPIKE_PRE}, ${SPIKE_HOLD}, ${SPIKE_POST}]
          rateControllers:
            - { type: fixed-rate, opts: { tps: ${SPIKE_BASE} } }
            - { type: fixed-rate, opts: { tps: ${SPIKE_PEAK} } }
            - { type: fixed-rate, opts: { tps: ${SPIKE_BASE} } }
      workload:
        module: workloads/cast-vote.js
        arguments: { votersFile: __POOL__, numCandidates: 3 }" $(( (SPIKE_BASE * (SPIKE_PRE + SPIKE_POST) + SPIKE_PEAK * SPIKE_HOLD) * 11 / 10 ))
        summarize spike "$SPIKE_PEAK"   # target column = peak rate
        # phase boundaries from the first submission + the composite weights
        t0=$(cat "${RUN_DIR}"/latency/spike/*.ndjson | jq -s 'map(.submitTimeMs) | min')
        printf '%s,baseline (%s TPS)\n%s,spike (%s TPS)\n%s,recovery (%s TPS)\n' \
            "$t0" "$SPIKE_BASE" "$((t0 + SPIKE_PRE * 1000))" "$SPIKE_PEAK" "$((t0 + (SPIKE_PRE + SPIKE_HOLD) * 1000))" "$SPIKE_BASE" > "${RUN_DIR}/spike-phases.csv"
        timeline spike "${RUN_DIR}/spike-phases.csv"
        ;;
    endurance)
        run_round endurance "      txDuration: ${ENDURANCE_SECS}
      rateControl: { type: fixed-rate, opts: { tps: ${ENDURANCE_TPS} } }
      workload:
        module: workloads/cast-vote.js
        arguments: { votersFile: __POOL__, numCandidates: 3 }" $(( ENDURANCE_TPS * (ENDURANCE_SECS + 10) ))
        summarize endurance "$ENDURANCE_TPS"
        # creep check: phases every ~10 min
        t0=$(cat "${RUN_DIR}"/latency/endurance/*.ndjson | jq -s 'map(.submitTimeMs) | min')
        : > "${RUN_DIR}/endurance-phases.csv"
        for ((m = 0; m * 600 < ENDURANCE_SECS; m++)); do echo "$((t0 + m * 600000)),minute $((m * 10))" >> "${RUN_DIR}/endurance-phases.csv"; done
        timeline endurance "${RUN_DIR}/endurance-phases.csv"
        ;;
    stress)
        # Staircase, not Caliper's linear-rate: linear-rate interpolates the
        # SLEEP TIME between txs linearly, so the offered TPS stays low for most
        # of the round and only shoots up at the very end. Equal fixed-rate
        # steps in one continuous round (composite-rate) keep the backlog
        # carrying over like a real ramp and give one phase row per step.
        STEP_RATES=(); STEP_W=(); STEP_RC=""
        for ((k = 0; k < STRESS_STEPS; k++)); do
            r=$(( STRESS_FROM + (STRESS_TO - STRESS_FROM) * k / (STRESS_STEPS - 1) ))
            STEP_RATES+=("$r"); STEP_W+=(1)
            STEP_RC+="
            - { type: fixed-rate, opts: { tps: ${r} } }"
        done
        STEP_SECS=$(( STRESS_SECS / STRESS_STEPS ))
        run_round stress "      txDuration: $(( STEP_SECS * STRESS_STEPS ))
      rateControl:
        type: composite-rate
        opts:
          weights: [$(IFS=,; echo "${STEP_W[*]}")]
          rateControllers:${STEP_RC}
      workload:
        module: workloads/cast-vote.js
        arguments: { votersFile: __POOL__, numCandidates: 3 }" $(( (STRESS_FROM + STRESS_TO) / 2 * (STRESS_SECS + 10) * 11 / 10 ))
        summarize stress "$STRESS_TO"   # target column = top step
        t0=$(cat "${RUN_DIR}"/latency/stress/*.ndjson | jq -s 'map(.submitTimeMs) | min')
        : > "${RUN_DIR}/stress-steps.csv"
        for k in "${!STEP_RATES[@]}"; do echo "$((t0 + k * STEP_SECS * 1000)),step ${k} (${STEP_RATES[$k]} TPS offered)" >> "${RUN_DIR}/stress-steps.csv"; done
        timeline stress "${RUN_DIR}/stress-steps.csv"
        ;;
    *) log "unknown test ${t}"; exit 1 ;;
    esac
    DONE_TESTS="${DONE_TESTS:+${DONE_TESTS} }${t}"
    LAST_POOL="$ROUND_POOL"
    probe "$LAST_POOL"
    rm -f "${CALIPER_DIR}/${LAST_POOL}.progress"
done
CURRENT_STEP="teardown"
