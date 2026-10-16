#!/usr/bin/env node
'use strict';

// Aggregates the per-transaction latency NDJSON logs written by
// perf-testing/caliper/connector/voting-connector.js (one file per
// worker per round: round<R>-worker<W>.ndjson) and prints p50/p95/p99/min/
// max/avg confirmation latency for a round. Caliper's own report.html only
// has min/max/avg - this fills the percentile gap the test plan requires.
//
// Usage: node compute-percentiles.js <latencyLogDir> <roundIndex>
//   e.g. node compute-percentiles.js ../caliper/reports/latency 0

const fs = require('node:fs');
const path = require('node:path');

const [, , dirArg, roundArg] = process.argv;
if (!dirArg || roundArg === undefined) {
    console.error('Usage: node compute-percentiles.js <latencyLogDir> <roundIndex>');
    process.exit(1);
}

const dir = path.resolve(process.cwd(), dirArg);
const roundIndex = parseInt(roundArg, 10);
const prefix = `round${roundIndex}-worker`;

const files = fs.readdirSync(dir).filter((f) => f.startsWith(prefix) && f.endsWith('.ndjson'));
if (files.length === 0) {
    console.error(`No latency files matching ${prefix}*.ndjson found in ${dir}`);
    process.exit(1);
}

const records = [];
for (const file of files) {
    const content = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const line of content.split('\n')) {
        if (!line.trim()) {
            continue;
        }
        records.push(JSON.parse(line));
    }
}

function percentile(sortedArr, p) {
    if (sortedArr.length === 0) {
        return NaN;
    }
    const idx = Math.min(sortedArr.length - 1, Math.ceil((p / 100) * sortedArr.length) - 1);
    return sortedArr[Math.max(0, idx)];
}

const successful = records.filter((r) => r.success);
const failed = records.filter((r) => !r.success);
const latencies = successful.map((r) => r.latencyMs).sort((a, b) => a - b);

const sum = latencies.reduce((a, b) => a + b, 0);
const avg = latencies.length ? sum / latencies.length : NaN;

console.log(`Round ${roundIndex}: ${files.length} worker file(s), ${records.length} total tx (${successful.length} succeeded, ${failed.length} failed)`);
console.log('Confirmation latency over successful transactions (ms):');
console.log(`  min:  ${latencies[0]}`);
console.log(`  p50:  ${percentile(latencies, 50)}`);
console.log(`  p95:  ${percentile(latencies, 95)}`);
console.log(`  p99:  ${percentile(latencies, 99)}`);
console.log(`  max:  ${latencies[latencies.length - 1]}`);
console.log(`  avg:  ${avg.toFixed(1)}`);

if (records.length > 0) {
    const spanMs = Math.max(...records.map((r) => r.confirmTimeMs)) - Math.min(...records.map((r) => r.submitTimeMs));
    const throughputTps = successful.length / (spanMs / 1000);
    console.log(`Observed throughput over round span: ${throughputTps.toFixed(1)} TPS (span ${(spanMs / 1000).toFixed(1)}s)`);
}
