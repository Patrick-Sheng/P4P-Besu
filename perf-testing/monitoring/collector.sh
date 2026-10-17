#!/usr/bin/env bash
# collector.sh (plan Section 11): append one row every INTERVAL seconds to OUT.
# Independent of Prometheus/Grafana, so the record survives if they fall over.
# Adapted from the plan's listing: RPC/OUT/INTERVAL from env, DATADIRS default
# to every validator of the n=N native network, and heap-after-GC per node read
# from the -Xlog:gc files node-ctl.sh writes (last "Pause Young/Full" line).
#
# Usage: N=4 RPC=http://127.0.0.1:20400 OUT=soak-metrics.csv INTERVAL=120 bash collector.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
N=${N:-4}
GEN="network/generated/n${N}"
RPC=${RPC:-$(jq -r '.validators[0].rpcUrl' "${GEN}/network-meta.json")}
OUT=${OUT:-soak-metrics.csv}
INTERVAL=${INTERVAL:-120}   # du on RocksDB dirs costs I/O; keep this >= 60
DATADIRS=()
for ((i = 1; i <= N; i++)); do DATADIRS+=("${GEN}/data-native/validator${i}"); done

rpc() { curl -s -m 10 -X POST -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}" "$RPC"; }
hex() { [ -n "$1" ] && [ "$1" != null ] && printf '%d' "$1" || echo -1; }
heap_after_gc() {  # <gc log> -> MiB after the last GC, from "... 512M->123M(2048M) ..."
    grep -hE 'Pause (Young|Full|Remark)' "$1" 2>/dev/null | tail -1 | grep -oE '[0-9]+M->[0-9]+M' | sed -E 's/.*->([0-9]+)M/\1/'
}

if [ ! -f "$OUT" ]; then
  hdr="ts,block,block_ts,txs_in_block,pool_local,pool_remote,peers"
  for i in "${!DATADIRS[@]}"; do hdr+=",db$((i+1))_mb"; done
  for i in "${!DATADIRS[@]}"; do hdr+=",heap$((i+1))_mb"; done
  echo "$hdr,disk_free_gb,mem_used_mb,swap_used_mb" > "$OUT"
fi

while true; do
  ts=$(date +%s)
  blk=$(rpc eth_getBlockByNumber '["latest",false]')
  num=$(hex "$(echo "$blk" | jq -r '.result.number')")
  bts=$(hex "$(echo "$blk" | jq -r '.result.timestamp')")
  ntx=$(echo "$blk" | jq '.result.transactions | length' 2>/dev/null)
  pool=$(rpc txpool_besuStatistics '[]')
  plocal=$(echo "$pool" | jq '.result.localCount' 2>/dev/null)
  premote=$(echo "$pool" | jq '.result.remoteCount' 2>/dev/null)
  peers=$(hex "$(rpc net_peerCount '[]' | jq -r '.result')")
  dbs=$(for d in "${DATADIRS[@]}"; do du -sm "$d" 2>/dev/null | cut -f1 || echo -1; done | paste -sd,)
  heaps=$(for ((i = 1; i <= N; i++)); do h=$(heap_after_gc "$(ls -t "${GEN}"/validator${i}-gc.log* 2>/dev/null | head -1)"); echo "${h:--1}"; done | paste -sd,)
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  mem=$(free -m | awk '/Mem:/{print $3}')
  swp=$(free -m | awk '/Swap:/{print $3}')
  echo "$ts,$num,$bts,${ntx:--1},${plocal:--1},${premote:--1},$peers,$dbs,$heaps,$free_gb,$mem,$swp" >> "$OUT"
  sleep "$INTERVAL"
done
