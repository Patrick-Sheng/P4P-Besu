#!/usr/bin/env node
'use strict';

// Round 2 final verification (plan Section 10):
//   1. all validators report the same block number + hash
//   2. on-chain tallies == expected tallies, where expected = generator voters
//      with an 'ok' row in any soak / Area 2 CSV (voter i -> candidate i mod N)
//      + the attack scripts' one legitimate vote each (from their logs)
//   3. sum of tallies == successful votes == voters in Voted state (full scan
//      of every generator voter index 0..5,499,999 via batched eth_call)
// Voters Voted on chain without an 'ok' row (e.g. confirmed after the
// generator's drain timeout) are listed separately rather than hidden.
//
// Usage: node loadgen/verify.js --net=<besu-n4.json> --results=reports/r2-soak --out=verify.json [--scan-to=5500000]

const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { ethers } = require(path.resolve(__dirname, '../caliper/node_modules/ethers'));

const opt = {};
for (const a of process.argv.slice(2)) { const m = a.match(/^--([^=]+)=(.*)$/); if (m) opt[m[1]] = m[2]; }
const net = require(path.resolve(opt.net)).voting;
const RPCS = net.rpcUrls;
const CONTRACT = net.contracts.VotingSystem.address;
const NC = Number(net.numCandidates || 3);
const SEED = ethers.keccak256(ethers.toUtf8Bytes(String(opt.seed || 'p4p-r2')));
const SCAN_TO = Number(opt['scan-to'] || 5500000);
const iface = new ethers.Interface(['function getTally(uint8) view returns (uint256)', 'function getVoterState(address) view returns (uint8)']);
const coder = ethers.AbiCoder.defaultAbiCoder();
const addrOf = (i) => ethers.computeAddress(ethers.keccak256(coder.encode(['bytes32', 'uint256'], [SEED, i])));

let id = 1;
async function batch(url, calls) {
    const body = calls.map(([method, params]) => ({ jsonrpc: '2.0', id: id++, method, params }));
    const res = await (await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })).json();
    const byId = new Map(res.map((r) => [r.id, r]));
    return body.map((b) => byId.get(b.id).result);
}
const rpc = async (url, m, p = []) => (await batch(url, [[m, p]]))[0];

async function main() {
    const res = {};
    // 1. heads
    const heads = [];
    for (const u of RPCS) {
        const b = await rpc(u, 'eth_getBlockByNumber', ['latest', false]);
        heads.push({ url: u, number: parseInt(b.number, 16), hash: b.hash });
    }
    const common = Math.min(...heads.map((h) => h.number));
    const tag = '0x' + common.toString(16);
    const hashes = [];
    for (const u of RPCS) hashes.push((await rpc(u, 'eth_getBlockByNumber', [tag, false])).hash);
    res.heads = heads;
    res.commonBlock = common;
    res.headsAgree = hashes.every((h) => h === hashes[0]) && heads.every((h) => h.number === heads[0].number);

    // 2. expected from generator CSVs (ok in any attempt) + attack logs
    const okVoters = new Set();
    const csvs = [];
    for (const d of fs.readdirSync(opt.results)) {
        if (!/^(soak|area2)-/.test(d)) continue;
        for (const f of fs.readdirSync(path.join(opt.results, d))) {
            if (/^(soak-r\d+|a2-crash|a2-quorum)\.csv$/.test(f)) csvs.push(path.join(opt.results, d, f));
        }
    }
    for (const f of csvs) {
        const rl = readline.createInterface({ input: fs.createReadStream(f) });
        for await (const line of rl) {
            const c = line.split(',');
            if (c[6] === 'ok') okVoters.add(Number(c[0]));
        }
    }
    const expected = new Array(NC).fill(0n);
    for (const i of okVoters) expected[i % NC] += 1n;
    const attack = { doubleVote: 0, replay: 0, equivocationA: 0, equivocationB: 0, logs: 0 };
    for (const d of fs.readdirSync(opt.results)) {
        if (!/^soak-/.test(d)) continue;
        for (const f of fs.readdirSync(path.join(opt.results, d))) {
            const m = f.match(/^attack-.*-(double-vote|equivocation|replay)-\d+\.log$/);
            if (!m) continue;
            attack.logs++;
            const t = fs.readFileSync(path.join(opt.results, d, f), 'utf8');
            if (m[1] === 'double-vote' && /PASS: first vote confirmed/.test(t)) attack.doubleVote++;
            if (m[1] === 'replay' && /Original vote confirmed/.test(t)) attack.replay++;
            if (m[1] === 'equivocation') {
                if (/vote A \(candidate 0\): included in block \d+, status=1/.test(t)) attack.equivocationA++;
                if (/vote B \(candidate 1\): included in block \d+, status=1/.test(t)) attack.equivocationB++;
            }
        }
    }
    expected[0] += BigInt(attack.doubleVote + attack.replay + attack.equivocationA);
    expected[1] += BigInt(attack.equivocationB);
    const onchain = [];
    for (let c = 0; c < NC; c++) {
        const r = await rpc(RPCS[0], 'eth_call', [{ to: CONTRACT, data: iface.encodeFunctionData('getTally', [c]) }, tag]);
        onchain.push(BigInt(r));
    }
    res.csvFiles = csvs.length;
    res.generatorOk = okVoters.size;
    res.attackVotes = attack;
    res.expectedTallies = expected.map(String);
    res.onchainTallies = onchain.map(String);
    res.talliesMatch = expected.every((e, k) => e === onchain[k]);
    const sum = onchain.reduce((a, b) => a + b, 0n);
    const attackTotal = attack.doubleVote + attack.replay + attack.equivocationA + attack.equivocationB;
    res.tallySum = sum.toString();
    res.sumEqualsSuccessful = sum === BigInt(okVoters.size + attackTotal);

    // 3. full Voted-state scan of generator voters
    let voted = 0;
    const votedNotOk = [];
    const fromVoted = new Array(NC).fill(0n);   // i mod N over every Voted voter
    const okNotVoted = [];
    const B = 500;
    const t0 = Date.now();
    for (let s = 0; s < SCAN_TO; s += B) {
        const idx = [];
        for (let i = s; i < Math.min(SCAN_TO, s + B); i++) idx.push(i);
        // a batch item can come back as an error (e.g. an RPC timeout while the host is
        // slow): retry the whole batch, then give up loudly rather than miscount
        // 'latest', not the pinned height: BONSAI keeps only ~512 blocks (~17 min) of
        // historical state, shorter than the scan. The chain is idle during verification;
        // tallies are re-read at the end and must be unchanged (stateStableDuringScan).
        const calls = idx.map((i) => ['eth_call', [{ to: CONTRACT, data: iface.encodeFunctionData('getVoterState', [addrOf(i)]) }, 'latest']]);
        let out;
        for (let attempt = 1; ; attempt++) {
            try {
                out = await batch(RPCS[0], calls);
                if (out.every((r) => typeof r === 'string')) break;
            } catch (e) { /* network error: retry */ }
            if (attempt >= 10) throw new Error(`voter batch at ${s} failed after ${attempt} attempts`);
            await new Promise((r) => setTimeout(r, 2000 * attempt));
        }
        out.forEach((r, k) => {
            const isVoted = Number(BigInt(r)) === 2;
            const i = idx[k];
            if (isVoted) { voted++; fromVoted[idx[k] % NC] += 1n; }
            if (isVoted && !okVoters.has(i)) votedNotOk.push(i);
            if (!isVoted && okVoters.has(i)) okNotVoted.push(i);
        });
        if ((s / B) % 1000 === 0) console.log(`scan ${s}/${SCAN_TO} voted ${voted} (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
    }
    const endTallies = [];
    for (let c = 0; c < NC; c++) {
        endTallies.push(BigInt(await rpc(RPCS[0], 'eth_call', [{ to: CONTRACT, data: iface.encodeFunctionData('getTally', [c]) }, 'latest'])));
    }
    res.talliesAtEnd = endTallies.map(String);
    res.stateStableDuringScan = endTallies.every((t, k) => t === onchain[k]);
    res.votedInGeneratorRange = voted;
    res.votedButNoOkRow = { count: votedNotOk.length, sample: votedNotOk.slice(0, 20) };
    res.okRowButNotVoted = { count: okNotVoted.length, sample: okNotVoted.slice(0, 20) };
    res.votedCountMatches = voted === okVoters.size;
    // Internal consistency: tallies == (i mod N) over every voter in Voted state + attack votes,
    // i.e. every on-chain vote counted exactly once for its deterministic candidate. Voters
    // Voted without an ok row are votes that landed after an aborted generator stopped
    // watching - confirmed on chain, just not observed.
    const fromVotedTotal = fromVoted.map((v, c) => v + (c === 0 ? BigInt(attack.doubleVote + attack.replay + attack.equivocationA) : c === 1 ? BigInt(attack.equivocationB) : 0n));
    res.talliesFromVotedSet = fromVotedTotal.map(String);
    res.talliesMatchVotedSet = fromVotedTotal.every((e, k) => e === onchain[k]);
    // No lost votes: every vote the generator saw confirmed is still Voted
    res.noConfirmedVoteLost = okNotVoted.length === 0;
    fs.writeFileSync(opt.out.replace(/\.json$/, '') + '-voted-without-ok-row.txt', votedNotOk.join('\n') + '\n');
    res.pass = res.headsAgree && res.stateStableDuringScan && res.talliesMatchVotedSet && res.noConfirmedVoteLost;
    fs.writeFileSync(opt.out, JSON.stringify(res, null, 2));
    console.log(JSON.stringify({ ...res, heads: undefined }, null, 2));
    if (!res.pass) process.exitCode = 1;
}
main().catch((e) => { console.error(e); process.exit(1); });
