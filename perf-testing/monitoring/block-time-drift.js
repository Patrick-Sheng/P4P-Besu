#!/usr/bin/env node
'use strict';

// Measures block time drift from the genesis-configured ibft2.blockperiodseconds
// target (2s, see perf-testing/network/generate-network.mjs) over a block range.
// Run this against a validator's RPC endpoint after a benchmark round, using the
// block numbers spanning that round (read them off the round's latency NDJSON
// files, or just note the height before/after via eth_blockNumber).
//
// Usage: node block-time-drift.js <rpcUrl> <fromBlock> <toBlock> [targetPeriodSeconds=2]

const { ethers } = require('ethers');

const [, , rpcUrl, fromArg, toArg, targetArg] = process.argv;
const fromBlock = parseInt(fromArg, 10);
const toBlock = parseInt(toArg, 10);
const targetPeriodSeconds = targetArg ? parseFloat(targetArg) : 2;

if (!rpcUrl || !Number.isInteger(fromBlock) || !Number.isInteger(toBlock) || toBlock <= fromBlock) {
    console.error('Usage: node block-time-drift.js <rpcUrl> <fromBlock> <toBlock> [targetPeriodSeconds=2]');
    process.exit(1);
}

async function main() {
    const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, { staticNetwork: true });

    const timestamps = [];
    for (let n = fromBlock; n <= toBlock; n++) {
        const block = await provider.getBlock(n);
        if (!block) {
            console.error(`Block ${n} not found (chain may not have reached this height)`);
            break;
        }
        timestamps.push(Number(block.timestamp));
    }

    const periods = [];
    for (let i = 1; i < timestamps.length; i++) {
        periods.push(timestamps[i] - timestamps[i - 1]);
    }

    if (periods.length === 0) {
        console.error('Not enough blocks fetched to compute inter-block periods');
        process.exit(1);
    }

    const avg = periods.reduce((a, b) => a + b, 0) / periods.length;
    const drifts = periods.map((p) => p - targetPeriodSeconds);
    const maxDrift = Math.max(...drifts.map(Math.abs));
    const meanAbsDrift = drifts.reduce((a, b) => a + Math.abs(b), 0) / drifts.length;
    const sorted = [...periods].sort((a, b) => a - b);

    console.log(`Blocks ${fromBlock}..${toBlock} (${periods.length} intervals), target period ${targetPeriodSeconds}s`);
    console.log(`  avg block period:      ${avg.toFixed(3)}s`);
    console.log(`  min/max block period:  ${sorted[0]}s / ${sorted[sorted.length - 1]}s`);
    console.log(`  mean abs drift:        ${meanAbsDrift.toFixed(3)}s`);
    console.log(`  max abs drift:         ${maxDrift.toFixed(3)}s`);
    console.log(`  periods > 2x target:   ${periods.filter((p) => p > 2 * targetPeriodSeconds).length} (possible round changes / missed proposals)`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
