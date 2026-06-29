#!/bin/bash
# Usage: ./tally.sh CANDIDATE_ID
set -e

if [ -z "$1" ]; then
  echo "Usage: ./tally.sh CANDIDATE_ID"
  echo "Example: ./tally.sh 0"
  exit 1
fi

CONTRACT=0x3e0fe203b5854985b4baf481b8ba08cf96524494
RPC=http://127.0.0.1:8545
CANDIDATE=$1

echo "=== Tally for candidate $CANDIDATE ==="
cast call $CONTRACT "getTally(uint8)" $CANDIDATE --rpc-url $RPC