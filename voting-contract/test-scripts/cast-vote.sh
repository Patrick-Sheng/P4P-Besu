#!/bin/bash
# Usage: ./cast-vote.sh 0xVOTER_PRIVATE_KEY CANDIDATE_ID
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: ./cast-vote.sh 0xVOTER_PRIVATE_KEY CANDIDATE_ID"
  echo "Example: ./cast-vote.sh 0xabc123... 0"
  exit 1
fi

CONTRACT=0x6BB0c560dE5922eAd78Ff84d998343A01750f6A2
RPC=http://127.0.0.1:8545
VOTER_KEY=$1
CANDIDATE=$2

echo "=== Casting vote for candidate $CANDIDATE ==="
cast send $CONTRACT "castVote(uint8)" $CANDIDATE \
  --private-key $VOTER_KEY --rpc-url $RPC --legacy

echo ""
echo "Vote cast for candidate $CANDIDATE."