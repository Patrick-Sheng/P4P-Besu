#!/bin/bash
# Usage: ./register-voter.sh 0xVOTER_ADDRESS
set -e

if [ -z "$1" ]; then
  echo "Usage: ./register-voter.sh 0xVOTER_ADDRESS"
  exit 1
fi

CONTRACT=0x3e0fe203b5854985b4baf481b8ba08cf96524494
RPC=http://127.0.0.1:8545
ADMIN_KEY=$(cat ../../network/networkFiles/keys/$(ls ../../network/networkFiles/keys/ | head -1)/key)
VOTER_ADDRESS=$1

echo "=== Registering voter: $VOTER_ADDRESS ==="
cast send $CONTRACT "registerVoter(address)" $VOTER_ADDRESS \
  --private-key $ADMIN_KEY --rpc-url $RPC --legacy

echo ""
echo "Voter $VOTER_ADDRESS is now registered."