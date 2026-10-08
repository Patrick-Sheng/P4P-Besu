#!/bin/bash
# Launches Area 2 crash-fault runs as a DETACHED systemd --user unit
# (p4p-area2), outside the editor's cgroup - see run-area1.sh for why.
#
# Usage: scripts/run-area2.sh [nodeCount ...]     (default: 4 7 10)
# Each node count runs the "within" (crash f) then "over" (crash f+1) scenario.
# Follow: tail -f reports/crash-fault-results/area2-index.log
# Stop:   systemctl --user stop p4p-area2
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NODES=("$@")
[ "${#NODES[@]}" -eq 0 ] && NODES=(4 7 10)

if systemctl --user is-active --quiet p4p-area2; then
    echo "p4p-area2 is already running" >&2
    exit 1
fi
systemctl --user reset-failed p4p-area2 2>/dev/null || true
mkdir -p reports/crash-fault-results

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

CHAIN=""
for n in "${NODES[@]}"; do
    CHAIN+="bash scripts/area2-crash.sh ${n} within; sleep 20; bash scripts/area2-crash.sh ${n} over; sleep 20; "
done

systemd-run --user --unit=p4p-area2 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-area2 \
    -p StandardOutput="append:$(pwd)/reports/crash-fault-results/area2-driver.out" \
    -p StandardError="append:$(pwd)/reports/crash-fault-results/area2-driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-area2 for n=${NODES[*]}"
