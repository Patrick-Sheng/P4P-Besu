#!/usr/bin/env node
'use strict';

// Deploys VotingSystem to a generated N-validator network and writes the
// matching Caliper network config (perf-testing/caliper/networks/besu-nN.json).
//
// Usage: node deploy-and-configure.js <nodeCount> [--num-candidates=3]
//
// Deploys directly via ethers using the already-compiled Foundry artifact
// (voting-contract/out/VotingSystem.sol/VotingSystem.json) rather than shelling
// out to `forge script`, so this has no dependency on forge's broadcast-log
// format and works the same whether the network was started natively or via
// the perf-testing Docker Compose generator.

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const ARTIFACT_PATH = path.join(REPO_ROOT, 'voting-contract', 'out', 'VotingSystem.sol', 'VotingSystem.json');

const [, , nodeCountArg, ...rest] = process.argv;
const nodeCount = parseInt(nodeCountArg, 10);
const numCandidatesArg = rest.find((a) => a.startsWith('--num-candidates='));
const numCandidates = numCandidatesArg ? parseInt(numCandidatesArg.split('=')[1], 10) : 3;

if (!Number.isInteger(nodeCount)) {
    console.error('Usage: node deploy-and-configure.js <nodeCount> [--num-candidates=3]');
    process.exit(1);
}

const metaPath = path.join(REPO_ROOT, 'perf-testing', 'network', 'generated', `n${nodeCount}`, 'network-meta.json');

async function waitForLiveNetwork(rpcUrls, { timeoutMs = 120000, pollMs = 2000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    console.log(`Waiting for ${rpcUrls.length} validator(s) to come up and start producing blocks...`);
    while (Date.now() < deadline) {
        try {
            const blockNumbers = await Promise.all(rpcUrls.map(async (url) => {
                const provider = new ethers.JsonRpcProvider(url, undefined, { staticNetwork: true });
                return provider.getBlockNumber();
            }));
            const allReachable = blockNumbers.every((n) => typeof n === 'number');
            if (allReachable) {
                // confirm the chain is actually advancing (quorum is live), not just RPC up on block 0
                await new Promise((r) => setTimeout(r, 2500));
                const blockNumbers2 = await Promise.all(rpcUrls.map(async (url) => {
                    const provider = new ethers.JsonRpcProvider(url, undefined, { staticNetwork: true });
                    return provider.getBlockNumber();
                }));
                const advancing = blockNumbers2.some((n, i) => n > blockNumbers[i]) || blockNumbers2.every((n) => n > 0);
                if (advancing) {
                    console.log(`Network live. Block heights: ${blockNumbers2.join(', ')}`);
                    return;
                }
            }
        } catch (err) {
            // not up yet
        }
        process.stdout.write('.');
        await new Promise((r) => setTimeout(r, pollMs));
    }
    throw new Error(`Timed out waiting for network at ${rpcUrls.join(', ')} to start producing blocks`);
}

async function main() {
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
    const rpcUrls = meta.validators.map((v) => v.rpcUrl);

    await waitForLiveNetwork(rpcUrls);

    const adminKeyPath = path.isAbsolute(meta.adminKeyPath) ? meta.adminKeyPath : path.join(REPO_ROOT, meta.adminKeyPath);
    const adminKey = fs.readFileSync(adminKeyPath, 'utf8').trim();
    const provider = new ethers.JsonRpcProvider(rpcUrls[0], undefined, { staticNetwork: true });
    const deployer = new ethers.Wallet(adminKey, provider);

    const artifact = JSON.parse(fs.readFileSync(ARTIFACT_PATH, 'utf8'));
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, deployer);

    console.log(`Deploying VotingSystem(numCandidates=${numCandidates}) via ${deployer.address} on ${rpcUrls[0]}...`);
    const contract = await factory.deploy(numCandidates, { gasPrice: 0n, gasLimit: 3000000n, type: 0 });
    await contract.waitForDeployment();
    const address = await contract.getAddress();
    console.log(`Deployed VotingSystem at ${address}`);

    const abiPathAbs = ARTIFACT_PATH;
    const networksDir = path.join(__dirname, 'networks');
    fs.mkdirSync(networksDir, { recursive: true });
    const networkConfigPath = path.join(networksDir, `besu-n${nodeCount}.json`);

    const networkConfig = {
        caliper: {
            blockchain: 'connector/voting-connector.js'
        },
        voting: {
            rpcUrls,
            chainId: 1337,
            contracts: {
                VotingSystem: {
                    address,
                    // relative to this caliper/ workspace directory
                    abiPath: path.relative(__dirname, abiPathAbs)
                }
            },
            adminPrivateKey: adminKey,
            numCandidates
        }
    };
    fs.writeFileSync(networkConfigPath, JSON.stringify(networkConfig, null, 2));
    console.log(`Wrote Caliper network config: ${networkConfigPath}`);
    console.log('\nNext: generate + register a voter pool, e.g.');
    console.log(`  node seed/generate-voters.js 50000 seed/generated/n${nodeCount}-voters.json`);
    console.log(`  node seed/register-voters.js networks/besu-n${nodeCount}.json seed/generated/n${nodeCount}-voters.json`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
