#!/usr/bin/env node
// Generates an N-validator IBFT2 Besu network (genesis + keys + docker-compose.yml)
// under perf-testing/network/generated/n<N>/. Used by the scalability (Area 1) and
// crash/malicious fault-tolerance (Areas 2-3) test matrices, which all need to spin
// up independent networks at 4/7/10/13 validators.
//
// Usage: node generate-network.mjs <nodeCount> [--light] [--block-period=2]
//   --light   caps each validator's JVM heap at 512m so the full matrix can be
//             smoke-tested on a resource-constrained dev machine. Omit for real
//             benchmark runs on adequately sized hardware.

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const nodeCount = parseInt(args[0], 10);
const light = args.includes('--light');
const blockPeriodArg = args.find((a) => a.startsWith('--block-period='));
const blockPeriodSeconds = blockPeriodArg ? parseInt(blockPeriodArg.split('=')[1], 10) : 2;

if (!Number.isInteger(nodeCount) || nodeCount < 4) {
    console.error('Usage: node generate-network.mjs <nodeCount:int>=4> [--light] [--block-period=2]');
    process.exit(1);
}

const outDir = path.join(__dirname, 'generated', `n${nodeCount}`);
const configDir = path.join(outDir, 'config');
const dataDir = path.join(outDir, 'data');

if (existsSync(outDir)) {
    console.log(`Removing previous generated network at ${outDir}`);
    rmSync(outDir, { recursive: true, force: true });
}
mkdirSync(outDir, { recursive: true });
mkdirSync(dataDir, { recursive: true });
// configDir is intentionally NOT pre-created: `besu operator generate-blockchain-config`
// refuses to write into an already-existing --to directory.

// 1. IBFT config file consumed by `besu operator generate-blockchain-config`.
// Mirrors network/ibftConfigFile.json at the repo root (same chainId/block period)
// so results are comparable across node counts and with the existing dev network.
const ibftConfigFile = {
    genesis: {
        config: {
            chainId: 1337,
            berlinBlock: 0,
            ibft2: {
                blockperiodseconds: blockPeriodSeconds,
                epochlength: 30000,
                requesttimeoutseconds: 4
            }
        },
        nonce: '0x0',
        timestamp: '0x58ee40ba',
        gasLimit: '0x1fffffffffffff',
        difficulty: '0x1',
        mixHash: '0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365',
        coinbase: '0x0000000000000000000000000000000000000000',
        alloc: {}
    },
    blockchain: { nodes: { generate: true, count: nodeCount } }
};
const ibftConfigPath = path.join(outDir, 'ibftConfigFile.json');
writeFileSync(ibftConfigPath, JSON.stringify(ibftConfigFile, null, 2));

// 2. Generate genesis.json + one key pair per validator.
console.log(`Generating ${nodeCount} validator keys + genesis...`);
execFileSync('besu', [
    'operator', 'generate-blockchain-config',
    `--config-file=${ibftConfigPath}`,
    `--to=${configDir}`,
    '--private-key-file-name=key'
], { stdio: 'inherit' });

const keysRoot = path.join(configDir, 'keys');
const validatorAddresses = readdirSync(keysRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort(); // deterministic ordering -> validator1..N

if (validatorAddresses.length !== nodeCount) {
    throw new Error(`Expected ${nodeCount} validator keys, found ${validatorAddresses.length}`);
}

// besu operator generate-blockchain-config already writes a key.pub file
// (the raw 128-hex-char public key) alongside each private key - this is
// exactly the identifier half of an enode URL, so no extra derivation step
// (e.g. `besu public-key export`) is needed.
const pubKeys = validatorAddresses.map((addr) =>
    readFileSync(path.join(keysRoot, addr, 'key.pub'), 'utf8').trim().replace(/^0x/, '')
);

// 3. Static IP plan. Subnet keyed by node count so differently-sized networks
// generated side by side never collide if more than one is ever brought up.
const subnet = `172.20.${nodeCount}.0/24`;
const ipFor = (i) => `172.20.${nodeCount}.${10 + i}`; // i is 0-based
const bootnodeEnode = `enode://${pubKeys[0]}@${ipFor(0)}:30303`;

// Host port plan: RPC only needs to be reachable from the host (Caliper runs
// there); P2P stays inside the docker network. Offset by node count so the
// n4/n7/n10/n13 networks can in principle coexist without port clashes.
const hostRpcPort = (i) => 20000 + nodeCount * 100 + i; // i is 0-based

const javaOpts = light ? '-Xmx512m' : '-Xmx2g';

// 4. docker-compose.yml
const services = validatorAddresses.map((addr, i) => {
    const name = `validator${i + 1}`;
    const bootnodesFlag = i === 0 ? '' : `\n      - --bootnodes=${bootnodeEnode}`;
    return `  ${name}:
    image: hyperledger/besu:24.12.0
    container_name: besu-n${nodeCount}-${name}
    restart: "no"
    environment:
      - JAVA_OPTS=${javaOpts}
    volumes:
      - ./config/genesis.json:/config/genesis.json:ro
      - ./config/keys/${addr}/key:/config/key:ro
      - ./data/${name}:/data
    command:
      - --data-path=/data
      - --genesis-file=/config/genesis.json
      - --node-private-key-file=/config/key
      - --data-storage-format=BONSAI
      - --rpc-http-enabled
      - --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL
      - --rpc-http-host=0.0.0.0
      - --rpc-http-cors-origins=*
      - --host-allowlist=*
      - --p2p-host=${ipFor(i)}
      - --p2p-port=30303${bootnodesFlag}
      - --profile=ENTERPRISE
      - --logging=INFO
    ports:
      - "${hostRpcPort(i)}:8545"
    networks:
      besu-n${nodeCount}:
        ipv4_address: ${ipFor(i)}
`;
}).join('\n');

const compose = `# Generated by perf-testing/network/generate-network.mjs -- do not hand-edit.
# Regenerate with: node perf-testing/network/generate-network.mjs ${nodeCount}${light ? ' --light' : ''}
services:
${services}
networks:
  besu-n${nodeCount}:
    driver: bridge
    ipam:
      config:
        - subnet: ${subnet}
`;
writeFileSync(path.join(outDir, 'docker-compose.yml'), compose);

// 5. Metadata consumed by deploy-contract.sh / the Caliper network-config generator.
const meta = {
    nodeCount,
    blockPeriodSeconds,
    subnet,
    validators: validatorAddresses.map((addr, i) => ({
        address: addr,
        keyPath: path.join(configDir, 'keys', addr, 'key'),
        ip: ipFor(i),
        rpcUrl: `http://127.0.0.1:${hostRpcPort(i)}`,
        containerName: `besu-n${nodeCount}-validator${i + 1}`,
        isBootnode: i === 0
    })),
    adminKeyPath: path.join(configDir, 'keys', validatorAddresses[0], 'key'),
    // f = max tolerable simultaneous faulty/crashed validators under n >= 3f+1
    maxTolerableFaults: Math.floor((nodeCount - 1) / 3)
};
writeFileSync(path.join(outDir, 'network-meta.json'), JSON.stringify(meta, null, 2));

console.log(`\nGenerated ${nodeCount}-validator network at ${outDir}`);
console.log(`  f (max tolerable simultaneous faults) = ${meta.maxTolerableFaults}`);
console.log(`  RPC ports: ${meta.validators.map((v) => v.rpcUrl).join(', ')}`);
console.log(`\nNext: docker compose -f ${path.join(outDir, 'docker-compose.yml')} up -d`);
