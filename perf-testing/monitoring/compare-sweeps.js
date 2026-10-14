#!/usr/bin/env node
'use strict';

// T4 - hardware-sensitivity comparison of two Area 1 sweeps at the same node
// count: the original (e.g. reports/scalability-results/n4-20261008-032842/summary.csv)
// against the rerun with more VM resources (reports/additional/T4-.../n4-*/summary.csv).
// Both files are round-summary.js output; columns are read by header name.
//
// Reported per sweep:
//   max observed     highest confirmed TPS of any round (may be a saturated round)
//   max sustained    highest confirmed TPS among rounds that kept up with their
//                    target (observed >= satRatio x target, the same 0.8 rule
//                    area1-sweep.sh uses to stop the ladder), with its p50/p95/p99
//
// Usage: node compare-sweeps.js <before summary.csv> <after summary.csv> [--sat-ratio=0.8] [--csv=<out.csv>]

const fs = require('node:fs');

const args = process.argv.slice(2);
const [beforePath, afterPath] = args.filter((a) => !a.startsWith('--'));
const opt = (name, def) => {
    const a = args.find((x) => x.startsWith(`--${name}=`));
    return a === undefined ? def : a.slice(name.length + 3);
};
if (!beforePath || !afterPath) {
    console.error('Usage: node compare-sweeps.js <before summary.csv> <after summary.csv> [--sat-ratio=0.8] [--csv=<out.csv>]');
    process.exit(1);
}
const satRatio = Number(opt('sat-ratio', 0.8));
const csvOut = opt('csv', null);

function splitCsv(line) {
    const out = [];
    let cur = '';
    let q = false;
    for (const ch of line) {
        if (ch === '"') {
            q = !q;
        } else if (ch === ',' && !q) {
            out.push(cur);
            cur = '';
        } else {
            cur += ch;
        }
    }
    out.push(cur);
    return out;
}

function load(file) {
    const lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim());
    const header = splitCsv(lines[0]);
    const num = (v) => (v === undefined || v === '' ? NaN : Number(v));
    const rounds = lines.slice(1).map((l) => {
        const c = Object.fromEntries(splitCsv(l).map((v, i) => [header[i], v]));
        return {
            nodes: c.nodes, target: num(c.target_tps), observed: num(c.observed_tps), send: num(c.send_tps),
            p50: num(c.p50_ms), p95: num(c.p95_ms), p99: num(c.p99_ms), failed: num(c.failed), note: c.note || ''
        };
    }).filter((r) => Number.isFinite(r.target));
    const done = rounds.filter((r) => Number.isFinite(r.observed));
    const best = (xs) => xs.reduce((a, b) => (a === null || b.observed > a.observed ? b : a), null);
    return {
        file,
        nodes: rounds.length ? rounds[0].nodes : '?',
        rounds,
        maxObserved: best(done),
        maxSustained: best(done.filter((r) => r.observed >= satRatio * r.target))
    };
}

const before = load(beforePath);
const after = load(afterPath);
if (before.nodes !== after.nodes) {
    console.log(`WARNING: comparing different node counts (before n=${before.nodes}, after n=${after.nodes})`);
}

const f = (v, d = 1) => (Number.isFinite(v) ? v.toFixed(d) : '-');
const s = (ms) => (Number.isFinite(ms) ? (ms / 1000).toFixed(2) : '-');
console.log(`T4 comparison, n=${after.nodes} (sustained = observed >= ${satRatio} x target)`);
console.log(`  before: ${beforePath}`);
console.log(`  after:  ${afterPath}`);
console.log('  target | before: confirmed TPS  p50/p95/p99 (s)   | after: confirmed TPS  p50/p95/p99 (s)');
const targets = [...new Set([...before.rounds, ...after.rounds].map((r) => r.target))].sort((a, b) => a - b);
const rowsOut = [];
for (const t of targets) {
    const b = before.rounds.find((r) => r.target === t) || {};
    const a = after.rounds.find((r) => r.target === t) || {};
    console.log(`  ${String(t).padStart(6)} | ${f(b.observed).padStart(19)}  ${`${s(b.p50)}/${s(b.p95)}/${s(b.p99)}`.padStart(17)} | ${f(a.observed).padStart(18)}  ${`${s(a.p50)}/${s(a.p95)}/${s(a.p99)}`.padStart(17)}`);
    rowsOut.push([t, b.observed, b.p50, b.p95, b.p99, a.observed, a.p50, a.p95, a.p99].map((v) => (Number.isFinite(v) ? v : '')).join(','));
}
for (const [name, key] of [['max sustained', 'maxSustained'], ['max observed', 'maxObserved']]) {
    const b = before[key];
    const a = after[key];
    const ratio = b && a ? ` (x${(a.observed / b.observed).toFixed(2)})` : '';
    console.log(`  ${name.padEnd(13)}: before ${b ? `${f(b.observed)} TPS @ target ${b.target}, p95 ${s(b.p95)} s` : '-'} | after ${a ? `${f(a.observed)} TPS @ target ${a.target}, p95 ${s(a.p95)} s` : '-'}${ratio}`);
}
const lastAfter = after.rounds[after.rounds.length - 1];
if (lastAfter && /ABORTED|caliper exit/.test(lastAfter.note)) {
    console.log(`  NOTE: the rerun's last round ended abnormally (${lastAfter.note}) - its ceiling may be a crash, not saturation`);
}
if (csvOut) {
    fs.writeFileSync(csvOut, 'target_tps,before_tps,before_p50_ms,before_p95_ms,before_p99_ms,after_tps,after_p50_ms,after_p95_ms,after_p99_ms\n' + rowsOut.join('\n') + '\n');
}
