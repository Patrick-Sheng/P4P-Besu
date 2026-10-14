#!/bin/bash
# Additional test T3 - storage growth per empty block, per registration and
# per vote (docs/Additional Test Plan Infrastructure Evaluation.md). Fresh
# native network, no background load, one phase at a time:
#
#   read probe -> idle (T3_IDLE_SECS, empty blocks only) -> register T3_VOTERS
#   -> cast T3_VOTERS votes -> read probe
#
# Before and after each phase every validator's data directory is measured
# with `du -sb`, after a settle period (RocksDB compacts in the background, so
# sizes can jump). monitoring/storage-extrapolate.js then derives bytes per
# empty block / registration / vote and the election-scale estimate.
# The network configuration (2 s blocks, empty blocks on) is the one the
# existing results were produced with - deliberately unchanged.
#
# Launch via scripts/run-additional.sh T3 (detached systemd unit), not an editor terminal.
# Usage: t3-storage.sh [nodeCount=4]
# Env (defaults): T3_IDLE_SECS (1800) T3_VOTERS (10000) T3_VOTE_TPS (25) T3_SETTLE_SECS (60)
#                 T3_WARMUP_SECS (60) T3_PROBE_READS (500) T3_PROBE_TPS (50)
#                 T3_EXTRAP_VOTERS (2900000) T3_EXTRAP_DAYS (21) P4P_RUN_LABEL
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"
source scripts/additional-lib.sh

N="${1:-4}"
IDLE_SECS="${T3_IDLE_SECS:-1800}"
VOTERS="${T3_VOTERS:-10000}"
VOTE_TPS="${T3_VOTE_TPS:-25}"
SETTLE="${T3_SETTLE_SECS:-60}"
PROBE_READS="${T3_PROBE_READS:-500}"
PROBE_TPS="${T3_PROBE_TPS:-50}"
WORKERS=2

RUN_ID="T3-n${N}-$(date '+%Y%m%d-%H%M%S')${P4P_RUN_LABEL:+-${P4P_RUN_LABEL}}"
RUN_DIR="${ADDITIONAL_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
STORAGE_CSV="${RUN_DIR}/storage.csv"
READS_CSV="${RUN_DIR}/read-probes.csv"
CALIPER_DIR="${PERF_DIR}/caliper"
DATA_ROOT="${PERF_DIR}/network/generated/n${N}/data-native"
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
SLICE_MEM_MB="${P4P_SLICE_MEM_MB:-$SLICE_MEM_MB}"
LOAD_MEM_MB="${P4P_LOAD_MEM_MB:-600}"
NODE_MEM_MB="${P4P_NODE_MEM_MB:-$(( (SLICE_MEM_MB - LOAD_MEM_MB - 100) / N ))}"
[ "$NODE_MEM_MB" -gt 1200 ] && NODE_MEM_MB=1200
NODE_HEAP_MB="${P4P_NODE_HEAP_MB:-$(( NODE_MEM_MB * 40 / 100 ))}"

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ABORTED=""
CURRENT_STEP="init"
DONE_PHASES=""
REGISTERED=0

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
    systemctl --user stop "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    rm -f "${CALIPER_DIR}"/seed/generated/"${RUN_ID}"-*.json "${CALIPER_DIR}"/benchmarks/additional/"${RUN_ID}"-*.yaml
    if [ -n "$ABORTED" ]; then
        log "RESULT: CRASHED/ABORTED during step '${CURRENT_STEP}' - reason: ${ABORTED} (completed: ${DONE_PHASES:-none})"
        echo "$(date '+%F %T') ${RUN_ID} CRASHED step='${CURRENT_STEP}' reason='${ABORTED}' completed='${DONE_PHASES}' dir=${RUN_DIR}" >> "$ADDITIONAL_INDEX"
    else
        log "RESULT: COMPLETED - ${DONE_PHASES}"
        echo "$(date '+%F %T') ${RUN_ID} COMPLETED phases='${DONE_PHASES}' dir=${RUN_DIR}" >> "$ADDITIONAL_INDEX"
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
txpool_size() { local p; p=$(rpc txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1' 2>/dev/null); echo "${p:--1}"; }
votes_cast() {  # sum of getTally over the 3 candidates (as area4-throughput.sh)
    (cd "$CALIPER_DIR" && node -e "
const {ethers}=require('ethers');const cfg=require('./networks/besu-n${N}.json').voting;
const a=require(require('path').resolve(cfg.contracts.VotingSystem.abiPath)).abi;
const c=new ethers.Contract(cfg.contracts.VotingSystem.address,a,new ethers.JsonRpcProvider(cfg.rpcUrls[0],undefined,{staticNetwork:true}));
Promise.all([0,1,2].map(i=>c.getTally(i))).then(t=>console.log(t.reduce((x,y)=>x+y,0n).toString())).catch(()=>console.log(-1));")
}
sleep_checked() {  # <secs> : sleep in slices so a watchdog abort ends the run promptly
    local left="$1"
    while [ "$left" -gt 0 ]; do
        sleep $(( left < 10 ? left : 10 )); left=$(( left - 10 )); check_abort
    done
}

# One row per validator: phase, point (start|end), time, height, registered voters, on-chain votes, bytes
measure() {  # <phase> <start|end>
    CURRENT_STEP="$1: measure $2"
    log "[$1/$2] settling ${SETTLE}s before measuring"
    sleep_checked "$SETTLE"
    local ts h votes i dir tot db sizes=""
    ts=$(date +%s%3N); h=$(height); votes=$(votes_cast)
    for ((i = 1; i <= N; i++)); do
        dir="${DATA_ROOT}/validator${i}"
        # du on a live RocksDB can race with compaction deleting files; the total is still printed
        tot=$(du -sb "$dir" 2>/dev/null | cut -f1)
        db=""
        [ -d "${dir}/database" ] && db=$(du -sb "${dir}/database" 2>/dev/null | cut -f1)
        echo "$1,$2,${ts},${h},${REGISTERED},${votes},validator${i},${tot},${db}" >> "$STORAGE_CSV"
        sizes+="v${i}=$(( ${tot:-0} / 1048576 ))MB "
    done
    log "[$1/$2] height ${h}, ${REGISTERED} registered, ${votes} votes on chain | ${sizes% }"
}

caliper_round() {  # <name> <yaml round body after "label:"> -> latency in RUN_DIR/latency/<name>
    local name="$1" body="$2" bench="benchmarks/additional/${RUN_ID}-${1}.yaml" rc
    mkdir -p "${CALIPER_DIR}/benchmarks/additional"
    printf 'test:\n  workers:\n    number: %s\n  rounds:\n    - label: %s\n%s\n' "$WORKERS" "$name" "$body" > "${CALIPER_DIR}/${bench}"
    cp "${CALIPER_DIR}/${bench}" "${RUN_DIR}/benchmark-${name}.yaml"
    rm -rf "${CALIPER_DIR}/reports/latency"
    run_load npx caliper launch manager --caliper-workspace . \
        --caliper-networkconfig "networks/besu-n${N}.json" --caliper-benchconfig "$bench" \
        --caliper-flow-skip-install --caliper-flow-skip-start --caliper-flow-skip-end \
        --caliper-report-path "${RUN_DIR}/caliper-${name}.html" > "${RUN_DIR}/caliper-${name}.log" 2>&1
    rc=$?
    mkdir -p "${RUN_DIR}/latency/${name}"
    mv "${CALIPER_DIR}"/reports/latency/*.ndjson "${RUN_DIR}/latency/${name}/" 2>/dev/null
    check_abort
    [ "$rc" -ne 0 ] && { log "[${name}] Caliper exited ${rc} - see caliper-${name}.log"; exit 1; }
    return 0
}

probe() {  # <label> : getTally/getVoterState latency at the current state size
    CURRENT_STEP="read probe ${1}"
    caliper_round "$1" "      txNumber: ${PROBE_READS}
      rateControl: { type: fixed-rate, opts: { tps: ${PROBE_TPS} } }
      workload:
        module: workloads/read-queries.js
        arguments: { votersFile: ${POOL}, numCandidates: 3 }"
    local stats
    stats=$(node -e "
const fs=require('fs'),p=require('path');const d='${RUN_DIR}/latency/${1}';const by={getTally:[],getVoterState:[]};
for(const f of fs.readdirSync(d))for(const x of fs.readFileSync(p.join(d,f),'utf8').split('\n'))if(x.trim()){const r=JSON.parse(x);(by[r.verb]||(by[r.verb]=[])).push(r.latencyMs);}
const q=(l,v)=>l.length?l[Math.max(0,Math.ceil(v/100*l.length)-1)]:'';
console.log(['getTally','getVoterState'].map(k=>{const l=by[k].sort((a,b)=>a-b);return [l.length,q(l,50),q(l,95),q(l,99),l.length?l[l.length-1]:''].join(',');}).join(','));")
    [ -f "$READS_CSV" ] || echo "probe,height,registered,votes,tally_n,tally_p50_ms,tally_p95_ms,tally_p99_ms,tally_max_ms,voterstate_n,voterstate_p50_ms,voterstate_p95_ms,voterstate_p99_ms,voterstate_max_ms" > "$READS_CSV"
    echo "${1},$(height),${REGISTERED},$(votes_cast),${stats}" >> "$READS_CSV"
    log "[${1}] getTally n,p50,p95,p99,max | getVoterState n,p50,p95,p99,max (ms) = ${stats}"
}

# ======================================================================
log "=== T3 storage growth ${RUN_ID}: n=${N}, idle ${IDLE_SECS}s, ${VOTERS} registrations + ${VOTERS} votes at ${VOTE_TPS} TPS, settle ${SETTLE}s ==="
log "Memory budget: ${N} x validator ${NODE_MEM_MB}MB (heap ${NODE_HEAP_MB}MB), slice ${SLICE_MEM_MB}MB"
log "Disk: $(df -h "${PERF_DIR}/network" | tail -1)"
record_run_metadata

CURRENT_STEP="preflight"
if [ "$NODE_HEAP_MB" -lt 128 ]; then
    ABORTED="INSUFFICIENT_MEMORY_PREFLIGHT :: per-validator heap would be ${NODE_HEAP_MB}MB for n=${N}"; log "CRASH_REASON=${ABORTED}"; exit 3
fi
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 'p4p-txpool-*' 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done

CURRENT_STEP="start-network"
# fresh data dirs: start-native.sh wipes data-native/ before starting
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$NODE_HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" P4P_TX_POOL_MAX_SIZE="" \
    bash network/start-native.sh "$N" --light >> "$LOG" 2>&1 || exit 1
RPC_URL=$(jq -r '.validators[0].rpcUrl' "network/generated/n${N}/network-meta.json")
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"

CURRENT_STEP="deploy"
run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort
CURRENT_STEP="warm-up"
log "Warm-up: ${T3_WARMUP_SECS:-60}s idle (as area4-throughput.sh)"
sleep_checked "${T3_WARMUP_SECS:-60}"

CURRENT_STEP="generate-voters"
# generated off-chain now so the start probe has addresses to query; registered later
POOL="seed/generated/${RUN_ID}-voters.json"
run_load node seed/generate-voters.js "$VOTERS" "$POOL" >> "$LOG" 2>&1 || { check_abort; exit 1; }
echo "phase,point,ts_ms,height,registered,votes,validator,total_bytes,database_bytes" > "$STORAGE_CSV"

probe probe-start

# --- 1. idle: empty blocks only ---
measure idle start
CURRENT_STEP="idle"
log "[idle] ${IDLE_SECS}s with no transactions (~$(( IDLE_SECS / 2 )) empty blocks)"
sleep_checked "$IDLE_SECS"
measure idle end
DONE_PHASES="idle"

# --- 2. registration ---
measure registration start
CURRENT_STEP="registration"
t0=$(date +%s)
run_load node seed/register-voters.js "networks/besu-n${N}.json" "$POOL" --concurrency=200 >> "$LOG" 2>&1 || { check_abort; exit 1; }
check_abort
REGISTERED=$VOTERS
log "[registration] ${VOTERS} voters (plus 1 openVoting tx) in $(( $(date +%s) - t0 ))s"
for _ in $(seq 1 60); do [ "$(txpool_size)" -le 0 ] && break; sleep 2; done
measure registration end
DONE_PHASES+=" registration"

# --- 3. voting ---
measure voting start
CURRENT_STEP="voting"
t0=$(date +%s)
caliper_round "sweep-n${N}-${VOTE_TPS}tps" "      txNumber: ${VOTERS}
      rateControl: { type: fixed-rate, opts: { tps: ${VOTE_TPS} } }
      workload:
        module: workloads/cast-vote.js
        arguments: { votersFile: ${POOL}, numCandidates: 3 }"
node monitoring/round-summary.js "${RUN_DIR}/latency/sweep-n${N}-${VOTE_TPS}tps" "${RUN_DIR}/caliper-sweep-n${N}-${VOTE_TPS}tps.log" \
    "${RUN_DIR}/summary.csv" "$N" voting "$VOTE_TPS" "T3 voting phase" | grep -v '^ROUND_RESULT' | while read -r l; do log "[voting] $l"; done
for _ in $(seq 1 60); do [ "$(txpool_size)" -le 0 ] && break; sleep 2; done
log "[voting] finished in $(( $(date +%s) - t0 ))s"
measure voting end
DONE_PHASES+=" voting"

probe probe-end

CURRENT_STEP="extrapolate"
node monitoring/storage-extrapolate.js "$STORAGE_CSV" --registrations="${T3_EXTRAP_VOTERS:-2900000}" \
    --votes="${T3_EXTRAP_VOTERS:-2900000}" --days="${T3_EXTRAP_DAYS:-21}" --out="${RUN_DIR}/storage-summary" 2>&1 | tee -a "$LOG"
CURRENT_STEP="teardown"
