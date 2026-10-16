#!/bin/bash
# Launches the scaled Area 4 run as a DETACHED systemd --user unit (p4p-area4),
# outside the editor's cgroup - see run-area1.sh for why. Test parameters are
# passed through from the environment (see area4-throughput.sh header).
# Usage: [LOAD_TPS=.. TESTS=".."] scripts/run-area4.sh [nodeCount=4]
# Follow: tail -f reports/throughput-results/area4-index.log
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

N="${1:-4}"
if systemctl --user is-active --quiet p4p-area4; then
    echo "p4p-area4 is already running" >&2
    exit 1
fi
systemctl --user reset-failed p4p-area4 2>/dev/null || true
mkdir -p reports/throughput-results
source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ENV_ARGS=()
for v in LOAD_TPS LOAD_SECS SPIKE_BASE SPIKE_PEAK SPIKE_PRE SPIKE_HOLD SPIKE_POST ENDURANCE_TPS ENDURANCE_SECS \
         STRESS_FROM STRESS_TO STRESS_SECS STRESS_STEPS PROBE_READS PROBE_TPS TESTS; do
    [ -n "${!v:-}" ] && ENV_ARGS+=(--setenv="${v}=${!v}")
done
systemd-run --user --unit=p4p-area4 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-area4 "${ENV_ARGS[@]}" \
    -p StandardOutput="append:$(pwd)/reports/throughput-results/area4-driver.out" \
    -p StandardError="append:$(pwd)/reports/throughput-results/area4-driver.out" \
    bash scripts/area4-throughput.sh "$N"
echo "Launched p4p-area4 (n=${N})"
