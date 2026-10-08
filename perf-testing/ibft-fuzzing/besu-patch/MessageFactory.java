/*
 * Copyright ConsenSys AG.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * --- BYZANTINE FUZZING PATCH ---
 * See perf-testing/ibft-fuzzing/README.md in the P4P-Besu repo. Not upstream
 * Besu code. Drop-in replacement for the same path in a besu source checkout
 * at tag 24.12.0:
 *   consensus/ibft/src/main/java/org/hyperledger/besu/consensus/ibft/payload/MessageFactory.java
 *
 * Gated by the BESU_IBFT_BYZANTINE_MODE env var so only a deliberately
 * configured validator (one container in the test network) misbehaves; every
 * other validator sees this env var unset and behaves exactly as upstream.
 */
package org.hyperledger.besu.consensus.ibft.payload;

import org.hyperledger.besu.consensus.common.bft.ConsensusRoundIdentifier;
import org.hyperledger.besu.consensus.common.bft.payload.Payload;
import org.hyperledger.besu.consensus.common.bft.payload.SignedData;
import org.hyperledger.besu.consensus.ibft.messagewrappers.Commit;
import org.hyperledger.besu.consensus.ibft.messagewrappers.Prepare;
import org.hyperledger.besu.consensus.ibft.messagewrappers.Proposal;
import org.hyperledger.besu.consensus.ibft.messagewrappers.RoundChange;
import org.hyperledger.besu.consensus.ibft.statemachine.PreparedRoundArtifacts;
import org.hyperledger.besu.crypto.SECPSignature;
import org.hyperledger.besu.crypto.SignatureAlgorithm;
import org.hyperledger.besu.crypto.SignatureAlgorithmFactory;
import org.hyperledger.besu.cryptoservices.NodeKey;
import org.hyperledger.besu.datatypes.Hash;
import org.hyperledger.besu.ethereum.core.Block;

import java.math.BigInteger;
import java.util.Optional;
import java.util.Random;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** The Message factory. */
public class MessageFactory {

  private static final Logger LOG = LoggerFactory.getLogger(MessageFactory.class);

  /**
   * BYZANTINE ADDITION. One of: null/unset (normal), "wrong-round",
   * "wrong-digest", "bad-signature". "garbage-rlp" and "equivocate-prepare"
   * are handled in IbftMessageTransmitter instead, since they don't fit this
   * class's typed-Payload model (garbage-rlp bypasses it; equivocate-prepare
   * needs two independently-addressed sends of otherwise-normal messages
   * this factory already knows how to produce).
   */
  private static final String BYZANTINE_MODE = System.getenv("BESU_IBFT_BYZANTINE_MODE");

  private final NodeKey nodeKey;
  private final Random random = new Random();

  /**
   * Instantiates a new Message factory.
   *
   * @param nodeKey the node key
   */
  public MessageFactory(final NodeKey nodeKey) {
    this.nodeKey = nodeKey;
    if (BYZANTINE_MODE != null) {
      LOG.warn(
          "*** THIS VALIDATOR IS RUNNING IN BYZANTINE FUZZING MODE: {} *** "
              + "This build must never run against a real network.",
          BYZANTINE_MODE);
    }
  }

  /**
   * Create proposal.
   *
   * @param roundIdentifier the round identifier
   * @param block the block
   * @param roundChangeCertificate the round change certificate
   * @return the proposal
   */
  public Proposal createProposal(
      final ConsensusRoundIdentifier roundIdentifier,
      final Block block,
      final Optional<RoundChangeCertificate> roundChangeCertificate) {

    final ProposalPayload payload =
        new ProposalPayload(maybeCorruptRound(roundIdentifier), block.getHash());

    return new Proposal(createSignedMessage(payload), block, roundChangeCertificate);
  }

  /**
   * Create prepare.
   *
   * @param roundIdentifier the round identifier
   * @param digest the digest
   * @return the prepare
   */
  public Prepare createPrepare(final ConsensusRoundIdentifier roundIdentifier, final Hash digest) {

    final PreparePayload payload =
        new PreparePayload(maybeCorruptRound(roundIdentifier), maybeCorruptDigest(digest));

    return new Prepare(createSignedMessage(payload));
  }

  /**
   * Create commit.
   *
   * @param roundIdentifier the round identifier
   * @param digest the digest
   * @param commitSeal the commit seal
   * @return the commit
   */
  public Commit createCommit(
      final ConsensusRoundIdentifier roundIdentifier,
      final Hash digest,
      final SECPSignature commitSeal) {

    final CommitPayload payload =
        new CommitPayload(maybeCorruptRound(roundIdentifier), maybeCorruptDigest(digest), commitSeal);

    return new Commit(createSignedMessage(payload));
  }

  /**
   * Create round change.
   *
   * @param roundIdentifier the round identifier
   * @param preparedRoundArtifacts the prepared round artifacts
   * @return the round change
   */
  public RoundChange createRoundChange(
      final ConsensusRoundIdentifier roundIdentifier,
      final Optional<PreparedRoundArtifacts> preparedRoundArtifacts) {

    final RoundChangePayload payload =
        new RoundChangePayload(
            roundIdentifier,
            preparedRoundArtifacts.map(PreparedRoundArtifacts::getPreparedCertificate));
    return new RoundChange(
        createSignedMessage(payload), preparedRoundArtifacts.map(PreparedRoundArtifacts::getBlock));
  }

  // BYZANTINE ADDITION
  private ConsensusRoundIdentifier maybeCorruptRound(final ConsensusRoundIdentifier actual) {
    if (!"wrong-round".equals(BYZANTINE_MODE)) {
      return actual;
    }
    return new ConsensusRoundIdentifier(actual.getSequenceNumber(), actual.getRoundNumber() + 1);
  }

  // BYZANTINE ADDITION
  private Hash maybeCorruptDigest(final Hash actual) {
    if (!"wrong-digest".equals(BYZANTINE_MODE)) {
      return actual;
    }
    final byte[] garbage = new byte[32];
    random.nextBytes(garbage);
    return Hash.wrap(org.apache.tuweni.bytes.Bytes32.wrap(garbage));
  }

  private <M extends Payload> SignedData<M> createSignedMessage(final M payload) {
    SECPSignature signature = nodeKey.sign(payload.hashForSignature());
    if ("bad-signature".equals(BYZANTINE_MODE)) {
      signature = corruptSignature(signature);
    }
    return SignedData.create(payload, signature);
  }

  // BYZANTINE ADDITION: flips the low bit of r so the signature no longer
  // recovers to this validator's address - a receiver's SignedData decode
  // should reject the message as not coming from a known validator.
  private SECPSignature corruptSignature(final SECPSignature original) {
    final SignatureAlgorithm sig = SignatureAlgorithmFactory.getInstance();
    final BigInteger corruptedR = original.getR().xor(BigInteger.ONE);
    return sig.createSignature(corruptedR, original.getS(), original.getRecId());
  }
}
