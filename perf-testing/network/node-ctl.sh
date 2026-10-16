#!/bin/bash
# Controls ONE validator of a native network started by start-native.sh:
#   start  - (re)launch validator<i> as systemd --user unit p4p-besu-n<N>-v<i>,
#            reusing its existing data dir (so a restarted node resyncs from
#            where it crashed rather than from genesis)
#   crash  - SIGKILL it (an unclean crash fault: no graceful shutdown, no
#            flush - harsher than `docker stop`'s SIGTERM)
#   stop   - graceful stop (SIGTERM)
#
# A stopped/killed transient systemd unit can't simply be `systemctl start`ed
# again, so `start` re-issues the same systemd-run launch. Heap/memory caps come
# from generated/n<N>/node-env, written by start-native.sh, so a restarted node
# runs with exactly the limits it had before.
#
# Usage: ./node-ctl.sh <nodeCount> <validatorIndex 1..N> start|crash|stop
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

N="${1:?Usage: ./node-ctl.sh <nodeCount> <validatorIndex> start|crash|stop}"
IDX="${2:?validator index 1..N}"
ACTION="${3:?start|crash|stop}"

GEN_DIR="generated/n${N}"
CONFIG_DIR="${GEN_DIR}/config"
UNIT="p4p-besu-n${N}-v${IDX}"
SLICE="p4p-perf.slice"

case "$ACTION" in
crash)
    systemctl --user kill --signal=SIGKILL "$UNIT"
    exit 0
    ;;
stop)
    systemctl --user stop "$UNIT"
    exit 0
    ;;
start) ;;
*)
    echo "Unknown action ${ACTION}" >&2
    exit 1
    ;;
esac

# shellcheck source=/dev/null
source "${GEN_DIR}/node-env"   # HEAP_MB, NODE_MEM_MB

if systemctl --user is-active --quiet "$UNIT"; then
    echo "${UNIT} is already running" >&2
    exit 1
fi
systemctl --user reset-failed "$UNIT" 2>/dev/null || true

mapfile -t ADDRS < <(find "${CONFIG_DIR}/keys" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
i=$((IDX - 1))
addr="${ADDRS[$i]}"
RPC_BASE=$((20000 + N * 100))
P2P_BASE=$((30000 + N * 100))
data_path="${GEN_DIR}/data-native/validator${IDX}"
mkdir -p "$data_path"
log_file="$(pwd)/${GEN_DIR}/validator${IDX}.log"

bootnode_flag=()
if [ "$i" -ne 0 ]; then
    BOOTNODE_PUBKEY=$(sed 's/^0x//' "${CONFIG_DIR}/keys/${ADDRS[0]}/key.pub")
    bootnode_flag=(--bootnodes="enode://${BOOTNODE_PUBKEY}@127.0.0.1:${P2P_BASE}")
fi

# Bounded off-heap: metaspace, JIT code cache and Netty direct buffers otherwise
# grow unbounded on top of -Xmx, and glibc's per-thread malloc arenas inflate
# RocksDB's native footprint - together these made a -Xmx512m node reach ~1.2G RSS.
# GC log per node: lets a stalled/wedged node be told apart from a GC-thrashing one
JAVA_OPTS_VAL="-Xms128m -Xmx${HEAP_MB}m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=$(pwd)/${GEN_DIR}/validator${IDX}-gc.log:uptime,time:filecount=2,filesize=20m"

# append (not truncate) so a crashed node's pre-crash log survives its restart
systemd-run --user --quiet \
    --unit="$UNIT" --slice="$SLICE" \
    --working-directory="$(pwd)" \
    -p MemoryMax="${NODE_MEM_MB}M" -p MemorySwapMax=0 -p OOMScoreAdjust=800 \
    -p StandardOutput="append:${log_file}" -p StandardError="append:${log_file}" \
    --setenv=JAVA_OPTS="$JAVA_OPTS_VAL" --setenv=MALLOC_ARENA_MAX=2 \
    --setenv=PATH="$PATH" \
    "$(command -v besu)" \
    --data-path="$data_path" \
    --genesis-file="${CONFIG_DIR}/genesis.json" \
    --node-private-key-file="${CONFIG_DIR}/keys/${addr}/key" \
    --data-storage-format=BONSAI \
    --rpc-http-enabled \
    --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL \
    --rpc-http-host=127.0.0.1 \
    --rpc-http-port="$((RPC_BASE + i))" \
    --rpc-http-cors-origins=* \
    --host-allowlist=* \
    --p2p-host=127.0.0.1 \
    --p2p-port="$((P2P_BASE + i))" \
    "${bootnode_flag[@]}" \
    --profile=ENTERPRISE \
    --Xplugin-rocksdb-cache-capacity=33554432 \
    --Xplugin-rocksdb-background-thread-count=1 \
    --logging=INFO
