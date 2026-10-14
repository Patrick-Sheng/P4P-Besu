#!/usr/bin/env node
'use strict';

// T2 - transaction-pool eviction / client retry summary for ONE run of
// scripts/additional-fault.sh T2 <V0..V3>. Run after the load has finished
// and the pools have drained. Inputs (all inside <runDir>):
//   txlog/*.ndjson    every castVote send from caliper/connector/voting-connector.js
//                     (txLogDir): hash, submitTimeMs, sendOk, outcome, confirmTimeMs, retries
//   fault-events.csv  <epochMs>,<label> from fault-injection/lib.sh (crash / restart / chain-resumed)
//   txpool.csv        monitoring/txpool-sampler.sh
//   peak-mem.txt      monitoring/resource-watchdog.sh
//
// "Confirmed" is decided on-chain, not by the client: every sent hash is looked
// up with eth_getTransactionReceipt after the pool has drained (a client that
// gave up waiting would otherwise count an included vote as lost). The sum of
// getTally() is reported as a cross-check.
//
// Definitions (also written into the JSON):
//   outage          first "crash" event -> "chain-resumed" event (first block after quorum returns)
//   outage votes    votes whose submit time falls inside the outage
//   latency         connector-measured submit -> receipt seen; for a vote the connector stopped
//                   watching but which is on-chain, inclusion block timestamp - submit (counted
//                   separately as latencyFallbackCount, 1 s timestamp resolution)
//   pool empty      first txpool.csv sample after outage end with every validator's pool at 0
//
// Usage: node eviction-summary.js <runDir> <networkConfig> <label>
// Writes <runDir>/eviction-summary.json and <runDir>/eviction-summary.csv (header + one row).

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const [, , runDir, networkConfigArg, label = ''] = process.argv;
if (!runDir || !networkConfigArg) {
    console.error('Usage: node eviction-summary.js <runDir> <networkConfig> <label>');
    process.exit(2);
}

const readLines = (file) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()) : []);
const pct = (arr, p) => {
    if (arr.length === 0) {
        return null;
    }
    const s = [...arr].sort((a, b) => a - b);
    return s[Math.max(0, Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1))];
};

async function mapLimit(items, limit, fn) {
    const out = new Array(items.length);
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
        while (next < items.length) {
            const i = next++;
            out[i] = await fn(items[i]);
        }
    }));
    return out;
}

async function main() {
    const cfgPath = path.resolve(process.cwd(), networkConfigArg);
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')).voting;
    const workspaceRoot = path.resolve(path.dirname(cfgPath), '..');
    const artifact = JSON.parse(fs.readFileSync(path.resolve(workspaceRoot, cfg.contracts.VotingSystem.abiPath), 'utf8'));
    const provider = new ethers.JsonRpcProvider(cfg.rpcUrls[0], undefined, { staticNetwork: true });

    // ---- sends ----
    const txlogDir = path.join(runDir, 'txlog');
    const byHash = new Map();
    let duplicateRecords = 0;
    if (fs.existsSync(txlogDir)) {
        for (const f of fs.readdirSync(txlogDir).filter((n) => n.endsWith('.ndjson'))) {
            for (const line of readLines(path.join(txlogDir, f))) {
                const r = JSON.parse(line);
                if (r.verb !== 'castVote') {
                    continue;
                }
                if (byHash.has(r.hash)) {
                    duplicateRecords++;
                }
                byHash.set(r.hash, r);
            }
        }
    }
    if (byHash.size === 0) {
        throw new Error(`no castVote records in ${txlogDir} - was voting.txLogDir set in the network config?`);
    }
    const records = [...byHash.values()];
    const sent = records.filter((r) => r.sendOk);
    const sendFailed = records.length - sent.length;

    // ---- on-chain outcome of every accepted send ----
    const receipts = await mapLimit(sent, 20, (r) => provider.send('eth_getTransactionReceipt', [r.hash]));
    const blockTs = new Map();
    const tsOf = async (n) => {
        if (!blockTs.has(n)) {
            blockTs.set(n, Number((await provider.getBlock(n)).timestamp) * 1000);
        }
        return blockTs.get(n);
    };
    let confirmed = 0;
    let reverted = 0;
    let latencyFallbackCount = 0;
    for (let i = 0; i < sent.length; i++) {
        const r = sent[i];
        const rc = receipts[i];
        r.onchain = rc ? (rc.status === '0x1' ? 'confirmed' : 'reverted') : 'lost';
        if (r.onchain === 'confirmed') {
            confirmed++;
            if (r.outcome === 'confirmed') {
                r.latencyMs = r.confirmTimeMs - r.submitTimeMs;
            } else {
                r.latencyMs = (await tsOf(parseInt(rc.blockNumber, 16))) - r.submitTimeMs;
                r.latencyFallback = true;
                latencyFallbackCount++;
            }
        } else if (r.onchain === 'reverted') {
            reverted++;
        }
    }
    const lost = sent.length - confirmed;

    const contract = new ethers.Contract(cfg.contracts.VotingSystem.address, artifact.abi, provider);
    const numCandidates = Number(await contract.numCandidates());
    let tallyTotal = 0n;
    for (let k = 0; k < numCandidates; k++) {
        tallyTotal += await contract.getTally(k);
    }

    // ---- outage window ----
    const events = readLines(path.join(runDir, 'fault-events.csv')).map((l) => {
        const [ms, ...rest] = l.split(',');
        return { ms: Number(ms), label: rest.join(',') };
    });
    const firstCrash = events.find((e) => /^crash/.test(e.label));
    const restarts = events.filter((e) => /^restart/.test(e.label));
    const resumed = events.find((e) => /^chain-resumed/.test(e.label));
    const outageStart = firstCrash ? firstCrash.ms : null;
    const outageEnd = resumed ? resumed.ms : null;
    const inOutage = (r) => outageStart !== null && r.submitTimeMs >= outageStart && (outageEnd === null || r.submitTimeMs < outageEnd);
    const outageVotes = sent.filter(inOutage);
    const outageConfirmed = outageVotes.filter((r) => r.onchain === 'confirmed');
    const outageLat = outageConfirmed.map((r) => r.latencyMs);
    const allLat = sent.filter((r) => r.onchain === 'confirmed').map((r) => r.latencyMs);

    // ---- pool size ----
    const poolLines = readLines(path.join(runDir, 'txpool.csv'));
    const poolCols = poolLines.length ? poolLines[0].split(',') : [];
    const poolRows = poolLines.slice(1).map((l) => l.split(',').map(Number));
    const vCols = poolCols.map((c, i) => [c, i]).filter(([c]) => /^v\d+_pool$/.test(c));
    const peakPool = {};
    for (const [c, i] of vCols) {
        peakPool[c.replace('_pool', '')] = Math.max(-1, ...poolRows.map((r) => r[i]));
    }
    const lastSubmitMs = Math.max(...sent.map((r) => r.submitTimeMs));
    const firstEmptyAfter = (t) => {
        const row = poolRows.find((r) => r[0] >= t && vCols.every(([, i]) => r[i] === 0));
        return row ? row[0] : null;
    };
    const poolEmptyMs = outageEnd !== null ? firstEmptyAfter(outageEnd) : null;
    const poolEmptyAfterLastSubmitMs = firstEmptyAfter(lastSubmitMs);

    // ---- memory ----
    const peakMem = {};
    for (const m of (fs.existsSync(path.join(runDir, 'peak-mem.txt')) ? fs.readFileSync(path.join(runDir, 'peak-mem.txt'), 'utf8') : '').matchAll(/(v\d+)=(\d+)/g)) {
        peakMem[m[1]] = Number(m[2]);
    }

    // ---- client retries (V3) ----
    const retriesTotal = sent.reduce((a, r) => a + (r.retries || 0), 0);
    const retryDist = {};
    for (const r of sent.filter((x) => x.onchain === 'confirmed')) {
        retryDist[r.retries || 0] = (retryDist[r.retries || 0] || 0) + 1;
    }

    const s = (ms) => (ms === null ? null : Number((ms / 1000).toFixed(1)));
    const summary = {
        label,
        runDir: path.resolve(runDir),
        definitions: {
            outage: 'first crash event -> chain-resumed event',
            latency: 'connector submit->receipt; block timestamp - submit where the connector had stopped watching',
            lost: 'accepted sends minus those with a status-1 receipt on validator1 after the pools drained (votesReverted is a subset)'
        },
        votesSent: sent.length,
        sendFailed,
        duplicateRecords,
        votesConfirmed: confirmed,
        votesReverted: reverted,
        votesLost: lost,
        lossPct: Number((100 * lost / sent.length).toFixed(2)),
        onchainTallyTotal: tallyTotal.toString(),
        tallyMatchesConfirmed: tallyTotal === BigInt(confirmed),
        outage: {
            start: outageStart,
            end: outageEnd,
            durationS: outageStart !== null && outageEnd !== null ? s(outageEnd - outageStart) : null,
            lastRestart: restarts.length ? restarts[restarts.length - 1].ms : null,
            restartToResumeS: restarts.length && outageEnd !== null ? s(outageEnd - restarts[restarts.length - 1].ms) : null,
            votesSent: outageVotes.length,
            votesConfirmed: outageConfirmed.length,
            votesLost: outageVotes.length - outageConfirmed.length,
            p50Ms: pct(outageLat, 50),
            p95Ms: pct(outageLat, 95),
            p99Ms: pct(outageLat, 99)
        },
        allVotesP95Ms: pct(allLat, 95),
        latencyFallbackCount,
        poolEmptyAfterOutageEndS: poolEmptyMs !== null && outageEnd !== null ? s(poolEmptyMs - outageEnd) : null,
        poolEmptyAfterLastSubmitS: poolEmptyAfterLastSubmitMs !== null ? s(poolEmptyAfterLastSubmitMs - lastSubmitMs) : null,
        lastSubmitMs,
        peakPool,
        peakValidatorMemMb: peakMem,
        retries: { total: retriesTotal, votesRetried: sent.filter((r) => r.retries > 0).length, confirmedByRetryCount: retryDist, retryErrors: sent.reduce((a, r) => a + (r.retryErrors || 0), 0) }
    };
    fs.writeFileSync(path.join(runDir, 'eviction-summary.json'), JSON.stringify(summary, null, 2));

    const cols = {
        label, votes_sent: sent.length, send_failed: sendFailed, confirmed, reverted, lost, loss_pct: summary.lossPct,
        onchain_tally_total: summary.onchainTallyTotal, outage_s: summary.outage.durationS, restart_to_resume_s: summary.outage.restartToResumeS,
        outage_votes_sent: summary.outage.votesSent, outage_votes_lost: summary.outage.votesLost,
        outage_p50_ms: summary.outage.p50Ms, outage_p95_ms: summary.outage.p95Ms, outage_p99_ms: summary.outage.p99Ms,
        latency_fallback: latencyFallbackCount, pool_empty_after_outage_s: summary.poolEmptyAfterOutageEndS,
        pool_empty_after_last_submit_s: summary.poolEmptyAfterLastSubmitS,
        peak_pool: Math.max(-1, ...Object.values(peakPool)), peak_validator_mem_mb: Math.max(0, ...Object.values(peakMem)),
        retries_total: retriesTotal, votes_retried: summary.retries.votesRetried, retry_errors: summary.retries.retryErrors,
        run_dir: summary.runDir
    };
    fs.writeFileSync(path.join(runDir, 'eviction-summary.csv'),
        Object.keys(cols).join(',') + '\n' + Object.values(cols).map((v) => (v === null ? '' : JSON.stringify(v).replace(/^"|"$/g, ''))).join(',') + '\n');

    console.log(`T2 ${label}: sent ${sent.length} (send failures ${sendFailed}), confirmed ${confirmed}, reverted ${reverted}, lost ${lost} (${summary.lossPct}%); on-chain tally total ${tallyTotal}`);
    console.log(`  outage ${summary.outage.durationS ?? '?'} s (restart -> resume ${summary.outage.restartToResumeS ?? '?'} s): ${outageVotes.length} votes sent, ${summary.outage.votesLost} lost, latency p50/p95/p99 ${summary.outage.p50Ms ?? '-'}/${summary.outage.p95Ms ?? '-'}/${summary.outage.p99Ms ?? '-'} ms (${latencyFallbackCount} from block timestamps)`);
    console.log(`  pool empty ${summary.poolEmptyAfterOutageEndS ?? '?'} s after outage end (${summary.poolEmptyAfterLastSubmitS ?? '?'} s after last submit); peak pool ${JSON.stringify(peakPool)}; peak validator MB ${JSON.stringify(peakMem)}`);
    if (retriesTotal > 0) {
        console.log(`  retries: ${retriesTotal} resends for ${summary.retries.votesRetried} votes; confirmed by retry count ${JSON.stringify(retryDist)}; ${summary.retries.retryErrors} resends rejected (already known / already mined)`);
    }
    if (!summary.tallyMatchesConfirmed) {
        console.log(`  NOTE: on-chain tally total ${tallyTotal} != receipts confirmed ${confirmed} - check for votes from outside this load`);
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(2);
});
