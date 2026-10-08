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

function pass(msg) {
    console.log(`PASS: ${msg}`);
}

function fail(msg) {
    console.error(`FAIL: ${msg}`);
    process.exitCode = 1;
}

module.exports = { loadNetwork, registerFreshVoter, ensureVotingOpen, pass, fail };
