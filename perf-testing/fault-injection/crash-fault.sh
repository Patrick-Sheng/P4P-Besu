#!/bin/bash
# Area 2 - BFT fault tolerance (crash faults), within-tolerance case.
#
# Kills the maximum tolerable number of validators f (n >= 3f+1) for a given
# network size, staggered (not simultaneous), leaves them offline for a hold
# period, then reboots them and measures resync. Requires the Docker-based
# network from perf-testing/network/generate-network.mjs (docker stop/start
# by container name) or a native one from network/start-native.sh (SIGKILL /
# relaunch via network/node-ctl.sh) - see lib.sh node_crash/node_start.
#
# For the required "does throughput drop while catching up" measurement: run
# a Caliper throughput round (e.g. benchmarks/throughput/load.yaml) in another
# terminal while this script runs, and correlate this script's timestamped
# kill/reboot log lines against the round's transaction latency NDJSON
# (submitTimeMs) or the periodic default-observer TPS lines in its output.
#
# Usage: ./crash-fault.sh <nodeCount> [holdSeconds=30] [staggerSeconds=5]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

NODE_COUNT_ARG="${1:?Usage: ./crash-fault.sh <nodeCount> [holdSeconds=30] [staggerSeconds=5]}"
HOLD_SECONDS="${2:-30}"
STAGGER_SECONDS="${3:-5}"

load_network_meta "$NODE_COUNT_ARG"

if [ "$MAX_FAULTS" -lt 1 ]; then
    echo "n=$NODE_COUNT has maxTolerableFaults=$MAX_FAULTS; nothing to crash." >&2
    exit 1
fi

F="$MAX_FAULTS"
log "n=$NODE_COUNT, f=$F. Killing the last $F validators (staggered ${STAGGER_SECONDS}s apart), leaving validator1..$((NODE_COUNT - F)) as survivors."

SURVIVOR_URL="${RPC_URLS[0]}"
VICTIM_INDICES=()
for ((i = NODE_COUNT - F; i < NODE_COUNT; i++)); do
    VICTIM_INDICES+=("$i")
done

baseline_height=$(rpc_block_number "$SURVIVOR_URL")
log "Baseline height on survivor (${CONTAINER_NAMES[0]}): $baseline_height"

log "=== Killing $F node(s), staggered ==="
for idx in "${VICTIM_INDICES[@]}"; do
    log "crash ${CONTAINER_NAMES[$idx]} (${BACKEND})"
    node_crash "$idx"
    sleep "$STAGGER_SECONDS"
done

log "=== Holding for ${HOLD_SECONDS}s with n-f=$((NODE_COUNT - F)) nodes live ==="
height_at_kill=$(rpc_block_number "$SURVIVOR_URL")
sleep "$HOLD_SECONDS"
height_after_hold=$(rpc_block_number "$SURVIVOR_URL")
blocks_produced=$((height_after_hold - height_at_kill))

log "Survivor height: $height_at_kill -> $height_after_hold (+$blocks_produced blocks in ${HOLD_SECONDS}s)"
if [ "$blocks_produced" -lt 1 ]; then
    log "FAIL: network did not produce new blocks with n-f nodes online. Liveness check FAILED."
else
    log "PASS: network kept producing blocks with n-f nodes online (liveness maintained)."
fi

log "=== Rebooting $F node(s), staggered ==="
reboot_start_epoch=$(date +%s)
for idx in "${VICTIM_INDICES[@]}"; do
    log "restart ${CONTAINER_NAMES[$idx]} (${BACKEND})"
    node_start "$idx"
    sleep "$STAGGER_SECONDS"
done

target_height=$(rpc_block_number "$SURVIVOR_URL")
log "=== Waiting for rebooted node(s) to resync to height $target_height (chain kept advancing while they were down) ==="

overall_pass=true
for idx in "${VICTIM_INDICES[@]}"; do
    node_url="${RPC_URLS[$idx]}"
    log "Waiting on ${CONTAINER_NAMES[$idx]} (${node_url})..."
    if elapsed=$(wait_for_block_height "$node_url" "$target_height" 180); then
        log "  ${CONTAINER_NAMES[$idx]} caught up in ${elapsed}s"
        record_event "caught-up validator$((idx + 1))"

        # Correctness check: compare block hash at the same historical height
        # against the survivor. A matching hash implies a matching state root,
        # i.e. the resynced state is byte-for-byte consistent, without this
        # script needing to know the deployed contract's address/ABI.
        check_height=$((target_height > 5 ? target_height - 5 : 0))
        survivor_hash=$(rpc_block_hash "$SURVIVOR_URL" "$check_height")
        resynced_hash=$(rpc_block_hash "$node_url" "$check_height")
        if [ "$survivor_hash" = "$resynced_hash" ] && [ -n "$survivor_hash" ]; then
            log "  State check PASS: block #$check_height hash matches survivor ($survivor_hash)"
        else
            log "  State check FAIL: block #$check_height hash mismatch (survivor=$survivor_hash, resynced=$resynced_hash)"
            overall_pass=false
        fi
    else
        log "  FAIL: ${CONTAINER_NAMES[$idx]} did not resync within timeout"
        overall_pass=false
    fi
done

total_elapsed=$(( $(date +%s) - reboot_start_epoch ))
log "=== Done. Total reboot-to-full-resync wall time: ${total_elapsed}s ==="
if [ "$overall_pass" = true ] && [ "$blocks_produced" -ge 1 ]; then
    log "RESULT: PASS"
    exit 0
else
    log "RESULT: FAIL"
    exit 1
fi
