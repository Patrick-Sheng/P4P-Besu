#!/bin/bash
# Aggregates r2-sampler.sh rows for one phase into a single key=value line:
#   samples, cpu_busy (host %, mean), iowait (%, mean), besu_cpu (% of one
#   vCPU, summed over all validators), rss_end / rss_max (MiB, all validators),
#   mem_avail_min (MiB), swap_max (MiB), pool_start / pool_end / pool_max,
#   pool_slope (tx/s, least squares over the phase).
#
# Usage: r2-phase-stats.sh <samples.csv> <phase>
set -uo pipefail
CSV="$1"; PHASE="$2"
HZ=$(getconf CLK_TCK)

awk -F, -v ph="$PHASE" -v hz="$HZ" '
NR > 1 && $2 == ph {
    n++; ts[n] = $1; cpu += $3; iow += $4
    if (mavail == "" || $5 < mavail) mavail = $5
    if ($6 > swap) swap = $6
    rss_end = $7; if ($7 > rss_max) rss_max = $7
    tick[n] = $8
    if ($9 >= 0) {
        pn++; px[pn] = $1; py[pn] = $9
        if (pn == 1) pool_start = $9
        pool_end = $9; if ($9 > pool_max) pool_max = $9
    }
}
END {
    if (n == 0) { print "samples=0"; exit }
    besu = (n > 1 && ts[n] > ts[1]) ? (tick[n] - tick[1]) / hz / (ts[n] - ts[1]) * 100 : 0
    slope = 0
    if (pn > 1) {
        for (k = 1; k <= pn; k++) { sx += px[k]; sy += py[k] }
        mx = sx / pn; my = sy / pn
        for (k = 1; k <= pn; k++) { num += (px[k] - mx) * (py[k] - my); den += (px[k] - mx) ^ 2 }
        if (den > 0) slope = num / den
    }
    printf "samples=%d cpu_busy=%.1f iowait=%.1f besu_cpu=%.1f rss_end=%d rss_max=%d mem_avail_min=%d swap_max=%d pool_start=%d pool_end=%d pool_max=%d pool_slope=%.3f\n",
        n, cpu / n, iow / n, besu, rss_end, rss_max, mavail, swap, pool_start, pool_end, pool_max, slope
}' "$CSV"
