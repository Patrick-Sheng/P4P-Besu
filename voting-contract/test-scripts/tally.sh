#!/bin/bash
# Usage: ./tally.sh CANDIDATE_ID
set -e

if [ -z "$1" ]; then
  echo "Usage: ./tally.sh CANDIDATE_ID"
  echo "Example: ./tally.sh 0"
  exit 1
fi

CONTRACT=0x6BB0c560dE5922eAd78Ff84d998343A01750f6A2
RPC=http://127.0.0.1:8545
CANDIDATE=$1

echo "=== Tally for candidate $CANDIDATE ==="
cast call $CONTRACT "getTally(uint8)" $CANDIDATE --rpc-url $RPC