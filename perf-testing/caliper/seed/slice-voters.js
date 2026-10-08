#!/usr/bin/env node
'use strict';

// Splits a registered voter pool into non-overlapping, sequential chunks, one
// per benchmark round. Needed because Caliper creates a fresh workload-module
// instance per round (see caliper-core/lib/worker/caliper-worker.js
// prepareTest(): `this.workloadModule = workloadModuleFactory()` then
// initializeWorkloadModule() again), so workloads/cast-vote.js's cursor
// resets to 0 every round and re-derives the SAME deterministic voter
// partition from whatever file that round's config points at. Pointing every
// round at one shared votersFile (as the original scalability-N.yaml configs
// do) means round 2+ immediately reselects round 1's already-voted voters and
// every submitTransaction reverts. Giving each round its own disjoint slice
// of the same underlying registered pool avoids this.
//
// Usage: node slice-voters.js <poolFile> <outPrefix> <tps1:duration1> [<tps2:duration2> ...]
// Writes <outPrefix>-r0.json, <outPrefix>-r1.json, ... sized tps*duration each,
// in order, non-overlapping. Errors if the pool is too small.

const fs = require('node:fs');
const path = require('node:path');

const [, , poolFileArg, outPrefixArg, ...roundArgs] = process.argv;
if (!poolFileArg || !outPrefixArg || roundArgs.length === 0) {
    console.error('Usage: node slice-voters.js <poolFile> <outPrefix> <tps1:duration1> [<tps2:duration2> ...]');
    process.exit(1);
}

const pool = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), poolFileArg), 'utf8'));
const sizes = roundArgs.map((a) => {
    const [tps, duration] = a.split(':').map(Number);
    return Math.ceil(tps * duration);
});
const total = sizes.reduce((a, b) => a + b, 0);
if (total > pool.length) {
    console.error(`Pool has ${pool.length} voters but rounds need ${total} total - generate a bigger pool.`);
    process.exit(1);
}

let cursor = 0;
sizes.forEach((size, i) => {
    const slice = pool.slice(cursor, cursor + size);
    cursor += size;
    const outPath = `${outPrefixArg}-r${i}.json`;
    fs.writeFileSync(outPath, JSON.stringify(slice));
    console.log(`round ${i}: ${slice.length} voters -> ${outPath}`);
});
console.log(`Used ${cursor}/${pool.length} voters from pool.`);
