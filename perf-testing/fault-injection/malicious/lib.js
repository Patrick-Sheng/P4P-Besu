'use strict';

// Shared helpers for the Area 3 application-layer malicious-node scripts.
// These are correctness/security assertions, not throughput measurements, so
// unlike the Caliper workloads they run as small standalone ethers scripts
// against a network config produced by deploy-and-configure.js.

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

function loadNetwork(networkConfigPath) {
    const resolved = path.resolve(process.cwd(), networkConfigPath);
    const config = require(resolved).voting;
    const workspaceRoot = path.resolve(path.dirname(resolved), '..'); // networks/ -> caliper/

    const provider = new ethers.JsonRpcProvider(config.rpcUrls[0], undefined, { staticNetwork: true });
    const admin = new ethers.Wallet(config.adminPrivateKey, provider);

    const contractCfg = config.contracts.VotingSystem;
    const artifact = JSON.parse(fs.readFileSync(path.resolve(workspaceRoot, contractCfg.abiPath), 'utf8'));
    const contract = new ethers.Contract(contractCfg.address, artifact.abi, provider);

    return { config, provider, admin, contract };
}

/** Registers a fresh random voter via the admin account and returns its wallet. */
async function registerFreshVoter(provider, admin, contract) {
    const voter = ethers.Wallet.createRandom().connect(provider);
    const adminContract = contract.connect(admin);
    const nonce = await provider.getTransactionCount(admin.address);
    const tx = await adminContract.registerVoter(voter.address, { gasPrice: 0n, gasLimit: 100000n, nonce, type: 0 });
    await tx.wait();
    return voter;
}

async function ensureVotingOpen(admin, contract) {
    const open = await contract.votingOpen();
    if (!open) {
        const tx = await contract.connect(admin).openVoting({ gasPrice: 0n, gasLimit: 100000n, type: 0 });
        await tx.wait();
    }
}

/**
 * Reads the given candidates' tallies from EVERY validator at one common block
 * height and checks they all agree - the network-wide "no fork / no divergent
 * count" half of each attack assertion (reading only validator1 would miss a
 * node that counted differently). Waits a few blocks first so every node has
 * imported the attack's transactions. Returns true if all nodes agree.
 */
async function assertAllNodesAgree(config, contract, candidateIds) {
    const providers = config.rpcUrls.map((u) => new ethers.JsonRpcProvider(u, undefined, { staticNetwork: true }));
    const start = await providers[0].getBlockNumber();
    while ((await providers[0].getBlockNumber()) < start + 3) {
        await new Promise((r) => setTimeout(r, 1000));
    }
    const heights = await Promise.all(providers.map((p) => p.getBlockNumber()));
    const blockTag = Math.min(...heights);
    const rows = await Promise.all(providers.map(async (p, i) => {
        const c = contract.connect(p);
        const tallies = await Promise.all(candidateIds.map((id) => c.getTally(id, { blockTag })));
        const hash = (await p.getBlock(blockTag)).hash;
        return { node: `validator${i + 1}`, tallies: tallies.map(String).join('/'), hash };
    }));
    const agree = rows.every((r) => r.tallies === rows[0].tallies && r.hash === rows[0].hash);
    console.log(`Cross-node check at block ${blockTag} (tallies for candidates ${candidateIds.join('/')}):`);
    for (const r of rows) {
        console.log(`  ${r.node}: ${r.tallies}  ${r.hash}`);
    }
    if (agree) {
        pass(`all ${rows.length} validators report identical tallies and block hash at #${blockTag}`);
    } else {
        fail(`validators DISAGREE at block #${blockTag} - divergent state`);
    }
    return agree;
}

/**
 * Reads a candidate's tally pinned to the current head, so a later read can be
 * netted against legitimate votes cast in between (see attackerDelta).
 */
async function tallyAt(provider, contract, candidateId) {
    const block = await provider.getBlockNumber();
    return { block, tally: await contract.getTally(candidateId, { blockTag: block }) };
}

/**
 * Tally change between two tallyAt() reads that is NOT explained by other
 * voters: (after - before) minus VoteCast events for this candidate from any
 * address other than `attacker` in blocks (before.block, after.block]. Round 2
 * replays the attacks alongside soak traffic, where thousands of legitimate
 * votes land during one attack; with no concurrent traffic this is exactly the
 * raw delta round 1 checked.
 */
async function attackerDelta(contract, before, after, candidateId, attacker) {
    let others = 0n;
    if (after.block > before.block) {
        const logs = await contract.queryFilter(contract.filters.VoteCast(), before.block + 1, after.block);
        for (const l of logs) {
            if (Number(l.args.candidateId) === Number(candidateId) && l.args.voter.toLowerCase() !== attacker.toLowerCase()) {
                others += 1n;
            }
        }
    }
    const raw = after.tally - before.tally;
    if (others > 0n) {
        console.log(`  candidate ${candidateId}: raw tally delta ${raw}, of which ${others} from concurrent legitimate voters -> attacker delta ${raw - others}`);
    }
    return raw - others;
}

function pass(msg) {
    console.log(`PASS: ${msg}`);
}

function fail(msg) {
    console.error(`FAIL: ${msg}`);
    process.exitCode = 1;
}

module.exports = { loadNetwork, registerFreshVoter, ensureVotingOpen, assertAllNodesAgree, tallyAt, attackerDelta, pass, fail };
