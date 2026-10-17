#!/usr/bin/env python3
"""Round 3 Test 2: unbiased agreement-time statistics for one run directory.

r3-agreement.sh's first-pass numbers use validator1's consensus log lines only,
so blocks validator1 received through the sync path (typically the slow ones,
when it had fallen behind) drop out and bias the median low at larger n. Here
each block's time is its EARLIEST appearance in ANY validator's log - consensus
"Produced/Imported #N" or sync "PersistBlockTask ... block #N" - and intervals
are taken over every consecutive block in the 300 s measurement window.

Usage: r3-agreement-recompute.py <runDir> [<runDir> ...]  -> one CSV line each on stdout
"""
import gzip, os, re, statistics, sys
from datetime import datetime, timedelta

FMT = '%Y-%m-%d %H:%M:%S.%f'
TS = r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\+00:00 '
BLOCK = [re.compile(TS + r'.*IbftBesuControllerBuilder \| (?:Produced|Imported) #([\d,]+)'),
         re.compile(TS + r'.*PersistBlockTask \| Imported (?:empty )?block #([\d,]+)')]
MEASURE = re.compile(r'Measuring (\d+)s from (\S+ \S+)')

print('run,n,load,blocks_in_window,intervals,wall_mean_ms,mean_ms,median_ms,p95_ms,max_ms,median_minus_period_ms,p95_minus_period_ms')
for run in sys.argv[1:]:
    log = open(os.path.join(run, 'run.log')).read()
    m = MEASURE.search(log)
    secs, t0 = int(m.group(1)), datetime.strptime(m.group(2), FMT)
    t1 = t0 + timedelta(seconds=secs)
    period = int(re.search(r'(\d+) ms block period', log).group(1))
    name = os.path.basename(run.rstrip('/'))
    n, load = re.match(r'n(\d+)-r(\d+)-', name).groups()
    first = {}
    d = os.path.join(run, 'node-logs-full')
    for f in os.listdir(d):
        if not re.match(r'validator\d+\.log\.gz$', f):
            continue
        for line in gzip.open(os.path.join(d, f), 'rt', errors='replace'):
            for rx in BLOCK:
                b = rx.match(line)
                if b:
                    t = datetime.strptime(b.group(1), FMT)
                    num = int(b.group(2).replace(',', ''))
                    if num not in first or t < first[num]:
                        first[num] = t
                    break
    nums = sorted(k for k, t in first.items() if t0 <= t <= t1)
    iv = sorted((first[b] - first[a]).total_seconds() * 1000 for a, b in zip(nums, nums[1:]) if b == a + 1)
    if not iv:
        print(f'{name},{n},{load},0,0,,,,,,,'); continue
    p95 = iv[min(len(iv) - 1, int(len(iv) * 0.95))]
    med = statistics.median(iv)
    print(f'{name},{n},{load},{len(nums)},{len(iv)},{secs * 1000 / max(1, len(nums)):.0f},'
          f'{statistics.mean(iv):.0f},{med:.0f},{p95:.0f},{iv[-1]:.0f},{med - period:.0f},{p95 - period:.0f}')
