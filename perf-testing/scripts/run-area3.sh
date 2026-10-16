#!/bin/bash
# Launches Area 3 attack runs as a DETACHED systemd --user unit (p4p-area3),
# outside the editor's cgroup - see run-area1.sh for why.
# Usage: scripts/run-area3.sh [nodeCount ...]   (default: 4 7 10)
# Follow: tail -f reports/malicious-results/area3-index.log
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NODES=("$@")
[ "${#NODES[@]}" -eq 0 ] && NODES=(4 7 10)
if systemctl --user is-active --quiet p4p-area3; then
    echo "p4p-area3 is already running" >&2
    exit 1
fi
systemctl --user reset-failed p4p-area3 2>/dev/null || true
mkdir -p reports/malicious-results
source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

CHAIN=""
for n in "${NODES[@]}"; do CHAIN+="bash scripts/area3-attacks.sh ${n}; sleep 20; "; done
systemd-run --user --unit=p4p-area3 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-area3 \
    -p StandardOutput="append:$(pwd)/reports/malicious-results/area3-driver.out" \
    -p StandardError="append:$(pwd)/reports/malicious-results/area3-driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-area3 for n=${NODES[*]}"
