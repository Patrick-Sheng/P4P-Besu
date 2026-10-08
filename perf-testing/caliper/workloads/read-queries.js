'use strict';

// Read-path workload for the Volume test (Area 4): measures getTally() /
// getVoterState() query latency at a given point in chain state size, so
// consecutive rounds interleaved with vote-casting rounds (see
// benchmarks/throughput/volume.yaml) show whether reads degrade as the
// registeredVoters/voterState/voteCount state grows toward the full ~2.9M
// vote dataset.
//
// roundArguments:
//   votersFile:    same pool used to cast votes earlier, so getVoterState()
//                  looks up addresses that actually exist in contract state
//   numCandidates: for getTally() round-robin

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const path = require('node:path');
const fs = require('node:fs');

class ReadQueriesWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.cursor = 0;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);

        this.numCandidates = roundArguments.numCandidates || 3;

        const votersPath = path.isAbsolute(roundArguments.votersFile)
            ? roundArguments.votersFile
            : path.resolve(process.cwd(), roundArguments.votersFile);
        const allVoters = JSON.parse(fs.readFileSync(votersPath, 'utf8'));
        this.myVoters = allVoters.filter((_, idx) => idx % this.totalWorkers === this.workerIndex);
    }

    async submitTransaction() {
        const useTally = this.cursor % 2 === 0;
        this.cursor += 1;

        if (useTally || this.myVoters.length === 0) {
            await this.sutAdapter.sendRequests({
                contract: 'VotingSystem',
                verb: 'getTally',
                args: [this.cursor % this.numCandidates],
                readOnly: true
            });
        } else {
            const voter = this.myVoters[this.cursor % this.myVoters.length];
            await this.sutAdapter.sendRequests({
                contract: 'VotingSystem',
                verb: 'getVoterState',
                args: [voter.address],
                readOnly: true
            });
        }
    }
}

function createWorkloadModule() {
    return new ReadQueriesWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
