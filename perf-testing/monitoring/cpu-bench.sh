#!/bin/bash
# Single-thread CPU speed probe (seconds for a 20M-iteration Python loop; best
# of 3). On this VM ~1.15 s is normal; the Oct 15 host slowdown (throttling /
# power plan) showed as 4.2-4.6 s and made the chain crawl, which looks exactly
# like a Besu slowdown. Drivers log this per run and refuse to start above
# P4P_CPU_BENCH_MAX (default 2.5 s).
python3 - <<'PY'
import time
best = 1e9
for _ in range(3):
    t = time.perf_counter(); s = 0
    for i in range(20_000_000): s += i
    best = min(best, time.perf_counter() - t)
print(f"{best:.2f}")
PY
