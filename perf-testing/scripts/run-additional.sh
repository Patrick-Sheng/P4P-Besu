#!/bin/bash
# Launches the additional infrastructure-evaluation tests
# (docs/Additional Test Plan Infrastructure Evaluation.md) as a DETACHED
# systemd --user unit (p4p-additional), outside the editor's cgroup - see
# run-area1.sh for why.
#
# Usage: scripts/run-additional.sh T1 <S1|S2|S3>
#        scripts/run-additional.sh T2 <V0|V1|V2|V3>
#        scripts/run-additional.sh T3 [nodeCount=4]
#        scripts/run-additional.sh T4 [nodeCount ...]     (default: 4 7 - reruns the Area 1 sweep)
# Env:   REPEATS=<k>  run the same scenario k times back to back, each on a fresh
#                     network, labelled run1..runk (default 1)
#        every P4P_*, T1_*..T4_* and RECOVERY_TIMEOUT variable set in the calling
#        shell is forwarded into the unit (systemd-run does not inherit the
#        shell environment), e.g.  T1_VOTES=5000 scripts/run-additional.sh T1 S1
# Follow: tail -f reports/additional/additional-index.log   (T4: reports/additional/T4-*/area1-index.log)
# Stop:   systemctl --user stop p4p-additional
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"
source scripts/additional-lib.sh

TEST="${1:?Usage: scripts/run-additional.sh <T1|T2|T3|T4> [variant|nodeCount ...]}"
shift
REPEATS="${REPEATS:-1}"
if systemctl --user is-active --quiet p4p-additional; then
    echo "p4p-additional is already running" >&2
    exit 1
fi
case "$TEST" in
T1)
    case "${1:-}" in S1|S2|S3) ;; *) echo "T1 variant must be S1, S2 or S3" >&2; exit 1 ;; esac
    CMD="bash scripts/additional-fault.sh T1 $1" ;;
T2)
    case "${1:-}" in V0|V1|V2|V3) ;; *) echo "T2 variant must be V0, V1, V2 or V3" >&2; exit 1 ;; esac
    CMD="bash scripts/additional-fault.sh T2 $1" ;;
T3)
    CMD="bash scripts/t3-storage.sh ${1:-4}" ;;
T4)
    NODES=("$@")
    [ "${#NODES[@]}" -eq 0 ] && NODES=(4 7)
    # area1-sweep.sh unchanged except for where it writes; the T4 change is the
    # VM's resources, so record them alongside (run-meta.txt + env.txt)
    RUN_ID="T4-$(date '+%Y%m%d-%H%M%S')${P4P_RUN_LABEL:+-${P4P_RUN_LABEL}}"
    RUN_DIR="${ADDITIONAL_DIR}/${RUN_ID}"
    mkdir -p "$RUN_DIR"
    export P4P_RESULTS_DIR="$RUN_DIR"
    record_run_metadata
    echo "$(date '+%F %T') ${RUN_ID} LAUNCHED area1-sweep n=${NODES[*]} dir=${RUN_DIR}" >> "$ADDITIONAL_INDEX"
    CMD=""
    for n in "${NODES[@]}"; do CMD+="bash scripts/area1-sweep.sh ${n}; sleep 20; "; done
    CMD="${CMD%; }" ;;
*)
    echo "Unknown test '${TEST}' (T1, T2, T3, T4; T0 is scripts/record-env.sh)" >&2; exit 1 ;;
esac

systemctl --user reset-failed p4p-additional 2>/dev/null || true
[ -f "${ADDITIONAL_DIR}/env.txt" ] || echo "WARNING: no ${ADDITIONAL_DIR}/env.txt - run scripts/record-env.sh (T0) first" >&2

source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

ENV_ARGS=()
while IFS= read -r v; do
    [ "$v" = P4P_DRIVER_UNIT ] && continue
    ENV_ARGS+=(--setenv="${v}=${!v}")
done < <(compgen -e | grep -E '^(P4P_|T[0-9]_|RECOVERY_TIMEOUT$)' || true)

CHAIN=""
for ((r = 1; r <= REPEATS; r++)); do
    if [ "$REPEATS" -gt 1 ]; then
        CHAIN+="P4P_RUN_LABEL=run${r} ${CMD}; sleep 20; "
    else
        CHAIN+="${CMD}; "
    fi
done

systemd-run --user --unit=p4p-additional --slice=p4p-ctl.slice -p MemoryMax=256M \
    --working-directory="$(pwd)" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=P4P_DRIVER_UNIT=p4p-additional "${ENV_ARGS[@]}" \
    -p StandardOutput="append:${ADDITIONAL_DIR}/additional-driver.out" \
    -p StandardError="append:${ADDITIONAL_DIR}/additional-driver.out" \
    bash -c "$CHAIN"
echo "Launched p4p-additional: ${TEST} $* (x${REPEATS})"
