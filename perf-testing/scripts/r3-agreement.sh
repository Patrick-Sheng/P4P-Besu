#!/bin/bash
# Round 3 Test 2 (agreement time) for ONE validator count and load: fresh chain
# with a 100 ms block period (Besu's test-only genesis option
# ibft2.xblockperiodmilliseconds) so a new block starts as soon as the previous
# one is agreed - the time between blocks then approximates IBFT agreement time.
#
# Block timestamps on chain have 1 s resolution, so intervals are taken from
# validator1's log (millisecond timestamps of "Produced #N" / "Imported #N").
# Round changes are counted from every validator's log in the same window.
#
# Launch via scripts/run-r3.sh (detached systemd unit), never an editor terminal.
# Usage: r3-agreement.sh <nodeCount> [votesPerSec=0]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"

N="${1:?Usage: r3-agreement.sh <nodeCount> [votesPerSec]}"
RATE="${2:-0}"
MEASURE_SECS="${P4P_MEASURE_SECS:-300}"
SETTLE_SECS="${P4P_SETTLE_SECS:-60}"
BLOCK_MS="${P4P_BLOCK_PERIOD_MS:-100}"
HEAP_MB="${P4P_NODE_HEAP_MB:-1024}"
NODE_MEM_MB="${P4P_NODE_MEM_MB:-1800}"
POOL_SIZE="${P4P_TX_POOL_MAX_SIZE:-65536}"

RESULTS_DIR="${PERF_DIR}/reports/scalability-results/round3-agreement"
RUN_ID="n${N}-r${RATE}-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
INDEX="${RESULTS_DIR}/agreement-index.log"
CSV="${RESULTS_DIR}/agreement.csv"
GEN_DIR="${PERF_DIR}/network/generated/n${N}"
CALIPER_DIR="${PERF_DIR}/caliper"
SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
SAMPLER_UNIT="p4p-sampler-n${N}"
DRIVER_UNIT="${P4P_DRIVER_UNIT:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
# 3.5 GB reserve: at n=13 under load (Test 1) Besu reached ~13 GB and the kernel's
# global OOM killer fired before the slice cap; a lower cap keeps OOM inside the slice
SLICE_MEM_MB=$((MEM_TOTAL_MB - ${P4P_DESKTOP_RESERVE_MB:-3500}))
ABORTED=""
CURRENT_STEP="init"

finish() {
    local rc=$?
    set +e
    [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ] && ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    [ -z "$ABORTED" ] && [ "$rc" -ne 0 ] && ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited ${rc}"
    systemctl --user stop "$SAMPLER_UNIT" "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    systemctl --user reset-failed "$SAMPLER_UNIT" "$WATCH_UNIT" "$LOAD_UNIT" 2>/dev/null
    mkdir -p "${RUN_DIR}/node-logs" "${RUN_DIR}/node-logs-full"
    for ((k = 1; k <= N; k++)); do
        grep -E 'WARN|ERROR|expired' "${GEN_DIR}/validator${k}.log" 2>/dev/null | tail -200 > "${RUN_DIR}/node-logs/validator${k}-warn.log"
        # full logs: scripts/r3-agreement-recompute.py takes each block's earliest
        # appearance across ALL validators (validator1 alone misses synced blocks)
        gzip -c "${GEN_DIR}/validator${k}.log" > "${RUN_DIR}/node-logs-full/validator${k}.log.gz" 2>/dev/null
    done
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
    if [ -n "$ABORTED" ]; then
        log "RESULT: ABORTED during '${CURRENT_STEP}' - ${ABORTED}"
        echo "$(date '+%F %T') ${RUN_ID} ABORTED step='${CURRENT_STEP}' reason='${ABORTED}' dir=${RUN_DIR}" >> "$INDEX"
        exit 2
    fi
    log "RESULT: COMPLETED"
    echo "$(date '+%F %T') ${RUN_ID} COMPLETED dir=${RUN_DIR}" >> "$INDEX"
}
trap finish EXIT
check_abort() { if [ -f "${RUN_DIR}/ABORT_REASON" ]; then ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"; exit 2; fi; }
run_load() {  # <cmd...> in the memory-capped load unit, synchronous
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --wait --pipe --quiet --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$CALIPER_DIR" \
        -p MemoryMax=1536M -p MemorySwapMax=0 -p OOMScoreAdjust=800 --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
}
rpc() { curl -s -m 5 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" "$1"; }

log "=== Round 3 agreement time ${RUN_ID}: n=${N}, ${BLOCK_MS} ms block period, load ${RATE} votes/s, measure ${MEASURE_SECS}s ==="
log "Per node: heap ${HEAP_MB}MB, MemoryMax ${NODE_MEM_MB}MB, pool ${POOL_SIZE}; slice ${SLICE_MEM_MB}MB; CPU probe $(bash monitoring/cpu-bench.sh)s"

CURRENT_STEP="generate"
for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 'p4p-sampler-*' 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
done
node network/generate-network.mjs "$N" --block-period-ms="$BLOCK_MS" >> "$LOG" 2>&1 || exit 1
log "Genesis ibft2: $(jq -c .config.ibft2 "${GEN_DIR}/config/genesis.json")"

CURRENT_STEP="start-network"
P4P_NODE_MEM_MB="$NODE_MEM_MB" P4P_NODE_HEAP_MB="$HEAP_MB" P4P_SLICE_MEM_MB="$SLICE_MEM_MB" P4P_TX_POOL_MAX_SIZE="$POOL_SIZE" \
    bash network/start-native.sh "$N" >> "$LOG" 2>&1 || exit 1
RPC_URL=$(jq -r '.validators[0].rpcUrl' "${GEN_DIR}/network-meta.json")
mapfile -t RPC_URLS < <(jq -r '.validators[].rpcUrl' "${GEN_DIR}/network-meta.json")
systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    --setenv=P4P_ABORT_MEM_MB=1024 --setenv=P4P_STALL_SECS=30 --setenv=P4P_STARTUP_SECS=300 \
    bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$RPC_URL" "$LOG" "$LOAD_UNIT" "$DRIVER_UNIT"
echo startup > "${RUN_DIR}/phase"
systemd-run --user --quiet --unit="$SAMPLER_UNIT" --slice="$SLICE" -p MemoryMax=64M --setenv=PATH="$PATH" \
    bash "${PERF_DIR}/monitoring/r2-sampler.sh" "$N" "$RUN_DIR" "$RPC_URL"

CURRENT_STEP="wait-peers"
deadline=$(( $(date +%s) + 300 ))
while true; do
    check_abort
    all=1
    for u in "${RPC_URLS[@]}"; do
        p=$(rpc "$u" net_peerCount | jq -r '.result // empty' 2>/dev/null)
        [ -n "$p" ] && [ "$(printf '%d' "$p")" -eq $((N - 1)) ] || all=0
    done
    [ "$all" -eq 1 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && { ABORTED="PEERING_FAILED"; exit 2; }
    sleep 5
done
log "All ${N} validators report $((N - 1)) peers"

GENPID=""
if [ "$RATE" -gt 0 ]; then
    CURRENT_STEP="deploy + register"
    run_load node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || { check_abort; exit 1; }
    count=$(( RATE * (SETTLE_SECS + MEASURE_SECS + 60) ))
    run_load node ../loadgen/p4p-gen.js register --net="networks/besu-n${N}.json" --from=0 --to="$count" --window=500 \
        --state="${RUN_DIR}/register.progress" >> "$LOG" 2>&1 || { check_abort; exit 1; }
    log "Registered ${count} voters; starting ${RATE} votes/s"
    systemctl --user reset-failed "$LOAD_UNIT" 2>/dev/null
    systemd-run --user --quiet --unit="$LOAD_UNIT" --slice="$SLICE" --working-directory="$CALIPER_DIR" \
        -p MemoryMax=1536M -p MemorySwapMax=0 -p OOMScoreAdjust=800 --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
        -p StandardOutput="append:${RUN_DIR}/load.log" -p StandardError="append:${RUN_DIR}/load.log" \
        node ../loadgen/p4p-gen.js vote --net="networks/besu-n${N}.json" --from=0 --count="$count" --rate="$RATE" \
        --out="${RUN_DIR}/votes.csv" --label="agree-n${N}" --drain-secs=60
fi

CURRENT_STEP="settle"
log "Settling ${SETTLE_SECS}s (JIT warm-up, steady state) before measuring"
sleep "$SETTLE_SECS"; check_abort

CURRENT_STEP="measure"
echo measure > "${RUN_DIR}/phase"
t0=$(date '+%Y-%m-%d %H:%M:%S.%3N'); h0=$(printf '%d' "$(rpc "$RPC_URL" eth_blockNumber | jq -r .result)")
log "Measuring ${MEASURE_SECS}s from ${t0} (height ${h0})"
sleep "$MEASURE_SECS"; check_abort
t1=$(date '+%Y-%m-%d %H:%M:%S.%3N'); h1=$(printf '%d' "$(rpc "$RPC_URL" eth_blockNumber | jq -r .result)")
echo done > "${RUN_DIR}/phase"
[ -n "$GENPID$RATE" ] && systemctl --user stop "$LOAD_UNIT" 2>/dev/null
sleep 6
STATS=$(bash monitoring/r2-phase-stats.sh "${RUN_DIR}/samples.csv" measure)

CURRENT_STEP="analyse"
python3 - "$GEN_DIR" "$N" "$t0" "$t1" "$RATE" "$h0" "$h1" "$CSV" "$RUN_ID" "$STATS" "$BLOCK_MS" <<'PY' | tee -a "$LOG"
import sys, re, os, statistics
from datetime import datetime
gen, n, t0, t1, rate, h0, h1, csv, run_id, stats, block_ms = sys.argv[1:12]
n = int(n)
fmt = '%Y-%m-%d %H:%M:%S.%f'
T0, T1 = datetime.strptime(t0, fmt), datetime.strptime(t1, fmt)
blk = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\+00:00 \| BftProcessorExecutor-IBFT-0 \| INFO  \| IbftBesuControllerBuilder \| (Produced|Imported) #([\d,]+)')
exp = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\+00:00 .*round \d+ expired')
times = {}
for line in open(os.path.join(gen, 'validator1.log'), errors='replace'):
    m = blk.match(line)
    if m:
        t = datetime.strptime(m.group(1), fmt)
        if T0 <= t <= T1:
            times.setdefault(int(m.group(3).replace(',', '')), t)
expired = 0
for k in range(1, n + 1):
    for line in open(os.path.join(gen, f'validator{k}.log'), errors='replace'):
        m = exp.match(line)
        if m and T0 <= datetime.strptime(m.group(1), fmt) <= T1:
            expired += 1
nums = sorted(times)
iv = [(times[b] - times[a]).total_seconds() * 1000 for a, b in zip(nums, nums[1:]) if b == a + 1]
kv = dict(p.split('=') for p in stats.split())
if not iv:
    print(f'ANALYSIS: no consecutive blocks in window ({len(nums)} block lines)'); sys.exit(1)
iv.sort()
p95 = iv[min(len(iv) - 1, int(len(iv) * 0.95))]
row = dict(run=run_id, n=n, load_votes_per_s=rate, block_period_ms=block_ms, blocks=int(h1) - int(h0),
           intervals=len(iv), mean_ms=round(statistics.mean(iv), 1), median_ms=round(statistics.median(iv), 1),
           p95_ms=round(p95, 1), max_ms=round(iv[-1], 1), round_expiries=expired,
           host_cpu_pct=kv.get('cpu_busy'), besu_cpu_pct=kv.get('besu_cpu'), besu_rss_mb=kv.get('rss_end'))
new = not os.path.exists(csv)
with open(csv, 'a') as f:
    if new: f.write(','.join(row) + '\n')
    f.write(','.join(str(v) for v in row.values()) + '\n')
print('AGREEMENT ' + ' '.join(f'{k}={v}' for k, v in row.items()))
PY
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
CURRENT_STEP="teardown"
