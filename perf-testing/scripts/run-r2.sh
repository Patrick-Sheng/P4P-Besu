#!/bin/bash
# Launches one or more round 2 phases (scripts/r2-run.sh) back to back as ONE
# detached systemd --user unit (p4p-r2), outside the editor's cgroup. Stops at
# the first phase that doesn't complete.
#
# Usage: scripts/run-r2.sh <phase> [phase ...]
#        phases: smoke seed calibrate soak double area2 verify
#        env passed through: P4P_SOAK_FROM_ROUND P4P_SOAK_RATE P4P_REG_WINDOW P4P_CAL_STEPS P4P_CAL_SECS
# Follow: tail -f reports/r2-soak/r2-index.log reports/r2-soak/<phase>-*/run.log
# Stop:   systemctl --user stop p4p-r2
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ "$#" -ge 1 ] || { echo "Usage: $0 <phase> [phase ...]" >&2; exit 1; }
if systemctl --user is-active --quiet p4p-r2; then echo "p4p-r2 is already running" >&2; exit 1; fi
systemctl --user reset-failed p4p-r2 2>/dev/null || true
mkdir -p reports/r2-soak
source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

CHAIN=""
for p in "$@"; do CHAIN+="bash scripts/r2-run.sh ${p} || { echo 'stopped at ${p}'; exit 0; }; "; done
envs=()
for v in P4P_SOAK_FROM_ROUND P4P_SOAK_RATE P4P_REG_WINDOW P4P_CAL_STEPS P4P_CAL_SECS P4P_WARMUP_STEPS P4P_SOAK_ROUNDS P4P_ATTACK_LABEL P4P_ATTACK_TRAFFIC_RATE P4P_ATTACK_RESUME_CSV P4P_A2_RATE P4P_A2_PRE_SECS P4P_A2_CRASH_SECS P4P_A2_POST_SECS P4P_A2_QPRE_SECS P4P_A2_QHOLD_SECS P4P_A2_QPOST_SECS P4P_DOUBLE_RANGE; do
    [ -n "${!v:-}" ] && envs+=("--setenv=${v}=${!v}")
done
systemd-run --user --unit=p4p-r2 --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-r2 "${envs[@]}" \
    -p StandardOutput="append:$(pwd)/reports/r2-soak/driver.out" -p StandardError="append:$(pwd)/reports/r2-soak/driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-r2: $*"
