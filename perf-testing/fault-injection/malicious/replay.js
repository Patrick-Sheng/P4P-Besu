#!/usr/bin/env node
'use strict';

// Area 3 - malicious behaviour: replay attack.
// Casts one legitimate vote, keeps the exact raw signed transaction, then
// rebroadcasts that SAME raw transaction again later and confirms it has no
// further effect (either rejected outright as a duplicate/low nonce, or a
// no-op if the node returns the already-known hash) - specifically, that the
// candidate's tally does not increment a second time.
//
// Usage: node replay.js <networkConfigFile>

const { loadNetwork, registerFreshVoter, ensureVotingOpen, pass, fail } = require('./lib');

async function main() {
    const networkConfigPath = process.argv[2];
    if (!networkConfigPath) {
        console.error('Usage: node replay.js <networkConfigFile>');
        process.exit(1);
    }

    const { config, provider, admin, contract } = loadNetwork(networkConfigPath);
    await ensureVotingOpen(admin, contract);

    const voter = await registerFreshVoter(provider, admin, contract);
    console.log(`Registered voter ${voter.address}`);

    const candidateId = 0;
    const tallyBeforeOriginal = await contract.getTally(candidateId);

    const iface = contract.interface;
    const nonce = await provider.getTransactionCount(voter.address);
    const txRequest = {
        to: await contract.getAddress(),
        data: iface.encodeFunctionData('castVote', [candidateId]),
        nonce,
        gasPrice: 0n,
        gasLimit: 200000n,
        chainId: config.chainId,
        type: 0
    };
    const signedRawTx = await voter.signTransaction(txRequest);

    console.log('Broadcasting original vote...');
    const originalResponse = await provider.broadcastTransaction(signedRawTx);
    const originalReceipt = await originalResponse.wait();
    if (originalReceipt.status !== 1) {
        fail(`original vote reverted unexpectedly: ${originalResponse.hash}`);
        return;
    }
    const tallyAfterOriginal = await contract.getTally(candidateId);
    console.log(`Original vote confirmed in block ${originalReceipt.blockNumber} (tally ${tallyBeforeOriginal} -> ${tallyAfterOriginal})`);

    console.log('Replaying the exact same raw signed transaction...');
    let replayRejected = false;
    let replaySameHash = false;
    try {
        const replayResponse = await provider.broadcastTransaction(signedRawTx);
        replaySameHash = replayResponse.hash === originalResponse.hash;
        try {
            await replayResponse.wait(1, 15000);
        } catch (waitErr) {
            // never confirmed a second time - fine, it was never a distinct new tx anyway
        }
    } catch (err) {
        replayRejected = true;
        console.log(`  replay rejected at submission: ${err.message.split('\n')[0]}`);
    }

    const tallyAfterReplay = await contract.getTally(candidateId);
    const replayHadNoEffect = tallyAfterReplay === tallyAfterOriginal;

    console.log(`Tally after replay attempt: ${tallyAfterReplay} (unchanged expected: ${tallyAfterOriginal})`);
    console.log(`Replay rejected outright: ${replayRejected}; replay returned identical tx hash: ${replaySameHash}`);

    if (replayHadNoEffect) {
        pass('replayed transaction had no further effect on chain state - no double count.');
    } else {
        fail(`replay caused the tally to change again (${tallyAfterOriginal} -> ${tallyAfterReplay}) - replay was NOT correctly rejected.`);
    }
}

main().catch((err) => {
    fail(err.message);
    console.error(err);
});
