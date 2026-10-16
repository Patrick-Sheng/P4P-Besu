#!/usr/bin/env node
'use strict';

// One-time setup step run BEFORE a benchmark round: registers every voter in a
// pool (see generate-voters.js) via the admin account and opens voting, so the
// timed Caliper round (workloads/cast-vote.js) measures pure castVote()
// confirmation latency/throughput, not registration overhead.
//
// registerVoter() is onlyAdmin, so unlike vote-casting this is inherently a
// single-account, sequential-nonce transaction stream - there is no way to
// parallelize it across multiple sender accounts. Throughput here is bounded by
// how many registrations the network can confirm per second, same as any other
// tx stream; we pipeline a bounded window of in-flight txs (--concurrency) to
// avoid one-at-a-time request/wait latency dominating.
//
// Usage: node register-voters.js <networkConfigFile> <votersFile> [--concurrency=200]
//
// Safe to re-run: it tracks progress in <votersFile>.progress so an interrupted
// run (e.g. registering the ~2.9M voters for the Volume test) resumes instead of
// re-registering from zero.

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const [, , networkConfigArg, votersFileArg, ...rest] = process.argv;
const concurrencyArg = rest.find((a) => a.startsWith('--concurrency='));
const concurrency = concurrencyArg ? parseInt(concurrencyArg.split('=')[1], 10) : 200;

if (!networkConfigArg || !votersFileArg) {
    console.error('Usage: node register-voters.js <networkConfigFile> <votersFile> [--concurrency=200]');
    process.exit(1);
}

const networkConfigPath = path.resolve(process.cwd(), networkConfigArg);
const votersPath = path.resolve(process.cwd(), votersFileArg);
const progressPath = `${votersPath}.progress`;

async function main() {
    const networkConfig = require(networkConfigPath).voting;
    const voters = JSON.parse(fs.readFileSync(votersPath, 'utf8'));

    const provider = new ethers.JsonRpcProvider(networkConfig.rpcUrls[0], undefined, { staticNetwork: true });
    // ethers' default 4s receipt polling, not the network, was the registration
    // bottleneck (~40 regs/s with 2s blocks): each batch waited a full poll cycle
    provider.pollingInterval = 250;
    const admin = new ethers.Wallet(networkConfig.adminPrivateKey, provider);

    // abiPath in the network config is relative to the caliper workspace root
    // (perf-testing/caliper/), matching how the real Caliper connector resolves
    // it via CaliperUtils.resolvePath - not relative to the network config file.
    const workspaceRoot = path.resolve(__dirname, '..');
    const contractCfg = networkConfig.contracts.VotingSystem;
    const artifact = require(path.resolve(workspaceRoot, contractCfg.abiPath));
    const abi = Array.isArray(artifact) ? artifact : artifact.abi;
    const contract = new ethers.Contract(contractCfg.address, abi, admin);

    const votingOpen = await contract.votingOpen();
    if (!votingOpen) {
        console.log('Voting not open yet - calling openVoting()...');
        const tx = await contract.openVoting({ gasPrice: 0n, gasLimit: 100000n, type: 0 });
        await tx.wait();
        console.log('Voting opened.');
    }

    let startIndex = 0;
    if (fs.existsSync(progressPath)) {
        startIndex = parseInt(fs.readFileSync(progressPath, 'utf8').trim(), 10) || 0;
        console.log(`Resuming from voter index ${startIndex} (found ${progressPath})`);
    }

    if (startIndex >= voters.length) {
        console.log('All voters already registered according to progress file.');
        return;
    }

    let nonce = await provider.getTransactionCount(admin.address);
    console.log(`Registering ${voters.length - startIndex} voters (of ${voters.length} total), admin nonce starts at ${nonce}`);

    const total = voters.length;
    for (let batchStart = startIndex; batchStart < total; batchStart += concurrency) {
        const batchEnd = Math.min(batchStart + concurrency, total);
        const batch = voters.slice(batchStart, batchEnd);

        const responses = await Promise.all(batch.map((voter, offset) =>
            contract.registerVoter(voter.address, {
                gasPrice: 0n,
                gasLimit: 100000n,
                nonce: nonce + offset,
                type: 0
            }).catch((err) => ({ __error: err, voter }))
        ));
        nonce += batch.length;

        const failed = responses.filter((r) => r && r.__error);
        if (failed.length > 0) {
            console.error(`Batch [${batchStart}, ${batchEnd}) had ${failed.length} send failures. First error:`, failed[0].__error.message);
            process.exit(1);
        }

        const receipts = await Promise.all(responses.map((r) => r.wait()));
        const reverted = receipts.filter((r) => r.status !== 1);
        if (reverted.length > 0) {
            console.error(`Batch [${batchStart}, ${batchEnd}) had ${reverted.length} reverted registrations (already registered? wrong admin key?)`);
            process.exit(1);
        }

        fs.writeFileSync(progressPath, String(batchEnd));
        if (batchEnd % (concurrency * 10) === 0 || batchEnd === total) {
            console.log(`  registered ${batchEnd}/${total}`);
        }
    }

    console.log('All voters registered.');
    fs.unlinkSync(progressPath);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
