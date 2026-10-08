#!/usr/bin/env node
'use strict';

// Summarises one Area-1 sweep round into a CSV row: merges the per-tx latency
// NDJSON written by caliper/connector/voting-connector.js (p50/p95/p99) with
// Caliper's own result table from that round's log (send rate + failures,
// which never reach the NDJSON because a failed send throws before it is
// recorded). Prints a human-readable block to stdout and appends the row to
// <csvFile> (writing the header if the file is new).
//
// Usage: node round-summary.js <latencyDir> <caliperLog> <csvFile> <nodes> <round> <targetTps> [note]

const fs = require('node:fs');
const path = require('node:path');

const [, , latencyDir, caliperLog, csvFile, nodes, round, targetTpsArg, note = ''] = process.argv;
if (!latencyDir || !caliperLog || !csvFile || !nodes || round === undefined || !targetTpsArg) {
    console.error('Usage: node round-summary.js <latencyDir> <caliperLog> <csvFile> <nodes> <round> <targetTps> [note]');
    process.exit(1);
}
const targetTps = Number(targetTpsArg);

const records = [];
if (fs.existsSync(latencyDir)) {
    for (const f of fs.readdirSync(latencyDir).filter((n) => n.endsWith('.ndjson'))) {
        for (const line of fs.readFileSync(path.join(latencyDir, f), 'utf8').split('\n')) {
            if (line.trim()) {
                records.push(JSON.parse(line));
            }
        }
    }
}

// Caliper result row: | label | Succ | Fail | Send Rate | Max | Min | Avg | Throughput |
let caliper = null;
if (fs.existsSync(caliperLog)) {
    const rows = fs.readFileSync(caliperLog, 'utf8').split('\n')
        .filter((l) => /^\|\s*sweep-n\d+-\d+tps\s*\|/.test(l));
    if (rows.length > 0) {
        const cols = rows[rows.length - 1].split('|').map((c) => c.trim()).filter(Boolean);
        caliper = { succ: +cols[1], fail: +cols[2], sendTps: +cols[3], throughputTps: +cols[7] };
    }
}

const ok = records.filter((r) => r.success);
const lat = ok.map((r) => r.latencyMs).sort((a, b) => a - b);
const pct = (p) => (lat.length ? lat[Math.max(0, Math.min(lat.length - 1, Math.ceil((p / 100) * lat.length) - 1))] : '');
const avg = lat.length ? (lat.reduce((a, b) => a + b, 0) / lat.length).toFixed(1) : '';
let spanS = '';
let observedTps = '';
if (records.length > 0) {
    let lo = Infinity;
    let hi = -Infinity;
    for (const r of records) {
        lo = Math.min(lo, r.submitTimeMs);
        hi = Math.max(hi, r.confirmTimeMs);
    }
    spanS = ((hi - lo) / 1000).toFixed(1);
    observedTps = (ok.length / ((hi - lo) / 1000)).toFixed(1);
}

const failed = caliper ? caliper.fail : records.length - ok.length;
const submitted = caliper ? caliper.succ + caliper.fail : records.length;
const row = [nodes, round, targetTps, submitted, ok.length, failed,
    caliper ? caliper.sendTps : '', observedTps,
    lat[0] ?? '', pct(50), pct(95), pct(99), lat[lat.length - 1] ?? '', avg, spanS,
    JSON.stringify(note)].join(',');

if (!fs.existsSync(csvFile)) {
    fs.writeFileSync(csvFile, 'nodes,round,target_tps,submitted,succeeded,failed,send_tps,observed_tps,min_ms,p50_ms,p95_ms,p99_ms,max_ms,avg_ms,span_s,note\n');
}
fs.appendFileSync(csvFile, row + '\n');

console.log(`n=${nodes} round ${round} target ${targetTps} TPS: submitted ${submitted}, ok ${ok.length}, failed ${failed}, ` +
    `send ${caliper ? caliper.sendTps : '?'} TPS, observed ${observedTps || '?'} TPS`);
console.log(`  latency ms: min ${lat[0] ?? '-'} p50 ${pct(50) || '-'} p95 ${pct(95) || '-'} p99 ${pct(99) || '-'} max ${lat[lat.length - 1] ?? '-'} avg ${avg || '-'}`);
// machine-readable line for the sweep driver's saturation check
console.log(`ROUND_RESULT observed_tps=${observedTps || 0} failed=${failed} submitted=${submitted} p95_ms=${pct(95) || 0}`);
