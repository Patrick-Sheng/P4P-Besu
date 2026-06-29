#!/bin/bash
set -e

CONTRACT=0x3e0fe203b5854985b4baf481b8ba08cf96524494
RPC=http://127.0.0.1:8545
ADMIN_KEY=$(cat ../../network/networkFiles/keys/$(ls ../../network/networkFiles/keys/ | head -1)/key)

echo "=== Opening voting ==="
cast send $CONTRACT "openVoting()" \
  --private-key $ADMIN_KEY --rpc-url $RPC --legacy

echo ""
echo "Voting is now open. Voters can now register and cast votes."
echo "Run register-voter.sh to register a voter."