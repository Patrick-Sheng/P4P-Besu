#!/bin/bash
# Samples every validator's transaction-pool size (txpool_besuStatistics) for
# the T2 eviction test, so the pool can be plotted through the outage and the
# "outage end -> pool empty" time measured. Runs as its own small systemd
# --user unit (p4p-txpool-n<N>) next to the watchdog, started and stopped by
# scripts/additional-fault.sh. Kept out of resource-watchdog.sh so Areas 1-4
# see no extra RPC traffic.
#
# Usage: txpool-sampler.sh <nodeCount> <runDir> [intervalSecs=2]
# Output: <runDir>/txpool.csv   ts_ms,height,v1_pool,...,vN_pool
#         height is validator1's; pool = localCount + remoteCount; -1 = no answer
#         (e.g. a deliberately crashed validator)
set -uo pipefail

N="${1:?Usage: txpool-sampler.sh <nodeCount> <runDir> [intervalSecs]}"
RUN_DIR="${2:?Usage: txpool-sampler.sh <nodeCount> <runDir> [intervalSecs]}"
INTERVAL="${3:-2}"
META="$(dirname "${BASH_SOURCE[0]}")/../network/generated/n${N}/network-meta.json"
mapfile -t RPC < <(jq -r '.validators[].rpcUrl' "$META")
CSV="${RUN_DIR}/txpool.csv"

rpc() {  # <url> <method>
    curl -s -m 2 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" "$1"
}

header="ts_ms,height"
for ((i = 1; i <= N; i++)); do header+=",v${i}_pool"; done
echo "$header" > "$CSV"

while true; do
    ts=$(date +%s%3N)
    h=$(rpc "${RPC[0]}" eth_blockNumber | jq -r '.result // empty' 2>/dev/null)
    if [ -n "$h" ]; then h=$(printf '%d' "$h"); else h=-1; fi
    row="${ts},${h}"
    for u in "${RPC[@]}"; do
        p=$(rpc "$u" txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1' 2>/dev/null)
        row+=",${p:--1}"
    done
    echo "$row" >> "$CSV"
    sleep "$INTERVAL"
done
