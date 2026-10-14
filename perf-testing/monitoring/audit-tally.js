#!/usr/bin/env node
'use strict';

// T1 - tally audit across validators. Checks that the contract's own tally
// matches an independent recount from the chain's records, on EVERY validator
// (including any that crashed and resynced), at one common block height:
//
//   1. optionally close voting (admin closeVoting()), then wait until every
//      validator is past that block
//   2. audit height H = the lowest latest block across all validators
//   3. per validator, at H: block hash, getTally(c) for every candidate, and a
//      recount of every VoteCast event from the deployment block to H via
//      eth_getLogs in chunks (Besu's --rpc-max-logs-range defaults to 5000),
//      unique voter addresses, and the wall time of that recount
//   4. compare: tally == recount, events == unique voters (nobody counted
//      twice), identical across validators, totals == Caliper's confirmed votes
//
// A mismatch is a finding, not a script failure: all raw values are written
// out either way. Exit code 0 = every check passed, 1 = at least one mismatch,
// 2 = the audit itself could not be completed.
//
// RPC URLs come from network-meta.json (all validators - the Caliper config
// may be trimmed to the never-crashed ones), the contract address, ABI path,
// deployment block and admin key from caliper/networks/besu-nN.json.
//
// Usage: node audit-tally.js <networkConfig> <networkMeta> <outDir>
//          [--close-voting] [--expected=<confirmedVotes>] [--chunk=5000] [--extrapolate-votes=2900000]
// Writes <outDir>/audit.csv (one row per validator) and <outDir>/audit.json.

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const args = process.argv.slice(2);
const positional = args.filter((a) => !a.startsWith('--'));
const opt = (name) => {
    const a = args.find((x) => x.startsWith(`--${name}=`));
    return a === undefined ? undefined : a.slice(name.length + 3);
};
const [networkConfigArg, metaArg, outDirArg] = positional;
if (!networkConfigArg || !metaArg || !outDirArg) {
    console.error('Usage: node audit-tally.js <networkConfig> <networkMeta> <outDir> [--close-voting] [--expected=N] [--chunk=5000] [--extrapolate-votes=2900000]');
    process.exit(2);
}
const closeVoting = args.includes('--close-voting');
const expected = opt('expected') === undefined || opt('expected') === '' ? null : Number(opt('expected'));
const chunk = Number(opt('chunk') || 5000);
const extrapolateVotes = Number(opt('extrapolate-votes') || 2900000);
if (!Number.isInteger(chunk) || chunk < 1 || (expected !== null && !Number.isInteger(expected))) {
    console.error('--chunk must be a positive integer and --expected an integer');
    process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (msg) => console.log(`[audit] ${msg}`);

async function headOf(provider) {
    try {
        return await provider.getBlockNumber();
    } catch {
        return -1;
    }
}

async function main() {
    const cfgPath = path.resolve(process.cwd(), networkConfigArg);
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')).voting;
    // abiPath is relative to the caliper workspace (networks/ -> caliper/), as in malicious/lib.js
    const workspaceRoot = path.resolve(path.dirname(cfgPath), '..');
    const artifact = JSON.parse(fs.readFileSync(path.resolve(workspaceRoot, cfg.contracts.VotingSystem.abiPath), 'utf8'));
    const address = cfg.contracts.VotingSystem.address;
    const iface = new ethers.Interface(artifact.abi);
    const voteCastTopic = iface.getEvent('VoteCast').topicHash;

    const meta = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), metaArg), 'utf8'));
    const validators = meta.validators.map((v, i) => ({
        name: `validator${i + 1}`,
        rpcUrl: v.rpcUrl,
        provider: new ethers.JsonRpcProvider(v.rpcUrl, undefined, { staticNetwork: true })
    }));

    let deployBlock = cfg.deployBlock;
    if (!Number.isInteger(deployBlock)) {
        deployBlock = 0;
        log('WARNING: network config has no deployBlock (deployed by an older deploy-and-configure.js) - scanning from block 0');
    }

    // ---- 1. close voting ----
    let closeBlock = null;
    if (closeVoting) {
        const admin = new ethers.Wallet(cfg.adminPrivateKey, validators[0].provider);
        const c = new ethers.Contract(address, artifact.abi, admin);
        if (await c.votingOpen()) {
            const tx = await c.closeVoting({ gasPrice: 0n, gasLimit: 100000n, type: 0 });
            const receipt = await tx.wait();
            closeBlock = receipt.blockNumber;
            log(`closeVoting() mined in block ${closeBlock} (tx ${tx.hash})`);
        } else {
            log('voting already closed');
        }
    }

    // ---- 2. common audit height ----
    const target = (closeBlock ?? await headOf(validators[0].provider)) + 2;
    const deadline = Date.now() + 180000;
    let heads = [];
    for (;;) {
        heads = await Promise.all(validators.map((v) => headOf(v.provider)));
        if (heads.every((h) => h >= target) || Date.now() > deadline) {
            break;
        }
        await sleep(2000);
    }
    if (heads.some((h) => h < 0)) {
        throw new Error(`unreachable validator(s): ${validators.filter((_, i) => heads[i] < 0).map((v) => v.name).join(', ')}`);
    }
    if (heads.some((h) => h < target)) {
        log(`WARNING: not every validator reached block ${target} within 180s (heads ${heads.join(', ')})`);
    }
    const H = Math.min(...heads);
    log(`heads ${heads.join(', ')} -> audit height H=${H}; recount range ${deployBlock}..${H} in chunks of ${chunk}`);

    // ---- 3. per-validator audit (sequential, so recount times are not contended) ----
    const rows = [];
    const sampleLinks = [];
    for (const v of validators) {
        const c = new ethers.Contract(address, artifact.abi, v.provider);
        const block = await v.provider.getBlock(H);
        const numCandidates = Number(await c.numCandidates({ blockTag: H }));
        const votingOpen = await c.votingOpen({ blockTag: H });
        const tally = [];
        for (let k = 0; k < numCandidates; k++) {
            tally.push(await c.getTally(k, { blockTag: H }));
        }

        const t0 = process.hrtime.bigint();
        const recount = new Array(numCandidates).fill(0n);
        const voters = new Set();
        let events = 0;
        let invalidCandidate = 0;
        for (let from = deployBlock; from <= H; from += chunk) {
            const to = Math.min(from + chunk - 1, H);
            const logs = await v.provider.getLogs({ address, topics: [voteCastTopic], fromBlock: from, toBlock: to });
            for (const lg of logs) {
                const parsed = iface.parseLog(lg);
                const cand = Number(parsed.args.candidateId);
                if (cand < numCandidates) {
                    recount[cand] += 1n;
                } else {
                    invalidCandidate++;
                }
                voters.add(parsed.args.voter.toLowerCase());
                events++;
                if (rows.length === 0 && sampleLinks.length < 3) {
                    sampleLinks.push({ voter: parsed.args.voter, candidateId: cand, block: lg.blockNumber, tx: lg.transactionHash });
                }
            }
        }
        const recountMs = Number(process.hrtime.bigint() - t0) / 1e6;

        rows.push({
            validator: v.name,
            rpcUrl: v.rpcUrl,
            height: H,
            blockHash: block.hash,
            stateRoot: block.stateRoot,
            votingOpen,
            tally: tally.map(String),
            recount: recount.map(String),
            voteEvents: events,
            uniqueVoters: voters.size,
            invalidCandidateEvents: invalidCandidate,
            recountMs: Number(recountMs.toFixed(1))
        });
        log(`${v.name}: hash ${block.hash} tally ${tally.join('/')} recount ${recount.join('/')} events ${events} unique ${voters.size} recount ${recountMs.toFixed(0)} ms`);
    }

    // ---- 4. checks ----
    const ref = rows[0];
    const fingerprint = (r) => JSON.stringify([r.blockHash, r.tally, r.recount, r.voteEvents, r.uniqueVoters]);
    for (const r of rows) {
        const total = r.tally.reduce((a, b) => a + BigInt(b), 0n);
        r.checks = {
            tallyEqualsRecount: r.tally.every((t, k) => t === r.recount[k]) && r.invalidCandidateEvents === 0,
            eventsEqualUniqueVoters: r.voteEvents === r.uniqueVoters,
            matchesValidator1: fingerprint(r) === fingerprint(ref),
            matchesCaliperConfirmed: expected === null ? null : total === BigInt(expected)
        };
    }
    const allPass = rows.every((r) => Object.values(r.checks).every((x) => x !== false));

    const perVote = rows.filter((r) => r.voteEvents > 0).map((r) => r.recountMs / r.voteEvents);
    const extrapolation = perVote.length === 0 ? null : {
        msPer10kVotesMean: Number((perVote.reduce((a, b) => a + b, 0) / perVote.length * 10000).toFixed(1)),
        msPer10kVotesMax: Number((Math.max(...perVote) * 10000).toFixed(1)),
        votes: extrapolateVotes,
        estimatedSecondsMean: Number((perVote.reduce((a, b) => a + b, 0) / perVote.length * extrapolateVotes / 1000).toFixed(1)),
        assumption: 'linear in vote count, same host and chunk size; one validator audited at a time'
    };

    const result = {
        generatedAt: new Date().toISOString(),
        contract: address,
        deployBlock,
        closeBlock,
        auditHeight: H,
        headsAtAudit: heads,
        chunk,
        expectedConfirmedVotes: expected,
        verdict: allPass ? 'PASS' : 'MISMATCH',
        rows,
        extrapolation,
        // evidence for the ballot-secrecy limitation: each vote links to a voter address
        sampleVoteLinks: sampleLinks
    };

    fs.mkdirSync(outDirArg, { recursive: true });
    fs.writeFileSync(path.join(outDirArg, 'audit.json'), JSON.stringify(result, null, 2));
    const header = 'validator,rpc_url,audit_height,block_hash,voting_open,tally,recount,vote_events,unique_voters,recount_ms,tally_eq_recount,events_eq_unique,matches_validator1,matches_caliper_confirmed';
    const csv = rows.map((r) => [r.validator, r.rpcUrl, r.height, r.blockHash, r.votingOpen, r.tally.join('/'), r.recount.join('/'),
        r.voteEvents, r.uniqueVoters, r.recountMs, r.checks.tallyEqualsRecount, r.checks.eventsEqualUniqueVoters,
        r.checks.matchesValidator1, r.checks.matchesCaliperConfirmed ?? ''].join(','));
    fs.writeFileSync(path.join(outDirArg, 'audit.csv'), [header, ...csv].join('\n') + '\n');

    for (const r of rows) {
        const failed = Object.entries(r.checks).filter(([, ok]) => ok === false).map(([k]) => k);
        log(`${r.validator}: ${failed.length === 0 ? 'all checks pass' : `MISMATCH in ${failed.join(', ')}`}`);
    }
    if (extrapolation) {
        log(`recount time ~${extrapolation.msPer10kVotesMean} ms per 10,000 votes -> ~${extrapolation.estimatedSecondsMean} s for ${extrapolateVotes} votes (linear estimate)`);
    }
    if (expected !== null) {
        log(`Caliper confirmed votes: ${expected}; contract total on validator1: ${ref.tally.reduce((a, b) => a + BigInt(b), 0n)}`);
    }
    console.log(`AUDIT_RESULT=${result.verdict} height=${H} events=${ref.voteEvents} unique=${ref.uniqueVoters}`);
    process.exitCode = allPass ? 0 : 1;
}

main().catch((err) => {
    console.error(err);
    process.exit(2);
});
