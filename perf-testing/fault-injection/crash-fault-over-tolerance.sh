#!/bin/bash
# Area 2 - BFT fault tolerance (crash faults), OVER-tolerance case.
#
# Kills f+1 validators (one more than IBFT2 can tolerate under n >= 3f+1),
# staggered, and confirms the network correctly HALTS (stops producing new
# blocks) rather than forking or producing an inconsistent result with only
# 2f nodes left - one short of the 2f+1 quorum IBFT2 requires. Then reboots
# the killed nodes and confirms the network recovers once quorum is restored.
#
# Works against the Docker-based network from perf-testing/network/generate-network.mjs
# or a native one from network/start-native.sh (see lib.sh node_crash/node_start).
#
# Usage: ./crash-fault-over-tolerance.sh <nodeCount> [holdSeconds=30] [staggerSeconds=5]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

NODE_COUNT_ARG="${1:?Usage: ./crash-fault-over-tolerance.sh <nodeCount> [holdSeconds=30] [staggerSeconds=5]}"
HOLD_SECONDS="${2:-30}"
STAGGER_SECONDS="${3:-5}"

load_network_meta "$NODE_COUNT_ARG"

FPLUS1=$((MAX_FAULTS + 1))
if [ "$FPLUS1" -ge "$NODE_COUNT" ]; then
    echo "n=$NODE_COUNT is too small to kill f+1=$FPLUS1 nodes and still have any survivors to poll." >&2
    exit 1
fi

log "n=$NODE_COUNT, f=$MAX_FAULTS. Killing f+1=$FPLUS1 validators (one over tolerance) - expecting the network to HALT, not fork."

SURVIVOR_URL="${RPC_URLS[0]}"
VICTIM_INDICES=()
for ((i = NODE_COUNT - FPLUS1; i < NODE_COUNT; i++)); do
    VICTIM_INDICES+=("$i")
done

baseline_height=$(rpc_block_number "$SURVIVOR_URL")
log "Baseline height on survivor (${CONTAINER_NAMES[0]}): $baseline_height"

log "=== Killing $FPLUS1 node(s), staggered ==="
for idx in "${VICTIM_INDICES[@]}"; do
    log "crash ${CONTAINER_NAMES[$idx]} (${BACKEND})"
    node_crash "$idx"
    sleep "$STAGGER_SECONDS"
done

height_at_kill=$(rpc_block_number "$SURVIVOR_URL")
log "=== Holding for ${HOLD_SECONDS}s with only $((NODE_COUNT - FPLUS1)) nodes live (below 2f+1 quorum) ==="
sleep "$HOLD_SECONDS"
height_after_hold=$(rpc_block_number "$SURVIVOR_URL")
blocks_produced=$((height_after_hold - height_at_kill))

log "Survivor height: $height_at_kill -> $height_after_hold (+$blocks_produced blocks in ${HOLD_SECONDS}s)"
# Allow at most 1 block of slack: a proposal already in flight at the moment
# of the kill may still land, but the chain must not keep advancing after that.
if [ "$blocks_produced" -le 1 ]; then
    log "PASS: network correctly halted (no quorum) instead of producing an inconsistent result."
    halt_pass=true
else
    log "FAIL: network kept producing blocks with only $((NODE_COUNT - FPLUS1)) of $NODE_COUNT nodes online - quorum safety violated."
    halt_pass=false
fi

log "=== Rebooting $FPLUS1 node(s) to restore quorum, staggered ==="
for idx in "${VICTIM_INDICES[@]}"; do
    log "restart ${CONTAINER_NAMES[$idx]} (${BACKEND})"
    node_start "$idx"
    sleep "$STAGGER_SECONDS"
done

log "=== Confirming the network resumes block production now that quorum is restored ==="
height_before_recovery_wait=$(rpc_block_number "$SURVIVOR_URL")
# IBFT round-change timeouts double per failed round (requesttimeoutseconds=4 -> 8, 16, 32...),
# so after a long quorum loss the next round can be a minute+ away - 60s would false-FAIL.
if elapsed=$(wait_for_block_height "$SURVIVOR_URL" "$((height_before_recovery_wait + 1))" "${RECOVERY_TIMEOUT:-180}"); then
    log "PASS: network resumed producing blocks ${elapsed}s after quorum was restored."
    record_event "chain-resumed"
    recovery_pass=true
else
    log "FAIL: network did not resume block production within timeout after quorum restoration."
    recovery_pass=false
fi

if [ "$halt_pass" = true ] && [ "$recovery_pass" = true ]; then
    log "RESULT: PASS"
    exit 0
else
    log "RESULT: FAIL"
    exit 1
fi
