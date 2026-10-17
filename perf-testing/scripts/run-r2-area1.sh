#!/bin/bash
# Launches the round 2 Area 1 ladder (scripts/r2-area1-ladder.sh) for each
# validator count in turn as ONE detached systemd --user unit (p4p-r2-area1),
# outside the editor's cgroup. Climbing stops at the first size that reaches
# the breaking point (exit 10) or errors.
#
# Usage: scripts/run-r2-area1.sh [nodeCount ...]   (default 4 7 10 13 16 19)
# Follow: tail -f reports/r2-scalability/r2-area1-index.log
#         tail -f reports/r2-scalability/n<N>-*/run.log
# Stop:   systemctl --user stop p4p-r2-area1
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NODES=("$@")
[ "${#NODES[@]}" -eq 0 ] && NODES=(4 7 10 13 16 19)

if systemctl --user is-active --quiet p4p-r2-area1; then
    echo "p4p-r2-area1 is already running" >&2; exit 1
fi
systemctl --user reset-failed p4p-r2-area1 2>/dev/null || true
mkdir -p reports/r2-scalability

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

CHAIN=""
for n in "${NODES[@]}"; do
    CHAIN+="bash scripts/r2-area1-ladder.sh ${n}; rc=\$?; echo \"n=${n} exit \$rc\"; [ \$rc -ne 0 ] && { echo 'ladder stopped at n=${n}'; exit 0; }; sleep 20; "
done

systemd-run --user --unit=p4p-r2-area1 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-r2-area1 \
    -p StandardOutput="append:$(pwd)/reports/r2-scalability/driver.out" \
    -p StandardError="append:$(pwd)/reports/r2-scalability/driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-r2-area1 for n=${NODES[*]}"
