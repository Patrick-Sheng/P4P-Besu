## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

---

## IBFT Voting Test — Full Execution Guide

### Prerequisites
- All 4 Besu nodes running
- Contract deployed (you will see the contract address printed when you first run the deploy script — replace the address below with yours)

```
Contract deployed at: 0x3e0fe203b5854985b4baf481b8ba08cf96524494
```

### 1. Navigate to scripts folder

```bash
cd ~/P4P-Besu/voting-contract/test-scripts
chmod +x *.sh
```

### 2. Open the election (admin)

```bash
./setup-election.sh
```

Expected: `Voting is now open.`

### 3. Create voter wallets

```bash
cast wallet new
```

Save the output:
```
Address:     0xABC...   ← VOTER_ADDRESS
Private key: 0xDEF...   ← VOTER_KEY
```

Repeat for each voter you want to test.

### 4. Register each voter (admin)

```bash
./register-voter.sh 0xVOTER_ADDRESS
```

Expected: `Voter 0xABC... is now registered.`

### 5. Cast votes

```bash
./cast-vote.sh 0xVOTER_KEY CANDIDATE_ID
```

- Candidate IDs are `0`, `1`, or `2`
- Each voter can only vote once
- Use a different `VOTER_KEY` per voter

Example with 3 voters:
```bash
./cast-vote.sh 0xKEY_VOTER1 0   # votes for candidate 0
./cast-vote.sh 0xKEY_VOTER2 0   # votes for candidate 0
./cast-vote.sh 0xKEY_VOTER3 1   # votes for candidate 1
```

### 6. Check results

```bash
./tally.sh 0   # candidate 0 tally
./tally.sh 1   # candidate 1 tally
./tally.sh 2   # candidate 2 tally
```

Expected output (last digits = vote count):
```
0x0000000000000000000000000000000000000000000000000000000000000002
                                                                  ^
                                                              2 votes
```

### 7. Verify on the node terminal

Every `cast send` should produce this in your Besu node log:

```
Imported #XXX / 1 tx / 0 pending / ...
```

The `1 tx` confirms the transaction went through IBFT consensus.
