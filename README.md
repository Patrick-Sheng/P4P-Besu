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
besu operator generate-blockchain-config \
  --config-file=ibftConfigFile.json \
  --to=networkFiles \
  --private-key-file-name=key
```

### 3. Start validators
See node startup commands in project notes.

### 4. Deploy contract
```bash
cd voting-contract
forge build
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --legacy
```

### 5. Run tests
```bash
forge test -vv
```

## Contract
VotingSystem.sol -- three-state voter registry (NotVoted / Processing / Voted), castVote(), getTally()
