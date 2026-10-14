#!/bin/bash
# Shared helpers for the additional infrastructure-evaluation tests
# (docs/Additional Test Plan Infrastructure Evaluation.md): sourced by
# scripts/additional-fault.sh (T1, T2), scripts/t3-storage.sh (T3) and
# scripts/run-additional.sh (T4). Source this, don't execute it.
# Expects PERF_DIR to be set; record_run_metadata also needs RUN_ID and RUN_DIR.

ADDITIONAL_DIR="${PERF_DIR}/reports/additional"
ADDITIONAL_INDEX="${ADDITIONAL_DIR}/additional-index.log"
mkdir -p "$ADDITIONAL_DIR"

# Everything the plan asks to keep with each run, besides the results
# themselves: git commit of the harness, uncommitted code changes, versions,
# every P4P_/T<n>_ setting in effect, and a copy of the T0 env.txt.
record_run_metadata() {
    local out="${RUN_DIR}/run-meta.txt"
    {
        echo "run_id=${RUN_ID}"
        echo "started=$(date '+%F %T %z')"
        echo "git_commit=$(git -C "$PERF_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "git_branch=$(git -C "$PERF_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        echo "# uncommitted changes outside reports/ (empty = clean):"
        git -C "$PERF_DIR/.." status --porcelain -- . ':(exclude)perf-testing/reports' 2>/dev/null | head -50
        echo "besu_version=$(besu --version 2>/dev/null | head -1)"
        echo "node_version=$(node --version 2>/dev/null)"
        echo "host=$(hostname) cores=$(nproc) mem_total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
        echo "# environment overrides in effect:"
        env | grep -E '^(P4P_|T[0-9]_|RECOVERY_TIMEOUT=)' | sort
    } > "$out"
    if [ -f "${ADDITIONAL_DIR}/env.txt" ]; then
        cp "${ADDITIONAL_DIR}/env.txt" "${RUN_DIR}/env.txt"
    else
        echo "WARNING: ${ADDITIONAL_DIR}/env.txt not found - run scripts/record-env.sh (T0) before the tests" | tee -a "$out"
    fi
}
