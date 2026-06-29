# P4P Blockchain Voting System

Private blockchain-based electronic voting system using Hyperledger Besu with IBFT 2.0 consensus.

## Stack
- Hyperledger Besu 24.12.0
- IBFT 2.0 consensus (4 validators)
- Solidity 0.8.19 smart contract
- Foundry (forge, cast, anvil)

## Setup

### 1. Dependencies
- Java 21
- Besu 24.12.0
- Foundry

### 2. Generate network
```bash
cd network
besu operator generate-blockchain-config \
  --config-file=ibftConfigFile.json \
  --to=networkFiles \
  --private-key-file-name=key
```

### 3. Start validators
Follow the [Besu IBFT 2.0 tutorial](https://docs.besu-eth.org/private-networks/tutorials/ibft) to create the node directory structure and run all 4 validator nodes.

### 4. Deploy contract
First install dependencies:
```bash
cd voting-contract
forge install
```
or 
```bash
cd voting-contract
forge install foundry-rs/forge-std --no-commit
```

Create a `.env` file with the private key of one of the validator nodes you created:
```
DEPLOYER_PRIVATE_KEY=<private_key_of_your_deployer_node>
```

Then build and deploy:
```bash
forge build
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --legacy
```

### 5. Run tests
```bash
forge test -vv
```

## Contract
VotingSystem.sol -- three-state voter registry (NotVoted / Processing / Voted), castVote(), getTally()
