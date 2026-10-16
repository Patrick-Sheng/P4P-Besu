#!/bin/bash
# Launches the Area 1 sweep for each node count in turn (default 4 7 10) as a
# DETACHED systemd --user unit (p4p-area1), outside the VS Code/terminal
# cgroup. The earlier sweeps ran as children of the editor's terminal: the
# kernel OOM killer hit a besu JVM and systemd then killed the whole
# snap.code scope, crashing VS Code mid-run. Detached, an editor crash can't
# kill the test and a test OOM can't kill the editor.
#
# Usage: scripts/run-area1.sh [-t "10 25 50 ..."] [nodeCount ...]
# Follow progress: tail -f reports/scalability-results/area1-index.log
#                  tail -f reports/scalability-results/n<N>-*/sweep.log
# Stop:            systemctl --user stop p4p-area1
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TPS=""
if [ "${1:-}" = "-t" ]; then TPS="$2"; shift 2; fi
NODES=("$@")
[ "${#NODES[@]}" -eq 0 ] && NODES=(4 7 10)

if systemctl --user is-active --quiet p4p-area1; then
    echo "p4p-area1 is already running (systemctl --user status p4p-area1)" >&2
    exit 1
fi
systemctl --user reset-failed p4p-area1 2>/dev/null || true

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

CHAIN=""
for n in "${NODES[@]}"; do
    CHAIN+="bash scripts/area1-sweep.sh ${n} ${TPS}; sleep 20; "
done

systemd-run --user --unit=p4p-area1 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-area1 \
    -p StandardOutput="append:$(pwd)/reports/scalability-results/area1-driver.out" \
    -p StandardError="append:$(pwd)/reports/scalability-results/area1-driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-area1 for n=${NODES[*]} (TPS ladder: ${TPS:-default})"
