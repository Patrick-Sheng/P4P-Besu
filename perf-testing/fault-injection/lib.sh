#!/bin/bash
# Shared helpers for the crash-fault and malicious-node scripts.
# Source this, don't execute it directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Loads perf-testing/network/generated/n<N>/network-meta.json and exports:
#   META_PATH, NODE_COUNT, MAX_FAULTS, BACKEND, RPC_URLS[], CONTAINER_NAMES[]
# BACKEND is "native" for networks from network/start-native.sh (validators
# are systemd --user units driven by network/node-ctl.sh) and "docker" for
# networks from generate-network.mjs + docker compose.
load_network_meta() {
    local n="$1"
    META_PATH="$REPO_ROOT/perf-testing/network/generated/n${n}/network-meta.json"
    if [ ! -f "$META_PATH" ]; then
        echo "No generated network metadata at $META_PATH - run generate-network.mjs $n first" >&2
        exit 1
    fi
    NODE_COUNT=$(jq -r '.nodeCount' "$META_PATH")
    MAX_FAULTS=$(jq -r '.maxTolerableFaults' "$META_PATH")
    mapfile -t RPC_URLS < <(jq -r '.validators[].rpcUrl' "$META_PATH")
    BACKEND=$(jq -r '.backend // "docker"' "$META_PATH")
    if [ "$BACKEND" = "native" ]; then
        mapfile -t CONTAINER_NAMES < <(jq -r '.validators[].unit' "$META_PATH")
    else
        mapfile -t CONTAINER_NAMES < <(jq -r '.validators[].containerName' "$META_PATH")
    fi
}

# Crash validator at 0-based index. Native: SIGKILL (unclean crash).
# Docker: docker stop (SIGTERM, then SIGKILL after docker's grace period).
node_crash() {
    local idx="$1"
    record_event "crash validator$((idx + 1))"
    if [ "$BACKEND" = "native" ]; then
        bash "$REPO_ROOT/perf-testing/network/node-ctl.sh" "$NODE_COUNT" "$((idx + 1))" crash
    else
        docker stop "${CONTAINER_NAMES[$idx]}" >/dev/null
    fi
}

# Restart a crashed validator at 0-based index on its existing data dir.
node_start() {
    local idx="$1"
    record_event "restart validator$((idx + 1))"
    if [ "$BACKEND" = "native" ]; then
        bash "$REPO_ROOT/perf-testing/network/node-ctl.sh" "$NODE_COUNT" "$((idx + 1))" start
    else
        docker start "${CONTAINER_NAMES[$idx]}" >/dev/null
    fi
}

# Appends "<epochMs>,<label>" to $FAULT_EVENTS_FILE (if set) so a load run's
# per-tx latency log can be lined up against kill/restart moments afterwards
# (monitoring/fault-timeline.js).
record_event() {
    if [ -n "${FAULT_EVENTS_FILE:-}" ]; then
        echo "$(date +%s%3N),$1" >> "$FAULT_EVENTS_FILE"
    fi
}

# eth_blockNumber against one RPC URL, decimal. Empty string if unreachable.
rpc_block_number() {
    local url="$1"
    local hex
    hex=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$url" 2>/dev/null | jq -r '.result // empty')
    if [ -z "$hex" ]; then
        echo ""
    else
        printf '%d\n' "$hex"
    fi
}

# Blocks until $url's block number is >= $target_block, or timeout_s elapses.
# Prints elapsed seconds on success, exits 1 on timeout.
wait_for_block_height() {
    local url="$1" target_block="$2" timeout_s="$3"
    local start elapsed height
    start=$(date +%s)
    while true; do
        height=$(rpc_block_number "$url")
        if [ -n "$height" ] && [ "$height" -ge "$target_block" ]; then
            elapsed=$(( $(date +%s) - start ))
            echo "$elapsed"
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -ge "$timeout_s" ]; then
            echo "TIMEOUT after ${elapsed}s (last height: ${height:-unreachable}, target: $target_block)" >&2
            return 1
        fi
        sleep 1
    done
}

rpc_block_hash() {
    local url="$1" block_dec="$2"
    local block_hex
    block_hex=$(printf '0x%x' "$block_dec")
    curl -s -m 3 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"${block_hex}\", false],\"id\":1}" \
        "$url" 2>/dev/null | jq -r '.result.hash // empty'
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}
