#!/usr/bin/env node
'use strict';

// Round 2 (election-scale plan) load generator. Replaces Caliper for the
// 5.5M-voter chain: Caliper's cast-vote workload loads every voter key from one
// JSON file into each worker (~1 GB at 5.5M voters) and holds per-tx records
// in memory for the whole round.
//
// Voters are deterministic, so nothing is stored: voter i's private key is
// keccak256(seed || uint256(i)) and voter i always votes for i mod numCandidates,
// so expected tallies are known exactly.
//
// Confirmation tracking: one watcher reads each new block once and resolves
// every pending tx in it; latency is the time the watcher saw the block minus
// the send time (same definition as round 1's Caliper connector). Votes are
// sent round-robin across all validators' RPC endpoints, like the connector.
//
// The watcher deliberately does NOT use eth_getBlockReceipts: in Besu 24.12.0
// it re-decodes the block's whole receipt list once per transaction (O(n^2)),
// and polling it for 600-tx blocks starved the polled validators' consensus
// thread until the chain lost quorum (first round 2 Area 1 run, n=4 at
// 100 votes/s). Instead: eth_getBlockByNumber (tx hashes) + one eth_getLogs
// for the contract in that block. Every successful registerVoter/castVote/
// openVoting emits exactly one event and a reverted call emits none, so
// "included with a log" = success, "included without one" = reverted.
//
// Modes:
//   register  --from=i --to=j [--window=3000] [--batch=200]
//             admin registers voters [i, j) with a continuous in-flight window
//             (sequential admin nonces, sent to the first RPC only). Resumable:
//             progress (lowest unconfirmed index) is kept in <state>.progress.
//   vote      --from=i --count=k --rate=r --out=file.csv [--label=x] [--send-to=1,2]
//             open-loop fixed-rate castVote from voters [i, i+k): sends on
//             schedule regardless of confirmations. Streams one CSV row per tx
//             and writes <out>.summary.json at the end.
//   double    --sample=1000 --range=0:N --out=file.csv
//             mass double-vote check: picks random voters in range that are in
//             Voted state, re-sends castVote from each (nonce 1), expects every
//             one to revert and tallies to be unchanged.
//   tally     [--expect-to=N] [--expect-ranges=a:b,c:d]  prints on-chain
//             tallies per node at one height + expected i mod N tallies
//   state     --index=i   prints voter i's address and on-chain state
//
// Common: --net=networks/besu-n4.json (caliper network config: rpcUrls,
//         contract address, admin key), --seed=<hex|text> (default "p4p-r2")
//
// Usage: node loadgen/p4p-gen.js <mode> --net=... [options]

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require(path.resolve(__dirname, '../caliper/node_modules/ethers'));

// ---------- args ----------
const mode = process.argv[2];
const opt = {};
for (const a of process.argv.slice(3)) {
    const m = a.match(/^--([^=]+)(?:=(.*))?$/);
    if (m) opt[m[1]] = m[2] === undefined ? true : m[2];
}
if (!mode || !opt.net) {
    console.error('Usage: node p4p-gen.js register|vote|double|tally|state --net=<networkConfig> [options]');
    process.exit(1);
}
const net = require(path.resolve(process.cwd(), opt.net)).voting;
const RPCS = net.rpcUrls;
const CHAIN_ID = BigInt(net.chainId || 1337);
const CONTRACT = net.contracts.VotingSystem.address;
const NUM_CANDIDATES = Number(net.numCandidates || 3);
// --send-to=1,2,3 limits vote sends to those validators (1-based), e.g. the
// survivors during an Area 2 crash test; the watcher always reads validator 1
const SEND_RPCS = opt['send-to'] ? String(opt['send-to']).split(',').map((k) => RPCS[Number(k) - 1]) : RPCS;
const SEED = ethers.keccak256(ethers.toUtf8Bytes(String(opt.seed || 'p4p-r2')));
const iface = new ethers.Interface([
    'function registerVoter(address voter)',
    'function castVote(uint8 candidateId)',
    'function getTally(uint8 candidateId) view returns (uint256)',
    'function getVoterState(address voter) view returns (uint8)',
    'function registeredVoters(address) view returns (bool)',
    'function votingOpen() view returns (bool)',
    'function openVoting()'
]);
const GAS_LIMIT = 100000n;

// ---------- voters ----------
const coder = ethers.AbiCoder.defaultAbiCoder();
function voterKey(i) {
    return ethers.keccak256(coder.encode(['bytes32', 'uint256'], [SEED, i]));
}
function voterAddress(i) {
    return ethers.computeAddress(voterKey(i));
}
function signRaw(privateKey, to, data, nonce) {
    const tx = ethers.Transaction.from({
        type: 0, chainId: CHAIN_ID, nonce, gasPrice: 0n, gasLimit: GAS_LIMIT, to, data, value: 0n
    });
    tx.signature = new ethers.SigningKey(privateKey).sign(tx.unsignedHash);
    const raw = tx.serialized;
    return { raw, hash: ethers.keccak256(raw) };
}

// ---------- JSON-RPC ----------
let rpcId = 1;
async function rpcBatch(url, calls) {
    if (calls.length === 0) return [];
    const body = calls.map(([method, params]) => ({ jsonrpc: '2.0', id: rpcId++, method, params }));
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const out = await res.json();
    if (!Array.isArray(out)) throw new Error(`batch RPC error: ${JSON.stringify(out).slice(0, 200)}`);
    const byId = new Map(out.map((r) => [r.id, r]));
    return body.map((b) => byId.get(b.id));
}
async function rpc(url, method, params = []) {
    const [r] = await rpcBatch(url, [[method, params]]);
    if (r.error) throw new Error(`${method}: ${r.error.message}`);
    return r.result;
}
async function call(url, fn, args, blockTag = 'latest') {
    const data = iface.encodeFunctionData(fn, args);
    const ret = await rpc(url, 'eth_call', [{ to: CONTRACT, data }, blockTag]);
    return iface.decodeFunctionResult(fn, ret)[0];
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- block watcher ----------
// pending: hash -> record; onConfirm(record, receipt, block) called once per tx
class Watcher {
    constructor(url, onConfirm) {
        this.url = url;
        this.onConfirm = onConfirm;
        this.pending = new Map();
        this.next = null;
        this.head = 0;
        this.running = false;
        this.blocks = 0;
    }
    async start() {
        this.next = parseInt(await rpc(this.url, 'eth_blockNumber'), 16) + 1;
        this.running = true;
        this.loop = this._loop();
    }
    async stop() { this.running = false; await this.loop; }
    async _loop() {
        while (this.running) {
            try {
                this.head = parseInt(await rpc(this.url, 'eth_blockNumber'), 16);
                while (this.next <= this.head) {
                    const tag = '0x' + this.next.toString(16);
                    const [blk, logs] = await rpcBatch(this.url, [
                        ['eth_getBlockByNumber', [tag, false]],
                        ['eth_getLogs', [{ fromBlock: tag, toBlock: tag, address: CONTRACT }]]]);
                    if (blk.error || logs.error || !blk.result) throw new Error(`block ${this.next}: ${JSON.stringify(blk.error || logs.error || 'missing')}`);
                    const seenMs = Date.now();
                    const block = { number: this.next, timestamp: parseInt(blk.result.timestamp, 16), txs: blk.result.transactions.length };
                    const withLog = new Set((logs.result || []).map((l) => l.transactionHash));
                    for (const h of blk.result.transactions) {
                        const rec = this.pending.get(h);
                        if (rec) {
                            this.pending.delete(h);
                            this.onConfirm(rec, { status: withLog.has(h) ? '0x1' : '0x0' }, block, seenMs);
                        }
                    }
                    this.blocks++;
                    this.next++;
                }
            } catch (err) {
                console.error(`[watcher] ${err.message}`);
                await sleep(1000);
            }
            await sleep(250);
        }
    }
}

// ---------- register ----------
async function register() {
    const from = Number(opt.from || 0);
    const to = Number(opt.to);
    const window = Number(opt.window || 3000);
    const batch = Number(opt.batch || 200);
    const url = RPCS[0];
    const admin = new ethers.Wallet(net.adminPrivateKey);
    const progressFile = opt.state || `register-${from}-${to}.progress`;

    if (!(await call(url, 'votingOpen', []))) {
        console.log('Voting not open - sending openVoting()');
        const nonce = parseInt(await rpc(url, 'eth_getTransactionCount', [admin.address, 'pending']), 16);
        const { raw } = signRaw(admin.privateKey, CONTRACT, iface.encodeFunctionData('openVoting', []), nonce);
        await rpc(url, 'eth_sendRawTransaction', [raw]);
        while (!(await call(url, 'votingOpen', []))) await sleep(1000);
    }

    let start = from;
    if (fs.existsSync(progressFile)) {
        start = Math.max(from, Number(fs.readFileSync(progressFile, 'utf8').trim()) || from);
        console.log(`Resuming at voter ${start} (from ${progressFile})`);
    }
    // the progress file only advances past confirmed voters, so on resume some
    // voters at/after `start` may already be registered (they revert as
    // "Already registered"); skip them with a cheap view call
    let skipped = 0;
    while (start < to && (await call(url, 'registeredVoters', [voterAddress(start)]))) { start++; skipped++; }
    if (skipped) console.log(`Skipped ${skipped} already-registered voters; starting at ${start}`);

    let nonce = parseInt(await rpc(url, 'eth_getTransactionCount', [admin.address, 'pending']), 16);
    console.log(`Registering voters [${start}, ${to}) = ${to - start}; admin ${admin.address} nonce ${nonce}; window ${window}`);

    let confirmed = 0, reverted = 0, resent = 0;
    const inflight = new Map(); // index -> { hash, raw, sentBlock }
    const watcher = new Watcher(url, (rec, r) => {
        inflight.delete(rec.i);
        confirmed++;
        if (r.status !== '0x1') reverted++;
    });
    await watcher.start();

    const t0 = Date.now();
    let next = start, lastLog = Date.now(), lastProgress = start;
    while (next < to || inflight.size > 0) {
        // fill the window
        while (next < to && inflight.size < window) {
            const n = Math.min(batch, to - next, window - inflight.size);
            const calls = [];
            for (let k = 0; k < n; k++) {
                const i = next + k;
                const data = iface.encodeFunctionData('registerVoter', [voterAddress(i)]);
                const { raw, hash } = signRaw(admin.privateKey, CONTRACT, data, nonce + k);
                const rec = { i, hash, raw, sentBlock: watcher.head };
                inflight.set(i, rec);
                watcher.pending.set(hash, rec);
                calls.push(['eth_sendRawTransaction', [raw]]);
            }
            // a validator restart (seeding watchdog: stuck node or memory) makes the
            // endpoint briefly unreachable - wait it out instead of exiting
            let res;
            for (let attempt = 0; ; attempt++) {
                try { res = await rpcBatch(url, calls); break; } catch (err) {
                    if (attempt >= 120) throw err;
                    if (attempt % 6 === 0) console.log(`[${new Date().toISOString()}] send failed (${err.message}); retrying for up to 10 min`);
                    await sleep(5000);
                }
            }
            const errs = res.filter((r) => r.error && !/already known|nonce too low/i.test(r.error.message));
            if (errs.length) {
                throw new Error(`${errs.length}/${n} sends failed at voter ${next}: ${errs[0].error.message}`);
            }
            next += n; nonce += n;
        }
        // resend anything stuck > 20 blocks (e.g. evicted); same signed tx, same hash
        for (const rec of inflight.values()) {
            if (watcher.head - rec.sentBlock > 20) {
                rec.sentBlock = watcher.head;
                resent++;
                await rpcBatch(url, [['eth_sendRawTransaction', [rec.raw]]]).catch(() => {});
            }
        }
        // progress = lowest unconfirmed index
        let low = next;
        for (const i of inflight.keys()) if (i < low) low = i;
        if (low !== lastProgress) { fs.writeFileSync(progressFile, String(low)); lastProgress = low; }
        if (Date.now() - lastLog > 30000) {
            const s = (Date.now() - t0) / 1000;
            console.log(`[${new Date().toISOString()}] confirmed ${confirmed} (${(confirmed / s).toFixed(1)} regs/s), inflight ${inflight.size}, reverted ${reverted}, resent ${resent}, next ${next}, head ${watcher.head}`);
            lastLog = Date.now();
        }
        await sleep(100);
    }
    await watcher.stop();
    fs.writeFileSync(progressFile, String(to));
    const s = (Date.now() - t0) / 1000;
    console.log(`DONE register [${start}, ${to}): confirmed ${confirmed}, reverted ${reverted}, resent ${resent}, ${s.toFixed(0)}s, ${(confirmed / s).toFixed(1)} regs/s`);
    if (reverted > 0) process.exitCode = 2;
}

// ---------- vote ----------
function pct(sorted, p) {
    if (!sorted.length) return null;
    return sorted[Math.max(0, Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1))];
}

async function vote() {
    const from = Number(opt.from || 0);
    const count = Number(opt.count);
    const rate = Number(opt.rate);
    const out = opt.out;
    const label = opt.label || `vote-${from}`;
    const drainSecs = Number(opt['drain-secs'] || 180);
    const fresh = !fs.existsSync(out) || fs.statSync(out).size === 0;
    const csv = fs.createWriteStream(out, { flags: 'a' });
    if (fresh) csv.write('voter,hash,send_ms,confirm_ms,latency_ms,block,status,send_lag_ms\n');

    let ok = 0, revertedN = 0, sendErrors = 0;
    const latencies = [];
    const sendLags = [];
    let firstSend = null, lastConfirm = null;
    const watcher = new Watcher(RPCS[0], (rec, r, block, seenMs) => {
        const lat = seenMs - rec.sendMs;
        const st = r.status === '0x1' ? 'ok' : 'reverted';
        if (st === 'ok') { ok++; latencies.push(lat); } else revertedN++;
        lastConfirm = seenMs;
        csv.write(`${rec.i},${rec.hash},${rec.sendMs},${seenMs},${lat},${block.number},${st},${rec.lag}\n`);
    });
    await watcher.start();

    // pre-sign ahead of the schedule so signing never delays sends
    const signed = [];
    let signedUpTo = from;
    const end = from + count;
    const skip = new Set(opt['skip-file'] && fs.existsSync(opt['skip-file'])
        ? fs.readFileSync(opt['skip-file'], 'utf8').split('\n').filter(Boolean).map(Number) : []);
    let skipped = 0;
    function topUp() {
        while (signedUpTo < end && signed.length < rate * 5) {
            const i = signedUpTo++;
            if (skip.has(i)) { skipped++; continue; }
            const data = iface.encodeFunctionData('castVote', [i % NUM_CANDIDATES]);
            signed.push({ i, ...signRaw(voterKey(i), CONTRACT, data, 0) });
        }
    }
    topUp();

    console.log(`[${label}] castVote voters [${from}, ${end}) at ${rate} votes/s open-loop -> ${out}`);
    const t0 = Date.now();
    let sent = 0, cursor = 0, inflightHttp = 0, lastLog = Date.now();
    const toSend = count - skip.size;
    if (skip.size) console.log(`[${label}] skipping ${skip.size} voters already Voted (resumed round)`);
    while (sent < toSend) {
        const due = Math.min(toSend, Math.floor(((Date.now() - t0) / 1000) * rate));
        while (sent < due && signed.length) {
            const n = Math.min(due - sent, signed.length, 100);
            const chunk = signed.splice(0, n);
            const sendMs = Date.now();
            if (firstSend === null) firstSend = sendMs;
            for (const [k, s] of chunk.entries()) {
                // scheduled send time of this tx vs when it actually went out
                const lag = sendMs - (t0 + ((sent + k) / rate) * 1000);
                sendLags.push(lag);
                const rec = { i: s.i, hash: s.hash, sendMs, lag: Math.round(lag) };
                watcher.pending.set(s.hash, rec);
            }
            const url = SEND_RPCS[cursor++ % SEND_RPCS.length];
            inflightHttp++;
            rpcBatch(url, chunk.map((s) => ['eth_sendRawTransaction', [s.raw]]))
                .then((res) => {
                    res.forEach((r, k) => {
                        if (r && r.error) {
                            const s = chunk[k];
                            watcher.pending.delete(s.hash);
                            sendErrors++;
                            csv.write(`${s.i},${s.hash},${sendMs},,,,send_error:${String(r.error.message).replace(/[,\n]/g, ' ')},\n`);
                        }
                    });
                })
                .catch((err) => {
                    for (const s of chunk) {
                        watcher.pending.delete(s.hash);
                        sendErrors++;
                        csv.write(`${s.i},${s.hash},${sendMs},,,,send_error:${String(err.message).replace(/[,\n]/g, ' ')},\n`);
                    }
                })
                .finally(() => { inflightHttp--; });
            sent += n;
        }
        topUp();
        if (Date.now() - lastLog > 60000) {
            const s = (Date.now() - t0) / 1000;
            console.log(`[${label}] t=${s.toFixed(0)}s sent ${sent} (${(sent / s).toFixed(1)}/s) ok ${ok} reverted ${revertedN} send_err ${sendErrors} pending ${watcher.pending.size} head ${watcher.head}`);
            lastLog = Date.now();
        }
        await sleep(10);
    }
    const sendEnd = Date.now();
    while (inflightHttp > 0) await sleep(50);
    // drain: wait for remaining receipts, bounded
    const drainDeadline = Date.now() + drainSecs * 1000;
    while (watcher.pending.size > 0 && Date.now() < drainDeadline) await sleep(500);
    await watcher.stop();
    const dropped = watcher.pending.size;
    for (const rec of watcher.pending.values()) {
        csv.write(`${rec.i},${rec.hash},${rec.sendMs},,,,dropped,${rec.lag}\n`);
    }
    await new Promise((r) => csv.end(r));

    latencies.sort((a, b) => a - b);
    sendLags.sort((a, b) => a - b);
    const summary = {
        label, from, count, skippedAlreadyVoted: skip.size, targetRate: rate,
        sent, ok, reverted: revertedN, sendErrors, dropped,
        successPct: +(ok * 100 / Math.max(1, toSend)).toFixed(4),
        sendRate: +(sent / ((sendEnd - t0) / 1000)).toFixed(2),
        throughput: lastConfirm ? +(ok / ((lastConfirm - firstSend) / 1000)).toFixed(2) : 0,
        latencyMs: { p50: pct(latencies, 50), p95: pct(latencies, 95), p99: pct(latencies, 99), max: latencies[latencies.length - 1] ?? null,
            mean: latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : null },
        sendLagMs: { p50: pct(sendLags, 50), p99: pct(sendLags, 99), max: sendLags[sendLags.length - 1] ?? null },
        startMs: t0, sendEndMs: sendEnd, endMs: Date.now(), blocksWatched: watcher.blocks
    };
    fs.writeFileSync(`${out}.summary.json`, JSON.stringify(summary, null, 2));
    console.log(`[${label}] DONE ${JSON.stringify(summary)}`);
}

// ---------- tallies ----------
function expectedTallies(ranges) {
    const t = new Array(NUM_CANDIDATES).fill(0n);
    for (const [a, b] of ranges) {
        for (let c = 0; c < NUM_CANDIDATES; c++) {
            // count of i in [a, b) with i mod N == c
            const first = a + ((c - (a % NUM_CANDIDATES)) + NUM_CANDIDATES) % NUM_CANDIDATES;
            t[c] += first < b ? BigInt(Math.floor((b - 1 - first) / NUM_CANDIDATES) + 1) : 0n;
        }
    }
    return t;
}
async function readTallies(url, blockTag) {
    const t = [];
    for (let c = 0; c < NUM_CANDIDATES; c++) t.push(await call(url, 'getTally', [c], blockTag));
    return t;
}
async function tally() {
    const heights = await Promise.all(RPCS.map(async (u) => parseInt(await rpc(u, 'eth_blockNumber'), 16)));
    const tag = '0x' + Math.min(...heights).toString(16);
    const rows = [];
    for (const u of RPCS) {
        const blk = await rpc(u, 'eth_getBlockByNumber', [tag, false]);
        rows.push({ url: u, tallies: (await readTallies(u, tag)).map(String), hash: blk.hash });
    }
    const agree = rows.every((r) => r.hash === rows[0].hash && r.tallies.join() === rows[0].tallies.join());
    const res = { block: parseInt(tag, 16), heights, agree, nodes: rows };
    const ranges = opt['expect-ranges'] ? opt['expect-ranges'].split(',').map((r) => r.split(':').map(Number))
        : opt['expect-to'] ? [[0, Number(opt['expect-to'])]] : null;
    if (ranges) {
        res.expected = expectedTallies(ranges).map(String);
        res.match = res.expected.join() === rows[0].tallies.join();
        res.sum = rows[0].tallies.reduce((a, b) => a + BigInt(b), 0n).toString();
    }
    console.log(JSON.stringify(res, null, 2));
    if (!agree || res.match === false) process.exitCode = 1;
}

// ---------- mass double vote ----------
async function double() {
    const sample = Number(opt.sample || 1000);
    const [lo, hi] = (opt.range || '').split(':').map(Number);
    const out = opt.out || 'double-vote.csv';
    const url = RPCS[0];
    const picked = new Set();
    while (picked.size < sample) picked.add(lo + Math.floor(Math.random() * (hi - lo)));
    const voters = [...picked].sort((a, b) => a - b);

    // precondition: every picked voter is already in Voted state (2)
    const notVoted = [];
    for (const i of voters) {
        if (Number(await call(url, 'getVoterState', [voterAddress(i)])) !== 2) notVoted.push(i);
    }
    if (notVoted.length) {
        console.error(`Precondition failed: ${notVoted.length} picked voters are not in Voted state, e.g. ${notVoted.slice(0, 5)}`);
        process.exit(1);
    }
    const before = await readTallies(url, 'latest');
    const csv = fs.createWriteStream(out);
    csv.write('voter,hash,block,status,send_error\n');
    const results = new Map();
    const watcher = new Watcher(url, (rec, r, block) => { results.set(rec.i, { status: r.status === '0x1' ? 'ok' : 'reverted', block: block.number, hash: rec.hash }); });
    await watcher.start();
    let sendErrors = 0;
    for (let k = 0; k < voters.length; k += 100) {
        const chunk = voters.slice(k, k + 100).map((i) => {
            // second vote: same voter, nonce 1, a different candidate than the first
            const { raw, hash } = signRaw(voterKey(i), CONTRACT, iface.encodeFunctionData('castVote', [(i + 1) % NUM_CANDIDATES]), 1);
            watcher.pending.set(hash, { i, hash });
            return { i, raw, hash };
        });
        const res = await rpcBatch(RPCS[(k / 100) % RPCS.length], chunk.map((c) => ['eth_sendRawTransaction', [c.raw]]));
        res.forEach((r, j) => {
            if (r.error) {
                sendErrors++;
                watcher.pending.delete(chunk[j].hash);
                results.set(chunk[j].i, { status: 'send_error', error: r.error.message, hash: chunk[j].hash });
            }
        });
    }
    const deadline = Date.now() + 180000;
    while (watcher.pending.size > 0 && Date.now() < deadline) await sleep(500);
    await watcher.stop();
    for (const rec of watcher.pending.values()) results.set(rec.i, { status: 'dropped', hash: rec.hash });
    for (const i of voters) {
        const r = results.get(i);
        csv.write(`${i},${r.hash},${r.block ?? ''},${r.status},${(r.error || '').replace(/[,\n]/g, ' ')}\n`);
    }
    await new Promise((r) => csv.end(r));
    const after = await readTallies(url, 'latest');
    const counts = {};
    for (const r of results.values()) counts[r.status] = (counts[r.status] || 0) + 1;
    const summary = { sample, range: [lo, hi], counts, sendErrors, talliesBefore: before.map(String), talliesAfter: after.map(String),
        talliesUnchanged: before.join() === after.join(), allBlocked: !counts.ok };
    fs.writeFileSync(`${out}.summary.json`, JSON.stringify(summary, null, 2));
    console.log(JSON.stringify(summary, null, 2));
    if (!summary.allBlocked || !summary.talliesUnchanged) process.exitCode = 1;
}

async function state() {
    const i = Number(opt.index);
    const addr = voterAddress(i);
    const reg = await call(RPCS[0], 'registeredVoters', [addr]);
    const st = await call(RPCS[0], 'getVoterState', [addr]);
    console.log(JSON.stringify({ index: i, address: addr, registered: reg, state: ['NotVoted', 'Processing', 'Voted'][Number(st)] }));
}

// voted-scan --from=i --to=j --out=file : writes the indices in [i, j) whose
// voter is already in Voted state (used to resume a soak round that was cut
// short, so the resumed round doesn't re-send votes that already landed)
async function votedScan() {
    const from = Number(opt.from), to = Number(opt.to), B = 500;
    const voted = [];
    for (let s = from; s < to; s += B) {
        const idx = []; for (let i = s; i < Math.min(to, s + B); i++) idx.push(i);
        const res = await rpcBatch(RPCS[0], idx.map((i) => ['eth_call', [{ to: CONTRACT, data: iface.encodeFunctionData('getVoterState', [voterAddress(i)]) }, 'latest']]));
        res.forEach((r, k) => { if (Number(BigInt(r.result)) === 2) voted.push(idx[k]); });
    }
    fs.writeFileSync(opt.out, voted.join('\n') + (voted.length ? '\n' : ''));
    console.log(`voted-scan [${from}, ${to}): ${voted.length} already voted -> ${opt.out}`);
}

const modes = { register, vote, double, tally, state, 'voted-scan': votedScan };
if (!modes[mode]) { console.error(`unknown mode ${mode}`); process.exit(1); }
modes[mode]().catch((err) => { console.error(err); process.exit(1); });
