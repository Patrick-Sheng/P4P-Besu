#!/bin/bash
# Shared helpers for the round 2 (election-scale plan) 4-validator chain that
# carries Areas 4, 3 and 2 (plan Sections 6-10). Sourced by scripts/r2-run.sh.
#
# Fixed configuration (plan Section 3): 4 validators, 2 GiB heap each, cgroup
# cap 2900 MiB, SEQUENCED pool (--profile=ENTERPRISE, as round 1) enlarged to
# 65,536 so a 5-minute quorum-loss halt at 100 votes/s (30,000 votes) fits,
# metrics on every validator for Prometheus.
#
# Expects PERF_DIR (perf-testing/), RUN_DIR and LOG to be set by the caller.

N=4
# 1 GiB heap (user decision 2026-10-15): with -Xmx2g, G1 expands the committed
# heap toward 2 GiB although live data is ~0.4 GB, and off-heap (RocksDB) adds
# ~1-1.2 GB, so 4 validators could reach ~12.8 GB - more than this VM can hold
# for a multi-hour soak. Same heap as the Area 1 ladder.
R2_HEAP_MB="${P4P_NODE_HEAP_MB:-1024}"
R2_NODE_MEM_MB="${P4P_NODE_MEM_MB:-2600}"
R2_POOL="${P4P_TX_POOL_MAX_SIZE:-65536}"
R2_LOAD_MEM_MB="${P4P_LOAD_MEM_MB:-1536}"
R2_STATE="${PERF_DIR}/reports/r2-soak/state"      # contract config for this chain
R2_NET="${R2_STATE}/besu-n4.json"
R2_SNAP_ROOT="${P4P_SNAP_ROOT:-$HOME/p4p-snapshots}"
GEN_DIR="${PERF_DIR}/network/generated/n${N}"
SLICE="p4p-perf.slice"
LOAD_UNIT="p4p-load-n${N}"
ATTACK_UNIT="p4p-attack-n${N}"
WATCH_UNIT="p4p-watchdog-n${N}"
COLLECT_UNIT="p4p-collector-n${N}"
GENJS="${PERF_DIR}/loadgen/p4p-gen.js"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

rpc_at() {  # <url> <method> [params]
    curl -s -m 10 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" "$1"
}
rpc_url() { jq -r ".validators[$(( $1 - 1 ))].rpcUrl" "${GEN_DIR}/network-meta.json"; }
height_of() { local h; h=$(rpc_at "$(rpc_url "$1")" eth_blockNumber | jq -r '.result // empty' 2>/dev/null); [ -n "$h" ] && printf '%d' "$h" || echo -1; }
hash_at() { rpc_at "$(rpc_url "$1")" eth_getBlockByNumber "[\"$(printf '0x%x' "$2")\",false]" | jq -r '.result.hash // "none"'; }
block_ts() { printf '%d' "$(rpc_at "$(rpc_url 1)" eth_getBlockByNumber "[\"$(printf '0x%x' "$1")\",false]" | jq -r '.result.timestamp')"; }
pool_of() { rpc_at "$(rpc_url "${1:-1}")" txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1' 2>/dev/null; }
disk_free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
db_mb() { du -sm "${GEN_DIR}/data-native/validator${1}" 2>/dev/null | cut -f1; }
swap_mb() { awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo; }

check_abort() {
    if [ -f "${RUN_DIR}/ABORT_REASON" ]; then ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"; exit 2; fi
}

# Runs node <args> in a memory-capped unit, synchronously. <unit> lets an
# attack replay run alongside the soak generator.
run_unit() {  # <unit> <workdir> <cmd...>
    local unit="$1" wd="$2"; shift 2
    systemctl --user reset-failed "$unit" 2>/dev/null
    systemd-run --user --wait --pipe --quiet --unit="$unit" --slice="$SLICE" --working-directory="$wd" \
        -p MemoryMax="${R2_LOAD_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
        --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$@"
    local rc=$?
    if [ "$(systemctl --user show -p Result --value "$unit" 2>/dev/null)" = "oom-kill" ]; then
        echo "LOADGEN_OOM_KILLED :: ${unit} hit MemoryMax=${R2_LOAD_MEM_MB}MB" > "${RUN_DIR}/ABORT_REASON"
    fi
    return $rc
}
gen() { run_unit "$LOAD_UNIT" "$PERF_DIR" node "$GENJS" "$@" --net="$R2_NET"; }

# Starts the 4-validator chain. fresh = wipe data; keep = restart on existing
# (seeded / restored) data. Waits for 3 peers each and checks the pool size took.
chain_up() {  # fresh|keep
    local mode="$1" stale
    for stale in $(systemctl --user list-units --all --plain --no-legend 'p4p-besu-*' 'p4p-load-*' 'p4p-watchdog-*' 'p4p-sampler-*' 'p4p-attack-*' 2>/dev/null | awk '{print $1}'); do
        systemctl --user stop "$stale"; systemctl --user reset-failed "$stale" 2>/dev/null
    done
    [ -f "${GEN_DIR}/config/genesis.json" ] || { node "${PERF_DIR}/network/generate-network.mjs" "$N" >> "$LOG" 2>&1 || return 1; }
    local mem_total slice
    mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    slice=$((mem_total - ${P4P_DESKTOP_RESERVE_MB:-1500}))
    log "Starting ${N}-validator chain (${mode}): heap ${R2_HEAP_MB}MB, MemoryMax ${R2_NODE_MEM_MB}MB, --tx-pool-max-size=${R2_POOL}, metrics on, slice ${slice}MB"
    mkdir -p "$R2_STATE"; echo dirty > "${R2_STATE}/data-state"   # live chain: data no longer equals a snapshot
    P4P_NODE_MEM_MB="$R2_NODE_MEM_MB" P4P_NODE_HEAP_MB="$R2_HEAP_MB" P4P_SLICE_MEM_MB="$slice" \
        P4P_TX_POOL_MAX_SIZE="$R2_POOL" P4P_METRICS=1 P4P_KEEP_DATA=$([ "$mode" = keep ] && echo 1) \
        bash "${PERF_DIR}/network/start-native.sh" "$N" >> "$LOG" 2>&1 || return 1
    local deadline=$(( $(date +%s) + 600 )) i p all counts
    while true; do
        all=1; counts=""
        for ((i = 1; i <= N; i++)); do
            p=$(rpc_at "$(rpc_url "$i")" net_peerCount | jq -r '.result // empty' 2>/dev/null)
            p=$([ -n "$p" ] && printf '%d' "$p" || echo -1); counts+="${p} "
            [ "$p" -ne $((N - 1)) ] && all=0
        done
        [ "$all" -eq 1 ] && break
        [ "$(date +%s)" -ge "$deadline" ] && { log "Peering failed: counts ${counts}"; return 1; }
        sleep 5
    done
    local h0 h1
    h0=$(height_of 1); sleep 6; h1=$(height_of 1)
    [ "$h1" -gt "$h0" ] || { log "Chain not advancing (${h0} -> ${h1})"; return 1; }
    local max
    max=$(rpc_at "$(rpc_url 1)" txpool_besuStatistics | jq -r '.result.maxSize // empty')
    [ "$max" = "$R2_POOL" ] || { log "Pool size not applied: maxSize=${max}"; return 1; }
    log "Chain up: all validators have $((N - 1)) peers, height ${h1}, pool maxSize ${max}"
}

# Watchdog: stall threshold and fault victims are per phase (Area 2 stops
# validators and halts the chain on purpose).
watchdog_start() {  # [stallSecs] [faultVictims]
    systemctl --user stop "$WATCH_UNIT" 2>/dev/null; systemctl --user reset-failed "$WATCH_UNIT" 2>/dev/null
    systemd-run --user --quiet --unit="$WATCH_UNIT" --slice="$SLICE" -p MemoryMax=64M \
        --setenv=PATH="$PATH" --setenv=P4P_ABORT_MEM_MB=1024 --setenv=P4P_STALL_SECS="${1:-60}" \
        --setenv=P4P_FAULT_VICTIMS="${2:-}" --setenv=P4P_WATCH_INTERVAL=5 --setenv=P4P_STARTUP_SECS=600 \
        --setenv=P4P_RESTART_STUCK="${P4P_RESTART_STUCK:-}" --setenv=P4P_RESTART_ANON_MB="${P4P_RESTART_ANON_MB:-3000}" \
        bash "${PERF_DIR}/monitoring/resource-watchdog.sh" "$N" "$RUN_DIR" "$(rpc_url 1)" "$LOG" "$LOAD_UNIT" "${P4P_DRIVER_UNIT:-}"
}
watchdog_stop() { systemctl --user stop "$WATCH_UNIT" 2>/dev/null; systemctl --user reset-failed "$WATCH_UNIT" 2>/dev/null; true; }

collector_start() {  # <outCsv> [intervalSecs]
    systemctl --user stop "$COLLECT_UNIT" 2>/dev/null; systemctl --user reset-failed "$COLLECT_UNIT" 2>/dev/null
    systemd-run --user --quiet --unit="$COLLECT_UNIT" --slice=p4p-mon.slice -p MemoryMax=64M \
        --working-directory="$PERF_DIR" --setenv=PATH="$PATH" --setenv=N="$N" \
        --setenv=OUT="$1" --setenv=INTERVAL="${2:-120}" bash "${PERF_DIR}/monitoring/collector.sh"
}
collector_stop() { systemctl --user stop "$COLLECT_UNIT" 2>/dev/null; systemctl --user reset-failed "$COLLECT_UNIT" 2>/dev/null; true; }

chain_down() {  # graceful SIGTERM so RocksDB flushes (snapshots need a clean stop)
    systemctl --user stop "$ATTACK_UNIT" "$LOAD_UNIT" 2>/dev/null
    watchdog_stop
    bash "${PERF_DIR}/network/stop-native.sh" "$N" >> "$LOG" 2>&1
}

deploy() {
    run_unit "$LOAD_UNIT" "${PERF_DIR}/caliper" node deploy-and-configure.js "$N" >> "$LOG" 2>&1 || return 1
    mkdir -p "$R2_STATE"
    cp "${PERF_DIR}/caliper/networks/besu-n${N}.json" "$R2_NET"
    log "Deployed VotingSystem at $(jq -r '.voting.contracts.VotingSystem.address' "$R2_NET") (config ${R2_NET})"
}

snapshot_save() {  # <name> : chain must be down
    local dst="${R2_SNAP_ROOT}/$1"
    rm -rf "$dst"; mkdir -p "$dst"
    local t0; t0=$(date +%s)
    cp -a "${GEN_DIR}/data-native" "$dst/" && cp "$R2_NET" "$dst/" || return 1
    echo "$1" > "${R2_STATE}/data-state"
    log "Snapshot '$1': $(du -sh "$dst" | cut -f1) in $(( $(date +%s) - t0 ))s; disk free $(disk_free_gb)GB"
}
snapshot_restore() {  # <name> : chain must be down
    local src="${R2_SNAP_ROOT}/$1"
    [ -d "${src}/data-native" ] || { log "No snapshot at ${src}"; return 1; }
    local t0; t0=$(date +%s)
    rm -rf "${GEN_DIR}/data-native"
    cp -a "${src}/data-native" "${GEN_DIR}/" && mkdir -p "$R2_STATE" && cp "${src}/besu-n4.json" "$R2_NET" || return 1
    echo "$1" > "${R2_STATE}/data-state"
    rm -f "${R2_STATE}/warmup-cursor" "${R2_STATE}/reserve-cursor"   # restored chain: those voters are NotVoted again
    log "Restored snapshot '$1' in $(( $(date +%s) - t0 ))s; disk free $(disk_free_gb)GB"
}

# Mean block time (s) over blocks (a, b]
mean_block_time() {
    [ "$2" -le "$1" ] && { echo 0; return; }
    echo "scale=3; ($(block_ts "$2") - $(block_ts "$1")) / ($2 - $1)" | bc
}
