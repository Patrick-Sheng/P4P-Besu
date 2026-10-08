# IBFT2 wire-protocol byzantine fuzzing (Area 3, stretch scope)

## Status: verified design + starter patch, not a built/tested artifact

Everything else in `perf-testing/` was run against a live network this
session. This was not: it requires forking and rebuilding Besu itself (a
large multi-module Gradle project), which is genuinely multi-hour/multi-day
work and out of scope for what could be compiled and tested in this session.
What follows is source-verified against the real Besu 24.12.0 source (cloned
and inspected directly, not recalled from training data - see "Verification"
below), plus two complete starter patch files. Treat this as a solid running
start, not a finished feature.

## Why this needs a Besu fork at all

The double-vote / equivocation / replay scripts in `../fault-injection/malicious/`
attack the **application layer**: they submit transactions (signed calls to
`castVote`) through the normal JSON-RPC surface. That's sufficient for
everything expressible as "what if a client submits a bad transaction" - which
covers double-voting, equivocation-of-votes, and replay as literally specified
in the test plan.

"Malformed consensus messages: garbage or out-of-protocol PRE-PREPARE/
PREPARE/COMMIT payloads" is a different attack surface entirely: it's about a
**validator** misbehaving inside the IBFT2 round protocol itself (the P2P/RLPx
devp2p messages validators exchange to agree on the next block), not about
what a client submits. Besu has no CLI flag, plugin hook, or JSON-RPC method
that lets you make a validator emit a malformed consensus message - the
`besu-plugin-api` surface exposes block-added events, RPC extensions, storage
backends, etc., but not IBFT2 message construction/transmission. The only way
to make one validator actually emit bad IBFT wire messages is to change the
Java code that constructs them.

A raw network-level approach (e.g. a TCP proxy mutating bytes on a validator's
p2p port) was considered and rejected: RLPx frames are encrypted+MAC'd after
the initial ECIES handshake, so a blind proxy can't produce a
still-decryptable-but-semantically-malformed IBFT payload - it can only
corrupt the frame, which just gets dropped as a MAC failure. That tests
transport-layer robustness, not IBFT2's message validation logic.

## Injection point (verified against besu tag 24.12.0 source)

```
consensus/ibft/src/main/java/org/hyperledger/besu/consensus/ibft/
├── payload/MessageFactory.java          <- constructs+signs every outbound
│                                            Proposal/Prepare/Commit/RoundChange
├── network/IbftMessageTransmitter.java  <- the ONE choke point all 4 message
│                                            types pass through before
│                                            multicaster.send(message)
├── messagedata/PrepareMessageData.java  <- (+ Proposal/Commit/RoundChange
│                                            variants) wrap a MessageFactory
│                                            output as raw RLP MessageData
└── validation/MessageValidator.java     <- the receiving side's acceptance
                                             logic - this is what should
                                             reject everything below
```

`IbftRoundFactory` (same module, `statemachine/IbftRoundFactory.java`)
constructs one `IbftMessageTransmitter` per round from a single per-validator
`MessageFactory` instance. Every validator runs the same unmodified code
today - there's no existing hook to make just one of them behave differently.

`ValidatorMulticaster` (in `consensus/common`) already has a two-argument
`send(MessageData message, Collection<Address> denylist)` overload alongside
the plain `send(message)` that `IbftMessageTransmitter` currently always uses.
That denylist parameter is exactly what "send conflicting messages to
different peers" needs, and it's already there - nothing to add for that part
except calling the overload with two different peer subsets.

## The patch: `MessageFactory.java` + `IbftMessageTransmitter.java`

Design choice: gate byzantine behaviour behind an environment variable
(`BESU_IBFT_BYZANTINE_MODE`) read once in `MessageFactory`'s constructor,
rather than threading a new CLI flag through Besu's option-parsing and
controller-builder wiring (which spans code outside the `consensus/ibft`
module and would make the patch much larger and harder to keep in sync with
upstream). This keeps the diff to exactly two files. To make ONE validator
byzantine: build a custom image from the patched source, and set
`BESU_IBFT_BYZANTINE_MODE=<mode>` in that one validator's docker-compose
service (see "Wiring into the test harness" below) - every other validator
runs the stock image unmodified.

See `besu-patch/MessageFactory.java` and `besu-patch/IbftMessageTransmitter.java`
in this directory for the full patched files (drop-in replacements for the
same paths in a besu source checkout at tag `24.12.0`). Modes implemented:

| Mode | What it does | What should catch it |
|---|---|---|
| `wrong-round` | Signs a Prepare/Commit for `roundIdentifier.getRoundNumber() + 1` instead of the actual round | `MessageValidator` / `RoundState` round-matching check - message is for a round the receiver isn't in, discarded |
| `wrong-digest` | Signs a Prepare/Commit against a random `Hash` instead of the real proposal digest | Digest-consistency check in `MessageValidator` - Prepare/Commit that doesn't match the accepted Proposal is rejected |
| `bad-signature` | Flips the low bit of the signature's `r` component after signing | Signature recovery in `SignedData` won't recover a valid validator address - rejected as "not from a known validator" |
| `garbage-rlp` | Bypasses `MessageFactory` and `PrepareMessageData.create()` entirely; sends a bare `AbstractMessageData` subclass wrapping `Bytes.random(96)` under the correct `IbftV2.PREPARE` message code - correct message *code*, garbage RLP body | Exercises the RLP decoder itself (`Prepare.decode()`); should throw a decode exception that's caught and the message dropped, node must not crash |
| `equivocate-prepare` | Constructs two *validly signed* Prepares for the same round with different digests and broadcasts both to every peer (`multicaster.send(message)` twice) | Not really "caught" by validation - every peer sees both and must handle the conflict; the expected outcome is "IBFT's 2f+1 quorum requirement means the byzantine node's two contradictory votes can't both count, so it contributes at most 1 signature toward whichever digest actually reaches quorum among the honest majority." **Not implemented**: true peer-subset targeting (mode A to half the network, mode B to the other half) - `IbftMessageTransmitter` only holds a `ValidatorMulticaster`, not the validator address list needed to partition peers with the existing `send(message, denylist)` overload. Doing that properly means threading the address list into this class, a further well-scoped extension, not done here. |

Each mode only ever fires for the ONE byzantine validator's own messages -
this deliberately models "one validator among n misbehaves," which is the
actual threat model IBFT2's 3f+1/2f+1 quorum math is built to tolerate, not
"the whole network is broken."

## What each mode should demonstrate against the test plan's questions

- **"does the smart contract's three-state model correctly reject the
  double-vote at the application layer"** - not applicable here, that's
  `fault-injection/malicious/double-vote.js` (already validated, application
  layer).
- **"does IBFT's quorum requirement prevent the malicious node influencing
  consensus alone"** - `wrong-round`/`wrong-digest`/`equivocate-prepare`: with
  n validators and f byzantine, the byzantine node can supply at most 1 of the
  2f+1 signatures a Proposal/Commit needs, so honest nodes reaching quorum
  among themselves (n-1 honest ≥ 2f+1 whenever n ≥ 3f+1) is what should be
  observed - the chain finalizes the block the honest majority agreed on,
  never the byzantine node's version, and it never single-handedly stalls
  consensus either.
- **"does the malicious node get outvoted automatically rather than needing
  manual removal from the validator set"** - run every mode across a full
  epoch (`epochlength: 30000` in the genesis config, see
  `perf-testing/network/generate-network.mjs`) and confirm the byzantine
  node's messages are rejected round after round with zero manual
  intervention - IBFT2 has no on-chain slashing/eviction, so "outvoted" here
  means "its vote never counts toward quorum," not "it gets removed from the
  validator set." If the test plan wants literal validator-set removal, that
  requires a separate `ibft_discardValidatorVote`/`ibft_proposeValidatorVote`
  governance action by the honest validators - a distinct, already-supported
  Besu RPC feature, not something the byzantine node can be forced into
  automatically.

## Wiring into the test harness (once built)

In `perf-testing/network/generate-network.mjs`, one validator's service block
would need:
```yaml
    image: your-registry/besu-byzantine:24.12.0   # built from the patched source
    environment:
      - BESU_IBFT_BYZANTINE_MODE=wrong-digest      # instead of the stock image's line
```
while every other validator keeps `image: hyperledger/besu:24.12.0` unmodified.
The generator script would need a `--byzantine-node=<index>:<mode>` flag added
to do this automatically instead of hand-editing the generated compose file;
not implemented here since there's no built image yet to point it at.

## Building it (not done this session)

```bash
git clone https://github.com/hyperledger/besu.git
cd besu && git checkout 24.12.0
# apply besu-patch/MessageFactory.java and besu-patch/IbftMessageTransmitter.java
# over the matching paths under consensus/ibft/src/main/java/...
./gradlew distDocker    # produces a local besu:<version> image; expect a long
                         # first build (large multi-module Gradle project)
docker tag hyperledger/besu:<built-version> besu-byzantine:24.12.0
```
Then validate the patch compiles and the modes behave as designed against
Besu's own IBFT integration test harness
(`consensus/ibft/src/integration-test/...`, visible in the same source tree)
before pointing a real validator at it - that test harness already spins up
an in-process multi-validator IBFT network specifically for this kind of
message-level testing, which is a faster feedback loop than a full
docker-compose network for iterating on the patch itself.

## Verification

The class names, method signatures, and file paths above were confirmed by
cloning `https://github.com/hyperledger/besu` at tag `24.12.0` (matching the
Besu version this whole project runs, per the root `README.md`) and reading
the actual source in this session - not recalled from training data, which
can drift from a specific pinned version. If Besu is upgraded past 24.12.0
later, re-check these paths before relying on the patch; Besu has
reorganized its consensus module boundaries between major versions before.
