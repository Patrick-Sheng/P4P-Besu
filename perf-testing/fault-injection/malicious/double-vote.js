#!/usr/bin/env node
'use strict';

// Area 3 - malicious behaviour: double-voting.
// Registers one fresh voter, votes once (should succeed), then resubmits a
// vote from the SAME account (should be rejected at the application layer by
// VotingSystem's three-state model: NotVoted -> Processing -> Voted, since
// castVote() requires voterState[msg.sender] == NotVoted).
//
// Usage: node double-vote.js <networkConfigFile>

const { loadNetwork, registerFreshVoter, ensureVotingOpen, assertAllNodesAgree, pass, fail } = require('./lib');

async function main() {
    const networkConfigPath = process.argv[2];
    if (!networkConfigPath) {
        console.error('Usage: node double-vote.js <networkConfigFile>');
        process.exit(1);
    }

    const { config, provider, admin, contract } = loadNetwork(networkConfigPath);
    await ensureVotingOpen(admin, contract);

    const voter = await registerFreshVoter(provider, admin, contract);
    console.log(`Registered voter ${voter.address}`);

    const candidateId = 0;
    const tallyBefore = await contract.getTally(candidateId);

    const voterContract = contract.connect(voter);
    const tx1 = await voterContract.castVote(candidateId, { gasPrice: 0n, gasLimit: 200000n, nonce: 0, type: 0 });
    const receipt1 = await tx1.wait();
    if (receipt1.status !== 1) {
        fail(`first (legitimate) vote reverted unexpectedly: ${tx1.hash}`);
        return;
    }
    pass(`first vote confirmed (tx ${tx1.hash})`);

    let secondVoteRejected = false;
    try {
        const tx2 = await voterContract.castVote(candidateId, { gasPrice: 0n, gasLimit: 200000n, nonce: 1, type: 0 });
        const receipt2 = await tx2.wait();
        secondVoteRejected = receipt2.status !== 1;
    } catch (err) {
        // ethers v6 throws on a reverted call when it can preflight-detect it,
        // or the node may reject at submission time - either counts as rejected.
        // Logged so the evidence shows WHY (a revert/nonce rejection, not e.g. a
        // network error that would make this check vacuous).
        secondVoteRejected = true;
        console.log(`  second vote rejected: ${err.code || ''} ${(err.shortMessage || err.message).split('\n')[0]}${err.receipt ? ` (mined in block ${err.receipt.blockNumber}, status ${err.receipt.status})` : ''}`);
    }

    const tallyAfter = await contract.getTally(candidateId);
    const voterState = await contract.getVoterState(voter.address);

    if (secondVoteRejected && tallyAfter === tallyBefore + 1n && voterState === 2n /* Voted */) {
        pass('double-vote was rejected at the application layer; tally incremented exactly once; voter state remains Voted.');
    } else {
        fail(`double-vote was NOT correctly rejected. secondVoteRejected=${secondVoteRejected}, tallyBefore=${tallyBefore}, tallyAfter=${tallyAfter}, voterState=${voterState}`);
    }

    await assertAllNodesAgree(config, contract, [candidateId]);
}

main().catch((err) => {
    fail(err.message);
    console.error(err);
});
