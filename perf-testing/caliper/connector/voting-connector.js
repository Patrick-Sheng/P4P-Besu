'use strict';

// Custom Caliper connector for the VotingSystem contract.
//
// Why not the stock `@hyperledger/caliper-ethereum` connector: that connector's
// getContext() binds exactly ONE `fromAddress` per worker process for the whole
// benchmark round (see its ethereum-connector.js), because its usual use case is
// one hot wallet per worker hammering repeatable calls (e.g. token transfers).
// castVote() is one-shot per voter (registeredVoters + a NotVoted/Processing/Voted
// state machine) - modelling real turnout means many thousands of DISTINCT voter
// accounts each submitting exactly one transaction, which the stock connector's
// single-fromAddress-per-worker model can't express. This connector instead takes
// a `privateKey` on every individual request and manages a wallet+nonce cache
// keyed by address, so each simulated voter can be its own account while
// transactions still flow through Caliper's normal sendRequests()/TxStatus
// pipeline (and therefore its normal throughput/latency reporting).
//
// Network config shape expected under the `voting` key (see ../networks/*.json):
// {
//   "caliper": { "blockchain": "connector/voting-connector.js" },
//   "voting": {
//     "rpcUrls": ["http://127.0.0.1:20700", ...],   // one or more validator RPC endpoints
//     "chainId": 1337,
//     "contracts": {
//       "VotingSystem": { "address": "0x...", "abiPath": "../../voting-contract/out/VotingSystem.sol/VotingSystem.json" }
//     }
//   }
// }

const fs = require('node:fs');
const path = require('node:path');
const { ethers } = require('ethers');
const { ConnectorBase, CaliperUtils, ConfigUtil, TxStatus } = require('@hyperledger/caliper-core');

const logger = CaliperUtils.getLogger('voting-connector');

// Caliper's built-in report (report-builder.js) only computes min/max/avg
// latency, not percentiles - but the test plan requires p50/p95/p99 vote
// confirmation latency. So every confirmed transaction's end-to-end latency
// (submit -> mined receipt) is appended here as NDJSON, one file per
// (worker, round), for perf-testing/monitoring/compute-percentiles.js to
// aggregate after the round finishes. Buffered in memory and flushed in
// batches rather than one fs call per tx, since Volume-test rounds can be
// millions of transactions.
const FLUSH_EVERY = 2000;

class VotingConnector extends ConnectorBase {
    /**
     * @param {number} workerIndex 0-based worker index, -1 for the manager process.
     * @param {string} bcType SUT type name.
     */
    constructor(workerIndex, bcType) {
        super(workerIndex, bcType);

        const configPath = CaliperUtils.resolvePath(ConfigUtil.get(ConfigUtil.keys.NetworkConfig));
        const votingConfig = require(configPath).voting;
        if (!votingConfig) {
            throw new Error(`Network config at ${configPath} is missing the top-level "voting" section`);
        }
        if (!Array.isArray(votingConfig.rpcUrls) || votingConfig.rpcUrls.length === 0) {
            throw new Error('Network config "voting.rpcUrls" must be a non-empty array');
        }

        this.votingConfig = votingConfig;

        // Round-robin RPC endpoint selection by worker index, so load spreads
        // across all validators instead of funnelling through node 1.
        const idx = workerIndex < 0 ? 0 : workerIndex;
        const url = votingConfig.rpcUrls[idx % votingConfig.rpcUrls.length];
        this.provider = new ethers.JsonRpcProvider(url, votingConfig.chainId ? {
            chainId: votingConfig.chainId,
            name: 'besu-ibft'
        } : undefined, { staticNetwork: true, batchMaxCount: 1 });

        // Sends rotate across every validator's RPC (not just the worker's own
        // node) so tx ingress/gossip load is spread like real clients would.
        this.sendProviders = votingConfig.rpcUrls.map((u) => new ethers.JsonRpcProvider(u, votingConfig.chainId ? {
            chainId: votingConfig.chainId,
            name: 'besu-ibft'
        } : undefined, { staticNetwork: true, batchMaxCount: 1 }));
        this.sendCursor = idx;

        // tx hash -> { resolve, reject, deadline } for the shared block watcher.
        // Per-tx receipt polling (one eth_getTransactionReceipt every 250ms per
        // in-flight tx) was ~12 extra RPCs per vote and capped the client at
        // ~65 TPS in the first n=4 sweep - i.e. it measured the load generator,
        // not IBFT. One watcher per worker instead fetches each new block's
        // receipts once and resolves every pending tx in it.
        this.pending = new Map();
        this.watcherRunning = false;
        this.lastScannedBlock = undefined;
        this.blockReceiptsSupported = true;

        this.contracts = {};
        for (const [name, cfg] of Object.entries(votingConfig.contracts || {})) {
            const abiPath = CaliperUtils.resolvePath(cfg.abiPath);
            const artifact = require(abiPath);
            const abi = Array.isArray(artifact) ? artifact : artifact.abi;
            this.contracts[name] = new ethers.Contract(cfg.address, abi, this.provider);
        }

        // address(lowercase) -> { wallet, nonce }
        this.wallets = new Map();

        this.latencyLogDir = CaliperUtils.resolvePath(votingConfig.latencyLogDir || 'reports/latency');
        fs.mkdirSync(this.latencyLogDir, { recursive: true });
        this.latencyBuffer = [];
        this.latencyStream = null;
        this.currentRoundIndex = -1;
    }

    _openLatencyStreamForRound(roundIndex) {
        if (this.latencyStream) {
            this.latencyStream.end();
        }
        this.currentRoundIndex = roundIndex;
        const idx = this.workerIndex < 0 ? 'manager' : this.workerIndex;
        const filePath = path.join(this.latencyLogDir, `round${roundIndex}-worker${idx}.ndjson`);
        this.latencyStream = fs.createWriteStream(filePath, { flags: 'w' });
    }

    _recordLatency(record) {
        if (!this.latencyStream) {
            this._openLatencyStreamForRound(this.currentRoundIndex);
        }
        this.latencyBuffer.push(JSON.stringify(record));
        if (this.latencyBuffer.length >= FLUSH_EVERY) {
            this._flushLatencyBuffer();
        }
    }

    _flushLatencyBuffer() {
        if (this.latencyBuffer.length === 0) {
            return;
        }
        this.latencyStream.write(this.latencyBuffer.join('\n') + '\n');
        this.latencyBuffer = [];
    }

    async init() {
        // Contract is deployed out-of-band (forge script), nothing to do here.
    }

    async installSmartContract() {
        // No-op: benchmarks are run with --caliper-flow-skip-install against a
        // contract deployed by perf-testing/network/deploy-contract.sh.
    }

    async prepareWorkerArguments(number) {
        const result = [];
        for (let i = 0; i < number; i++) {
            result[i] = {};
        }
        return result;
    }

    async getContext(roundIndex) {
        this._flushLatencyBuffer();
        this._openLatencyStreamForRound(roundIndex);
        return {};
    }

    async releaseContext() {
        this._flushLatencyBuffer();
        if (this.latencyStream) {
            this.latencyStream.end();
            this.latencyStream = null;
        }
        // wallets/provider otherwise live for the worker process lifetime
    }

    /**
     * @param {string} privateKey Hex-encoded private key of the sending account.
     * @return {Promise<{wallet: ethers.Wallet, reserveNonce: function(): number}>}
     */
    async _getWalletEntry(privateKey) {
        const key = privateKey.toLowerCase();
        let entry = this.wallets.get(key);
        if (!entry) {
            const wallet = new ethers.Wallet(privateKey, this.provider);
            const nonce = await this.provider.getTransactionCount(wallet.address);
            entry = { wallet, nonce };
            this.wallets.set(key, entry);
        }
        return entry;
    }

    async _waitForReceipt(hash, timeoutMs = 120000) {
        const promise = new Promise((resolve, reject) => {
            this.pending.set(hash, { resolve, reject, deadline: Date.now() + timeoutMs });
        });
        this._ensureWatcher();
        return promise;
    }

    async _receiptsForBlock(blockNumber) {
        const tag = '0x' + blockNumber.toString(16);
        if (this.blockReceiptsSupported) {
            try {
                return (await this.provider.send('eth_getBlockReceipts', [tag])) || [];
            } catch (err) {
                logger.warn(`eth_getBlockReceipts unavailable (${err.message}), falling back to per-tx receipts`);
                this.blockReceiptsSupported = false;
            }
        }
        const block = await this.provider.send('eth_getBlockByNumber', [tag, false]);
        const ours = ((block && block.transactions) || []).filter((h) => this.pending.has(h));
        return Promise.all(ours.map((h) => this.provider.send('eth_getTransactionReceipt', [h])));
    }

    _ensureWatcher() {
        if (this.watcherRunning) {
            return;
        }
        this.watcherRunning = true;
        const loop = async () => {
            while (this.pending.size > 0) {
                try {
                    const head = parseInt(await this.provider.send('eth_blockNumber', []), 16);
                    // re-scan one block back on (re)start: a tx can land in the
                    // head block before the watcher's first poll
                    if (this.lastScannedBlock === undefined || head - this.lastScannedBlock > 50) {
                        this.lastScannedBlock = head - 2;
                    }
                    for (let b = this.lastScannedBlock + 1; b <= head; b++) {
                        const receipts = await this._receiptsForBlock(b);
                        for (const receipt of receipts) {
                            const entry = receipt && this.pending.get(receipt.transactionHash);
                            if (entry) {
                                this.pending.delete(receipt.transactionHash);
                                entry.resolve(receipt);
                            }
                        }
                        this.lastScannedBlock = b;
                    }
                } catch (err) {
                    logger.warn(`block watcher poll failed: ${err.message}`);
                }
                const now = Date.now();
                for (const [hash, entry] of this.pending) {
                    if (now > entry.deadline) {
                        this.pending.delete(hash);
                        entry.reject(new Error(`no receipt for ${hash} before timeout`));
                    }
                }
                await new Promise((r) => setTimeout(r, 200));
            }
            this.watcherRunning = false;
        };
        loop();
    }

    /**
     * @typedef {Object} VotingRequest
     * @property {string} contract Name of the contract as declared in network config's voting.contracts
     * @property {string} verb Contract method name
     * @property {Array} args Method arguments in order
     * @property {string} privateKey Hex private key of the sending account (the simulated voter/admin)
     * @property {boolean} [readOnly] true for view calls
     * @property {number} [gasLimit] override gas limit (default 200000)
     * @property {number} [nonce] known nonce for the sender; skips the nonce lookup and wallet cache
     */
    async _sendSingleRequest(request) {
        const status = new TxStatus();
        const contract = this.contracts[request.contract];
        if (!contract) {
            status.SetStatusFail();
            logger.error(`Unknown contract "${request.contract}"`);
            return status;
        }

        try {
            if (request.readOnly) {
                // reads are timed too, so the Area 4 volume probes get p50/p95/p99
                // read latency rather than only Caliper's min/max/avg
                const startMs = Date.now();
                const result = await contract[request.verb](...(request.args || []));
                const endMs = Date.now();
                status.SetID('read');
                status.SetResult(result);
                status.SetVerification(true);
                status.SetStatusSuccess();
                this._recordLatency({
                    verb: request.verb,
                    readOnly: true,
                    submitTimeMs: startMs,
                    confirmTimeMs: endMs,
                    latencyMs: endMs - startMs,
                    success: true
                });
                return status;
            }

            const txFields = {
                to: contract.target,
                data: contract.interface.encodeFunctionData(request.verb, request.args || []),
                gasPrice: 0n,
                gasLimit: request.gasLimit ? BigInt(request.gasLimit) : 200000n,
                chainId: this.votingConfig.chainId,
                type: 0
            };
            let signedTx;
            if (request.nonce !== undefined) {
                // Caller knows the nonce (one-shot fresh voter accounts always
                // send at nonce 0): skip the eth_getTransactionCount round trip
                // and the wallet cache, and sign with a bare SigningKey, which
                // avoids Wallet's eager public-key/address derivation per voter.
                const tx = ethers.Transaction.from({ ...txFields, nonce: request.nonce });
                tx.signature = new ethers.SigningKey(request.privateKey).sign(tx.unsignedHash);
                signedTx = tx.serialized;
            } else {
                const entry = await this._getWalletEntry(request.privateKey);
                const nonce = entry.nonce;
                entry.nonce += 1; // reserved synchronously; never awaited before the increment
                signedTx = await entry.wallet.signTransaction({ ...txFields, nonce });
            }
            const hash = ethers.keccak256(signedTx);
            status.SetID(hash);

            const sendProvider = this.sendProviders[this.sendCursor++ % this.sendProviders.length];
            const submitTimeMs = Date.now();
            await sendProvider.send('eth_sendRawTransaction', [signedTx]);
            const receipt = await this._waitForReceipt(hash);
            const confirmTimeMs = Date.now();

            status.SetResult(receipt);
            status.SetVerification(true);
            const success = receipt.status === '0x1';
            if (success) {
                status.SetStatusSuccess();
            } else {
                status.SetStatusFail();
            }

            this._recordLatency({
                verb: request.verb,
                submitTimeMs,
                confirmTimeMs,
                latencyMs: confirmTimeMs - submitTimeMs,
                blockNumber: parseInt(receipt.blockNumber, 16),
                success
            });
        } catch (err) {
            status.SetStatusFail();
            logger.error(`Failed tx ${request.contract}.${request.verb}(${JSON.stringify(request.args)}): ${err.message}`);
        }

        return status;
    }
}

async function ConnectorFactory(workerIndex) {
    return new VotingConnector(workerIndex, 'voting');
}

module.exports.VotingConnector = VotingConnector;
module.exports.ConnectorFactory = ConnectorFactory;
