#!/usr/bin/env node
'use strict';

// Lines up a background Caliper load run against Area 2 fault events, to
// answer "does throughput drop while crashed nodes catch up?". Inputs:
//   - per-tx latency NDJSON from caliper/connector/voting-connector.js
//   - the events file fault-injection/lib.sh writes (<epochMs>,<label>)
//   - block timestamps over the run, fetched from a survivor's RPC
// Prints a per-bucket timeline and a per-phase summary. Phases are cut at
// the first "crash", first "restart", and last "caught-up"/"chain-resumed"
// event: baseline -> degraded -> recovering -> after.
//
// Usage: node fault-timeline.js <latencyDir> <eventsFile> <rpcUrl> <fromBlock> <toBlock> [bucketSecs=5] [csvOut]

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const [, , latencyDir, eventsFile, rpcUrl, fromArg, toArg, bucketArg, csvOut] = process.argv;
if (!latencyDir || !eventsFile || !rpcUrl || !fromArg || !toArg) {
    console.error('Usage: node fault-timeline.js <latencyDir> <eventsFile> <rpcUrl> <fromBlock> <toBlock> [bucketSecs=5] [csvOut]');
    process.exit(1);
}
const bucketMs = (Number(bucketArg) || 5) * 1000;

const txs = [];
for (const f of fs.readdirSync(latencyDir).filter((n) => n.endsWith('.ndjson'))) {
    for (const line of fs.readFileSync(path.join(latencyDir, f), 'utf8').split('\n')) {
        if (line.trim()) {
            txs.push(JSON.parse(line));
        }
    }
}
const events = fs.existsSync(eventsFile)
    ? fs.readFileSync(eventsFile, 'utf8').split('\n').filter(Boolean).map((l) => {
        const [ms, ...label] = l.split(',');
        return { ms: Number(ms), label: label.join(',') };
    })
    : [];

const pct = (arr, p) => {
    if (arr.length === 0) {
        return null;
    }
    const s = [...arr].sort((a, b) => a - b);
    return s[Math.max(0, Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1))];
};
const fmt = (v, d = 0) => (v === null || v === undefined || Number.isNaN(v) ? '-' : Number(v).toFixed(d));

async function main() {
    const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, { staticNetwork: true });
    const blocks = [];
    for (let n = Number(fromArg); n <= Number(toArg); n++) {
        const b = await provider.getBlock(n);
        if (!b) {
            break;
        }
        blocks.push({ number: n, ms: Number(b.timestamp) * 1000, txCount: b.transactions.length });
    }

    const okTx = txs.filter((t) => t.success);
    const startMs = Math.min(...txs.map((t) => t.submitTimeMs), ...events.map((e) => e.ms));
    const endMs = Math.max(...txs.map((t) => t.confirmTimeMs), ...events.map((e) => e.ms));

    // --- per-bucket timeline ---
    const rows = [];
    for (let t = startMs; t < endMs; t += bucketMs) {
        const inB = okTx.filter((x) => x.confirmTimeMs >= t && x.confirmTimeMs < t + bucketMs);
        const blk = blocks.filter((b) => b.ms >= t && b.ms < t + bucketMs);
        const ev = events.filter((e) => e.ms >= t && e.ms < t + bucketMs).map((e) => e.label);
        rows.push({
            t: Math.round((t - startMs) / 1000),
            tps: inB.length / (bucketMs / 1000),
            p50: pct(inB.map((x) => x.latencyMs), 50),
            blocks: blk.length,
            events: ev.join('; ')
        });
    }
    console.log(`Timeline (${bucketMs / 1000}s buckets, t=0 at first submit/event):`);
    console.log('  t(s)  confirmed_tps  p50_ms  blocks  events');
    for (const r of rows) {
        console.log(`  ${String(r.t).padStart(4)}  ${fmt(r.tps, 1).padStart(13)}  ${fmt(r.p50).padStart(6)}  ${String(r.blocks).padStart(6)}  ${r.events}`);
    }
    if (csvOut) {
        fs.writeFileSync(csvOut, 't_s,confirmed_tps,p50_ms,blocks,events\n' +
            rows.map((r) => [r.t, r.tps.toFixed(1), r.p50 ?? '', r.blocks, JSON.stringify(r.events)].join(',')).join('\n') + '\n');
    }

    // --- phases ---
    const first = (re) => events.find((e) => re.test(e.label));
    const last = (re) => [...events].reverse().find((e) => re.test(e.label));
    const crash = first(/^crash/);
    const restart = first(/^restart/);
    const recovered = last(/^(caught-up|chain-resumed)/);
    const cuts = [
        ['baseline', startMs, crash ? crash.ms : endMs],
        ['degraded (nodes down)', crash ? crash.ms : endMs, restart ? restart.ms : endMs],
        ['recovering (restart -> caught up)', restart ? restart.ms : endMs, recovered ? recovered.ms : endMs],
        ['after recovery', recovered ? recovered.ms : endMs, endMs]
    ];
    console.log('\nPer-phase summary (throughput = txs confirmed within the phase / phase length):');
    console.log('  phase                               dur_s  conf_tps  p50_ms  p95_ms  blocks  mean_gap_s  max_gap_s');
    for (const [name, a, b] of cuts) {
        if (b <= a) {
            continue;
        }
        const inP = okTx.filter((x) => x.confirmTimeMs >= a && x.confirmTimeMs < b);
        const lat = inP.map((x) => x.latencyMs);
        // block gaps: include the last block before the phase so a phase with
        // zero blocks still shows the (growing) gap since the previous block
        const blk = blocks.filter((x) => x.ms >= a && x.ms < b);
        const prev = [...blocks].reverse().find((x) => x.ms < a);
        const series = prev ? [prev, ...blk] : blk;
        const gaps = [];
        for (let i = 1; i < series.length; i++) {
            gaps.push((series[i].ms - series[i - 1].ms) / 1000);
        }
        if (blk.length === 0 && prev) {
            gaps.push((b - prev.ms) / 1000);
        }
        const mean = gaps.length ? gaps.reduce((x, y) => x + y, 0) / gaps.length : null;
        console.log(`  ${name.padEnd(34)}  ${fmt((b - a) / 1000, 1).padStart(5)}  ${fmt(inP.length / ((b - a) / 1000), 1).padStart(8)}  ${fmt(pct(lat, 50)).padStart(6)}  ${fmt(pct(lat, 95)).padStart(6)}  ${String(blk.length).padStart(6)}  ${fmt(mean, 2).padStart(10)}  ${fmt(gaps.length ? Math.max(...gaps) : null, 0).padStart(9)}`);
    }
    const failed = txs.length - okTx.length;
    console.log(`\nTotal: ${txs.length} recorded txs, ${okTx.length} succeeded, ${failed} reverted (send-side failures are in the Caliper log, not here)`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
