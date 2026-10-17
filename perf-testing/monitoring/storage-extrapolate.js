#!/usr/bin/env node
'use strict';

// T3 - turns the per-validator `du -sb` measurements written by
// scripts/t3-storage.sh (storage.csv) into bytes per empty block, per
// registration and per vote, and extrapolates disk per validator for an
// election. Per validator:
//
//   per empty block  = (idle end - idle start) / blocks produced while idle
//   per registration = (bytes grown during the phase - per empty block x blocks
//                       produced during the phase) / registrations     [idle-corrected]
//   per vote         = same for the voting phase / votes counted on chain
//
// The raw (uncorrected) per-registration / per-vote figures are reported too.
// Estimate = size at idle start (fresh chain, includes RocksDB preallocation)
//          + per empty block x (days x 86400 / blockPeriod)
//          + per registration x registrations + per vote x votes.
// Linear in every term - an ESTIMATE; compaction, Bonsai trie-log pruning and
// cache sizing can all make real growth non-linear. Measure longer to check.
//
// Usage: node storage-extrapolate.js <storage.csv> [--registrations=2900000] [--votes=2900000]
//          [--days=21] [--block-period=2] [--out=<prefix>]   (writes <prefix>.json and <prefix>.csv)

const fs = require('node:fs');

const args = process.argv.slice(2);
const csvPath = args.find((a) => !a.startsWith('--'));
const opt = (name, def) => {
    const a = args.find((x) => x.startsWith(`--${name}=`));
    return a === undefined ? def : a.slice(name.length + 3);
};
if (!csvPath) {
    console.error('Usage: node storage-extrapolate.js <storage.csv> [--registrations=N] [--votes=N] [--days=21] [--block-period=2] [--out=<prefix>]');
    process.exit(1);
}
const registrations = Number(opt('registrations', 2900000));
const votes = Number(opt('votes', 2900000));
const days = Number(opt('days', 21));
const blockPeriod = Number(opt('block-period', 2));
const out = opt('out', null);
const blocks = Math.round(days * 86400 / blockPeriod);

const lines = fs.readFileSync(csvPath, 'utf8').split('\n').filter((l) => l.trim());
const header = lines[0].split(',');
const rows = lines.slice(1).map((l) => Object.fromEntries(l.split(',').map((v, i) => [header[i], v])));
const num = (v) => (v === '' || v === undefined ? NaN : Number(v));

const validators = [...new Set(rows.map((r) => r.validator))];
const get = (v, phase, point) => rows.find((r) => r.validator === v && r.phase === phase && r.point === point);
const warnings = [];

const perValidator = validators.map((v) => {
    const d = (phase) => {
        const s = get(v, phase, 'start');
        const e = get(v, phase, 'end');
        if (!s || !e) {
            return null;
        }
        return {
            bytes: num(e.total_bytes) - num(s.total_bytes),
            blocks: num(e.height) - num(s.height),
            registered: num(e.registered) - num(s.registered),
            votes: num(e.votes) - num(s.votes)
        };
    };
    const idle = d('idle');
    const reg = d('registration');
    const vote = d('voting');
    const perBlock = idle && idle.blocks > 0 ? idle.bytes / idle.blocks : NaN;
    const corrected = (ph, n) => (ph && n > 0 ? (ph.bytes - perBlock * ph.blocks) / n : NaN);
    const raw = (ph, n) => (ph && n > 0 ? ph.bytes / n : NaN);
    for (const [name, ph] of [['idle', idle], ['registration', reg], ['voting', vote]]) {
        if (!ph) {
            warnings.push(`${v}: no ${name} start/end measurement`);
        } else if (ph.bytes < 0) {
            warnings.push(`${v}: size SHRANK during ${name} (${ph.bytes} B) - compaction; treat this validator's ${name} figure with care`);
        }
    }
    const r = {
        validator: v,
        baseBytes: num((get(v, 'idle', 'start') || {}).total_bytes),
        bytesPerEmptyBlock: perBlock,
        bytesPerRegistration: corrected(reg, reg && reg.registered),
        bytesPerRegistrationRaw: raw(reg, reg && reg.registered),
        bytesPerVote: corrected(vote, vote && vote.votes),
        bytesPerVoteRaw: raw(vote, vote && vote.votes),
        phases: { idle, registration: reg, voting: vote }
    };
    r.estimateBytes = r.baseBytes + r.bytesPerEmptyBlock * blocks + r.bytesPerRegistration * registrations + r.bytesPerVote * votes;
    return r;
});

const keys = ['baseBytes', 'bytesPerEmptyBlock', 'bytesPerRegistration', 'bytesPerRegistrationRaw', 'bytesPerVote', 'bytesPerVoteRaw', 'estimateBytes'];
const agg = {};
for (const k of keys) {
    const xs = perValidator.map((r) => r[k]).filter(Number.isFinite);
    agg[k] = xs.length ? { mean: xs.reduce((a, b) => a + b, 0) / xs.length, min: Math.min(...xs), max: Math.max(...xs) } : null;
}

const gb = (b) => (Number.isFinite(b) ? (b / 1e9).toFixed(2) : '-');
const f0 = (b) => (Number.isFinite(b) ? b.toFixed(0) : '-');
console.log(`T3 storage per validator (${validators.length} validators; idle-corrected unless marked raw):`);
console.log('  validator    B/empty block  B/registration (raw)  B/vote (raw)     fresh chain GB  estimate GB');
for (const r of perValidator) {
    console.log(`  ${r.validator.padEnd(11)}  ${f0(r.bytesPerEmptyBlock).padStart(13)}  ${`${f0(r.bytesPerRegistration)} (${f0(r.bytesPerRegistrationRaw)})`.padStart(20)}  ${`${f0(r.bytesPerVote)} (${f0(r.bytesPerVoteRaw)})`.padStart(15)}  ${gb(r.baseBytes).padStart(14)}  ${gb(r.estimateBytes).padStart(11)}`);
}
if (agg.estimateBytes) {
    console.log(`Estimate for ${registrations} registrations + ${votes} votes + ${days} days of ${blockPeriod}s blocks (${blocks} blocks):`);
    console.log(`  mean ${gb(agg.estimateBytes.mean)} GB per validator (range ${gb(agg.estimateBytes.min)}-${gb(agg.estimateBytes.max)} GB) - linear extrapolation, see assumptions`);
    console.log(`  of which empty blocks alone: ${gb(agg.bytesPerEmptyBlock.mean * blocks)} GB`);
}
for (const w of warnings) {
    console.log(`  WARNING: ${w}`);
}

if (out) {
    fs.writeFileSync(`${out}.json`, JSON.stringify({
        source: csvPath,
        assumptions: {
            registrations, votes, days, blockPeriodSeconds: blockPeriod, blocks,
            model: 'linear: fresh-chain size + per-empty-block x blocks + per-registration x registrations + per-vote x votes',
            correction: 'registration/vote figures subtract the idle per-block growth for the blocks produced during that phase'
        },
        perValidator,
        mean: agg,
        warnings
    }, null, 2));
    fs.writeFileSync(`${out}.csv`, ['validator,' + keys.join(','),
        ...perValidator.map((r) => [r.validator, ...keys.map((k) => f0(r[k]))].join(',')),
        ['mean', ...keys.map((k) => (agg[k] ? f0(agg[k].mean) : ''))].join(',')].join('\n') + '\n');
}
