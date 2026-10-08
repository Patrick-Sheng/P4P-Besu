#!/usr/bin/env node
'use strict';

// Area 3 - malicious behaviour: equivocation.
// A single voter signs TWO conflicting votes (different candidates) using the
// SAME nonce, and broadcasts each to a DIFFERENT validator's RPC endpoint at
// roughly the same time - modelling a byzantine client sending conflicting
// messages to different peers in the same round. Ethereum-style strict
// per-account nonce ordering means at most one of the two can ever be
// included in a block; this asserts that IBFT's total-ordering consensus
// still resolves to exactly one outcome network-wide (no fork where different
// validators disagree on which vote counted), not that both got dropped.
//
// Usage: node equivocation.js <networkConfigFile>

const { ethers } = require('ethers');
const { loadNetwork, registerFreshVoter, ensureVotingOpen, pass, fail } = require('./lib');

async function main() {
    const networkConfigPath = process.argv[2];
    if (!networkConfigPath) {
        console.error('Usage: node equivocation.js <networkConfigFile>');
        process.exit(1);
    }

    const { config, provider, admin, contract } = loadNetwork(networkConfigPath);
    await ensureVotingOpen(admin, contract);

    if (config.rpcUrls.length < 2) {
        console.warn('Only one RPC endpoint configured; broadcasting both conflicting votes to the same node ' +
            '(still valid - the network-wide consensus guarantee is what is under test) instead of two distinct peers.');
    }
    const providerA = provider;
    const providerB = new ethers.JsonRpcProvider(config.rpcUrls[config.rpcUrls.length > 1 ? 1 : 0], undefined, { staticNetwork: true });

    const voter = await registerFreshVoter(provider, admin, contract);
    console.log(`Registered voter ${voter.address}`);

    const candidateA = 0;
    const candidateB = 1;
    const tallyBeforeA = await contract.getTally(candidateA);
    const tallyBeforeB = await contract.getTally(candidateB);

    const iface = contract.interface;
    const nonce = await provider.getTransactionCount(voter.address);

    const txRequestA = {
        to: await contract.getAddress(),
        data: iface.encodeFunctionData('castVote', [candidateA]),
        nonce,
        gasPrice: 0n,
        gasLimit: 200000n,
        chainId: config.chainId,
        type: 0
    };
    const txRequestB = { ...txRequestA, data: iface.encodeFunctionData('castVote', [candidateB]) };

    const signedA = await voter.signTransaction(txRequestA);
    const signedB = await voter.signTransaction(txRequestB);

    console.log('Broadcasting conflicting vote A (candidate 0) and vote B (candidate 1) to different endpoints simultaneously...');
    const [resultA, resultB] = await Promise.allSettled([
        providerA.broadcastTransaction(signedA),
        providerB.broadcastTransaction(signedB)
    ]);

    async function waitForReceipt(txResult, label) {
        if (txResult.status !== 'fulfilled') {
            console.log(`  ${label}: rejected at broadcast time (${txResult.reason.message.split('\n')[0]})`);
            return null;
        }
        try {
            const receipt = await txResult.value.wait(1, 20000);
            console.log(`  ${label}: included in block ${receipt.blockNumber}, status=${receipt.status}`);
            return receipt;
        } catch (err) {
            console.log(`  ${label}: never confirmed (${err.message.split('\n')[0]}) - correctly dropped as a duplicate nonce`);
            return null;
        }
    }

    const [receiptA, receiptB] = await Promise.all([
        waitForReceipt(resultA, 'vote A (candidate 0)'),
        waitForReceipt(resultB, 'vote B (candidate 1)')
    ]);

    const includedCount = [receiptA, receiptB].filter((r) => r && r.status === 1).length;

    const tallyAfterA = await contract.getTally(candidateA);
    const tallyAfterB = await contract.getTally(candidateB);
    const deltaA = tallyAfterA - tallyBeforeA;
    const deltaB = tallyAfterB - tallyBeforeB;
    const totalDelta = deltaA + deltaB;

    console.log(`Tally deltas: candidate 0 +${deltaA}, candidate 1 +${deltaB}`);

    if (includedCount === 1 && totalDelta === 1n) {
        pass('exactly one of the two conflicting votes was included network-wide, and exactly one candidate\'s tally incremented - no fork, no double count.');
    } else {
        fail(`expected exactly one conflicting vote to land; got includedCount=${includedCount}, totalTallyDelta=${totalDelta}`);
    }
}

main().catch((err) => {
    fail(err.message);
    console.error(err);
});
