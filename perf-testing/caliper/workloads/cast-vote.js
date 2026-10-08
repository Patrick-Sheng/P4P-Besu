'use strict';

// Caliper workload: cast one vote per simulated voter.
//
// Models real turnout, not a repeatable hot-wallet benchmark: each transaction
// comes from a DIFFERENT, previously-registered voter account, because
// VotingSystem.castVote() can only ever succeed once per address (NotVoted ->
// Processing -> Voted). The voter pool is pre-registered and voting is opened
// by perf-testing/caliper/seed/register-voters.js BEFORE the benchmark runs, so
// this workload's timed transactions are pure castVote() confirmation latency,
// matching the brief's "p50/p95/p99 vote confirmation latency" metric - not
// conflated with registration overhead.
//
// roundArguments:
//   votersFile:    path (relative to the caliper workspace) to a JSON array of
//                  { "address": "0x..", "privateKey": "0x.." } produced by
//                  seed/generate-voters.js and registered by seed/register-voters.js
//   numCandidates: number of candidates to vote across (default 3, matches the
//                  deployed VotingSystem constructor argument)

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const path = require('node:path');
const fs = require('node:fs');

class CastVoteWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.myVoters = [];
        this.cursor = 0;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);

        if (!roundArguments.votersFile) {
            throw new Error('cast-vote workload requires roundArguments.votersFile');
        }
        this.numCandidates = roundArguments.numCandidates || 3;

        const votersPath = path.isAbsolute(roundArguments.votersFile)
            ? roundArguments.votersFile
            : path.resolve(process.cwd(), roundArguments.votersFile);
        const allVoters = JSON.parse(fs.readFileSync(votersPath, 'utf8'));

        // Deterministic partition: no cross-worker coordination needed, and no
        // two workers can ever pick the same voter.
        this.myVoters = allVoters.filter((_, idx) => idx % this.totalWorkers === this.workerIndex);

        if (this.myVoters.length === 0) {
            throw new Error(
                `Worker ${this.workerIndex}: voter pool (${allVoters.length} total, ${this.totalWorkers} workers) ` +
                'left this worker with zero voters. Generate a larger pool.'
            );
        }
    }

    async submitTransaction() {
        if (this.cursor >= this.myVoters.length) {
            throw new Error(
                `Worker ${this.workerIndex}: exhausted its ${this.myVoters.length}-voter pool. ` +
                'Each voter can only vote once - generate/register a larger voter pool for this round ' +
                '(size >= target TPS * round duration).'
            );
        }

        const voter = this.myVoters[this.cursor];
        const candidateId = this.cursor % this.numCandidates;
        this.cursor += 1;

        await this.sutAdapter.sendRequests({
            contract: 'VotingSystem',
            verb: 'castVote',
            args: [candidateId],
            privateKey: voter.privateKey,
            // pool voters are fresh accounts (registration is sent by the admin),
            // and each votes exactly once, so their only tx is always nonce 0
            nonce: 0
        });
    }
}

function createWorkloadModule() {
    return new CastVoteWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
