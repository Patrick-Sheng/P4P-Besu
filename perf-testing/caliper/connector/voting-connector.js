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
//     },
//     // optional, used by the additional T2 test (scripts/additional-fault.sh); absent = old behaviour
//     "receiptTimeoutMs": 120000,              // how long a sent tx is watched for a receipt
//     "txLogDir": "reports/txlog",             // one NDJSON line per castVote send: hash, outcome, retries
//     "retry": { "afterBlocks": 15, "maxRetries": 3 }  // resend the identical signed tx if no receipt
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

// Receipt watcher under stress (post-outage blocks of ~2,000 txs): a failed
// eth_getBlockReceipts is retried for the same block with backoff, and only
// after BLOCK_RECEIPTS_ATTEMPTS failures is THAT block read per tx - never
// more than PER_TX_CONCURRENCY receipt calls in flight. Besu decodes a whole
// block's receipts for each eth_getTransactionReceipt, so an unbounded per-tx
// fallback (the old behaviour) wedged validator1's RPC.
const BLOCK_RECEIPTS_ATTEMPTS = 3;
const PER_TX_CONCURRENCY = 8;
const WATCH_INTERVAL_MS = 200;
const WATCH_BACKOFF_MAX_MS = 10000;

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
        this.lastHead = undefined;
        this.blockReceiptsSupported = true;
        this.receiptTimeoutMs = Number(votingConfig.receiptTimeoutMs) || 120000;

        // Client-side retry (T2 variant V3): a vote with no receipt after
        // `afterBlocks` NEW blocks is resent as the identical signed tx (same
        // hash, same nonce - it can only ever be included once). Counted in
        // blocks, not seconds, so the timer does not run while the chain is
        // halted: retries start only once blocks are being produced again.
        const retry = votingConfig.retry;
        this.retry = retry && Number(retry.maxRetries) > 0
            ? { afterBlocks: Number(retry.afterBlocks) || 15, maxRetries: Number(retry.maxRetries) }
            : null;
        if (this.retry) {
            logger.info(`client retry enabled: resend after ${this.retry.afterBlocks} blocks without receipt, up to ${this.retry.maxRetries} times`);
        }

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

        // Per-send log (opt-in): unlike the latency NDJSON, which only holds
        // txs that got a receipt, this records every castVote send including
        // send errors and receipt timeouts, so lost votes can be counted.
        this.txLogDir = votingConfig.txLogDir ? CaliperUtils.resolvePath(votingConfig.txLogDir) : null;
        if (this.txLogDir) {
            fs.mkdirSync(this.txLogDir, { recursive: true });
        }
        this.txLogBuffer = [];
        this.txLogStream = null;
    }

    _openLatencyStreamForRound(roundIndex) {
        if (this.latencyStream) {
            this.latencyStream.end();
        }
        this.currentRoundIndex = roundIndex;
        const idx = this.workerIndex < 0 ? 'manager' : this.workerIndex;
        const filePath = path.join(this.latencyLogDir, `round${roundIndex}-worker${idx}.ndjson`);
        this.latencyStream = fs.createWriteStream(filePath, { flags: 'w' });
        if (this.txLogDir) {
            this._openTxLogStream('w');
        }
    }

    _openTxLogStream(flags) {
        if (this.txLogStream) {
            this.txLogStream.end();
        }
        const idx = this.workerIndex < 0 ? 'manager' : this.workerIndex;
        const filePath = path.join(this.txLogDir, `round${this.currentRoundIndex}-worker${idx}.ndjson`);
        this.txLogStream = fs.createWriteStream(filePath, { flags });
    }

    _recordTx(record) {
        if (!this.txLogDir) {
            return;
        }
        if (!this.txLogStream) {
            // late record after releaseContext(): append, never truncate
            this._openTxLogStream('a');
        }
        this.txLogBuffer.push(JSON.stringify(record));
        if (this.txLogBuffer.length >= FLUSH_EVERY) {
            this.txLogStream.write(this.txLogBuffer.join('\n') + '\n');
            this.txLogBuffer = [];
        }
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
        if (this.txLogStream && this.txLogBuffer.length > 0) {
            this.txLogStream.write(this.txLogBuffer.join('\n') + '\n');
            this.txLogBuffer = [];
        }
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
        if (this.txLogStream) {
            this.txLogStream.end();
            this.txLogStream = null;
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

    /**
     * @param {string} hash tx hash
     * @param {string} [signedTx] raw signed tx, kept only when client retry is enabled
     * @param {Object} [txRecord] tx-log record; its `retries`/`retryErrors` are updated in place
     */
    async _waitForReceipt(hash, signedTx, txRecord) {
        const promise = new Promise((resolve, reject) => {
            this.pending.set(hash, {
                resolve,
                reject,
                deadline: Date.now() + this.receiptTimeoutMs,
                signedTx: this.retry ? signedTx : undefined,
                // only trust lastHead while the watcher is live; a stale head
                // would make the first retry fire early
                lastSendBlock: this.watcherRunning ? this.lastHead : undefined,
                txRecord
            });
        });
        this._ensureWatcher();
        return promise;
    }

    /** Resends still-unconfirmed txs whose retry interval (in blocks) has elapsed. */
    async _retryPass(head) {
        const due = [];
        for (const [hash, entry] of this.pending) {
            if (!entry.signedTx) {
                continue;
            }
            if (entry.lastSendBlock === undefined) {
                entry.lastSendBlock = head;
            }
            const retries = entry.txRecord ? entry.txRecord.retries : 0;
            if (head - entry.lastSendBlock >= this.retry.afterBlocks && retries < this.retry.maxRetries) {
                due.push([hash, entry]);
            }
        }
        // bounded batches: after a halt thousands of votes can be due at once
        for (let i = 0; i < due.length; i += 100) {
            await Promise.all(due.slice(i, i + 100).map(async ([hash, entry]) => {
                entry.lastSendBlock = head;
                if (entry.txRecord) {
                    entry.txRecord.retries += 1;
                }
                const sendProvider = this.sendProviders[this.sendCursor++ % this.sendProviders.length];
                try {
                    await sendProvider.send('eth_sendRawTransaction', [entry.signedTx]);
                } catch (err) {
                    // "already known" (still pooled) / "nonce too low" (already
                    // mined) are expected and harmless; counted, not fatal
                    if (entry.txRecord) {
                        entry.txRecord.retryErrors = (entry.txRecord.retryErrors || 0) + 1;
                        entry.txRecord.lastRetryError = err.message.split('\n')[0].slice(0, 160);
                    }
                    logger.debug(`retry of ${hash} rejected: ${err.message}`);
                }
            }));
        }
    }

    /**
     * Receipts of our pending txs in one block.
     * @returns {Promise<{receipts: Object[], complete: boolean}>} complete=false: some
     *          receipts could not be fetched - the caller rescans this block later
     *          (already-resolved txs are no longer pending, so the rescan is incremental)
     * @throws on a failed eth_getBlockReceipts that should be retried for this block
     */
    async _receiptsForBlock(blockNumber) {
        const tag = '0x' + blockNumber.toString(16);
        if (this.blockReceiptsSupported) {
            try {
                const receipts = (await this.provider.send('eth_getBlockReceipts', [tag])) || [];
                this.blockReceiptFailures = { block: blockNumber, count: 0 };
                return { receipts, complete: true };
            } catch (err) {
                const code = err.error && err.error.code;
                if (code === -32601 || /method not (found|supported)/i.test(err.message)) {
                    logger.warn(`eth_getBlockReceipts unsupported (${err.message}), using per-tx receipts from now on`);
                    this.blockReceiptsSupported = false;
                } else {
                    const f = this.blockReceiptFailures && this.blockReceiptFailures.block === blockNumber
                        ? this.blockReceiptFailures : { block: blockNumber, count: 0 };
                    f.count++;
                    this.blockReceiptFailures = f;
                    if (f.count < BLOCK_RECEIPTS_ATTEMPTS) {
                        throw new Error(`eth_getBlockReceipts(${blockNumber}) failed (attempt ${f.count}/${BLOCK_RECEIPTS_ATTEMPTS}), retrying after backoff: ${err.message.split('\n')[0]}`);
                    }
                    logger.warn(`eth_getBlockReceipts(${blockNumber}) failed ${f.count} times, reading this block per tx (max ${PER_TX_CONCURRENCY} in flight)`);
                }
            }
        }
        const block = await this.provider.send('eth_getBlockByNumber', [tag, false]);
        const ours = ((block && block.transactions) || []).filter((h) => this.pending.has(h));
        const receipts = [];
        let failed = 0;
        for (let i = 0; i < ours.length; i += PER_TX_CONCURRENCY) {
            const batch = await Promise.allSettled(ours.slice(i, i + PER_TX_CONCURRENCY)
                .map((h) => this.provider.send('eth_getTransactionReceipt', [h])));
            for (const r of batch) {
                if (r.status === 'fulfilled') {
                    receipts.push(r.value);
                } else {
                    failed++;
                }
            }
        }
        if (failed > 0) {
            logger.warn(`per-tx receipts for block ${blockNumber}: ${failed}/${ours.length} calls failed, will rescan`);
        }
        return { receipts, complete: failed === 0 };
    }

    _ensureWatcher() {
        if (this.watcherRunning) {
            return;
        }
        this.watcherRunning = true;
        const loop = async () => {
            let backoffMs = 0;
            while (this.pending.size > 0) {
                let pollFailed = false;
                try {
                    const head = parseInt(await this.provider.send('eth_blockNumber', []), 16);
                    this.lastHead = head;
                    // re-scan one block back on (re)start: a tx can land in the
                    // head block before the watcher's first poll
                    if (this.lastScannedBlock === undefined || head - this.lastScannedBlock > 50) {
                        this.lastScannedBlock = head - 2;
                    }
                    for (let b = this.lastScannedBlock + 1; b <= head; b++) {
                        const { receipts, complete } = await this._receiptsForBlock(b);
                        for (const receipt of receipts) {
                            const entry = receipt && this.pending.get(receipt.transactionHash);
                            if (entry) {
                                this.pending.delete(receipt.transactionHash);
                                entry.resolve(receipt);
                            }
                        }
                        if (!complete) {
                            pollFailed = true;
                            break;
                        }
                        this.lastScannedBlock = b;
                    }
                    if (this.retry) {
                        await this._retryPass(head);
                    }
                } catch (err) {
                    pollFailed = true;
                    logger.warn(`block watcher poll failed: ${err.message}`);
                }
                // back off while the node is struggling (doubling, capped), so the
                // watcher does not hammer it with the same heavy request
                backoffMs = pollFailed ? Math.min(WATCH_BACKOFF_MAX_MS, Math.max(1000, backoffMs * 2)) : 0;
                const now = Date.now();
                for (const [hash, entry] of this.pending) {
                    if (now > entry.deadline) {
                        this.pending.delete(hash);
                        entry.reject(new Error(`no receipt for ${hash} before timeout`));
                    }
                }
                await new Promise((r) => setTimeout(r, WATCH_INTERVAL_MS + backoffMs));
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

        let txRecord = null;
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
            txRecord = { verb: request.verb, hash, submitTimeMs, sendOk: false, retries: 0 };
            await sendProvider.send('eth_sendRawTransaction', [signedTx]);
            txRecord.sendOk = true;
            const receipt = await this._waitForReceipt(hash, signedTx, txRecord);
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
            this._recordTx({
                ...txRecord,
                outcome: success ? 'confirmed' : 'reverted',
                confirmTimeMs,
                blockNumber: parseInt(receipt.blockNumber, 16)
            });
        } catch (err) {
            if (txRecord) {
                this._recordTx({
                    ...txRecord,
                    outcome: txRecord.sendOk ? 'no-receipt' : 'send-failed',
                    error: err.message.split('\n')[0].slice(0, 200)
                });
            }
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
