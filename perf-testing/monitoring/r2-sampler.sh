#!/bin/bash
# Round 2 (election-scale plan) resource sampler. Appends one row every
# INTERVAL seconds to <runDir>/samples.csv, tagged with the phase name the
# driver writes to <runDir>/phase, so per-phase aggregates (idle baseline,
# each load step) can be computed afterwards by r2-phase-stats.sh.
#
# besu_rss_mb is the summed VmRSS of the validator JVMs (process memory only,
# unlike the watchdog's cgroup memory.current, which also counts page cache).
# besu_cpu_ticks is their cumulative utime+stime, so CPU % over a window is
# delta_ticks / CLK_TCK / delta_seconds * 100 (100 = one full vCPU).
#
# cpu_probe_ms (every 12th sample, else empty): wall time of a fixed awk busy
# loop - a mid-run host slowdown (Windows moving the VM onto E-cores, power
# limits, throttling) shows up here instead of masquerading as a Besu effect.
#
# Usage: r2-sampler.sh <nodeCount> <runDir> <rpcUrl>
set -uo pipefail

N="$1"; RUN_DIR="$2"; RPC_URL="$3"
INTERVAL="${P4P_SAMPLE_INTERVAL:-5}"
UNIT_PREFIX="p4p-besu-n${N}-v"
CSV="${RUN_DIR}/samples.csv"

rpc() {
    curl -s -m 2 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":[],\"id\":1}" "$RPC_URL"
}

[ -f "$CSV" ] || echo "ts,phase,cpu_busy_pct,iowait_pct,mem_avail_mb,swap_used_mb,besu_rss_mb,besu_cpu_ticks,pool,height,cpu_probe_ms" > "$CSV"

read -r _ u n s i w q sq st _ < /proc/stat
prev_total=$((u + n + s + i + w + q + sq + st)); prev_idle=$i; prev_iow=$w

while true; do
    sleep "$INTERVAL"
    read -r _ u n s i w q sq st _ < /proc/stat
    total=$((u + n + s + i + w + q + sq + st))
    dt=$((total - prev_total)); [ "$dt" -le 0 ] && dt=1
    busy=$(( 1000 * (dt - (i - prev_idle) - (w - prev_iow)) / dt ))
    iow=$(( 1000 * (w - prev_iow) / dt ))
    prev_total=$total; prev_idle=$i; prev_iow=$w

    rss_kb=0; ticks=0
    for ((k = 1; k <= N; k++)); do
        pid=$(systemctl --user show -p MainPID --value "${UNIT_PREFIX}${k}" 2>/dev/null)
        [ -z "$pid" ] || [ "$pid" = 0 ] || [ ! -r "/proc/${pid}/status" ] && continue
        r=$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null)
        rss_kb=$((rss_kb + ${r:-0}))
        t=$(awk '{print $14 + $15}' "/proc/${pid}/stat" 2>/dev/null)
        ticks=$((ticks + ${t:-0}))
    done

    avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    swap=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo)
    pool=$(rpc txpool_besuStatistics | jq -r '(.result.localCount + .result.remoteCount) // -1' 2>/dev/null)
    h=$(rpc eth_blockNumber | jq -r '.result // empty' 2>/dev/null)
    [ -n "$h" ] && h=$(printf '%d' "$h") || h=-1
    phase=$(cat "${RUN_DIR}/phase" 2>/dev/null || echo unknown)
    probe=""
    nsample=$(( ${nsample:-0} + 1 ))
    if [ $((nsample % 12)) -eq 1 ]; then
        p0=$(date +%s%N); awk 'BEGIN {for (i = 0; i < 3000000; i++) s += i}'; probe=$(( ($(date +%s%N) - p0) / 1000000 ))
    fi

    printf '%s,%s,%d.%d,%d.%d,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$phase" \
        $((busy / 10)) $((busy % 10)) $((iow / 10)) $((iow % 10)) \
        "$avail" "$swap" $((rss_kb / 1024)) "$ticks" "${pool:--1}" "$h" "$probe" >> "$CSV"
done
