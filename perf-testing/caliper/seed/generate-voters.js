#!/usr/bin/env node
'use strict';

// Generates a pool of random voter accounts for a benchmark round.
//
// This network runs with --min-gas-price=0 (confirmed: perf-testing/network/
// generate-network.mjs, and the existing repo root network/start-nodes.sh relies
// on the same default), so these accounts never need ETH funding - the only
// setup step is registering them via register-voters.js.
//
// Usage: node generate-voters.js <count> <outFile>
// Each voter can only vote once, so size the pool to at least
// targetTPS * roundDurationSeconds for whichever benchmark round will use it.

const { ethers } = require('ethers');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const [, , countArg, outFileArg] = process.argv;
const count = parseInt(countArg, 10);

if (!Number.isInteger(count) || count <= 0 || !outFileArg) {
    console.error('Usage: node generate-voters.js <count> <outFile>');
    process.exit(1);
}

const outFile = path.resolve(process.cwd(), outFileArg);
fs.mkdirSync(path.dirname(outFile), { recursive: true });

console.log(`Generating ${count} voter accounts -> ${outFile}`);
const voters = new Array(count);
const progressEvery = Math.max(1, Math.floor(count / 20));

// A raw private key + ethers.Wallet(key) (just an EC point multiplication for
// the address) is far cheaper than ethers.Wallet.createRandom(), which also
// generates a BIP-39 mnemonic (PBKDF2-backed) that nothing here uses -
// createRandom() was taking minutes per 30k voters; this is seconds.
for (let i = 0; i < count; i++) {
    const privateKey = '0x' + crypto.randomBytes(32).toString('hex');
    const wallet = new ethers.Wallet(privateKey);
    voters[i] = { address: wallet.address, privateKey: wallet.privateKey };
    if ((i + 1) % progressEvery === 0 || i + 1 === count) {
        console.log(`  ${i + 1}/${count}`);
    }
}

fs.writeFileSync(outFile, JSON.stringify(voters));
console.log(`Done. Wrote ${voters.length} voters to ${outFile}`);
