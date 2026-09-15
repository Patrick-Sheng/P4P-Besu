#!/bin/bash
set -e

CONTRACT=0x6BB0c560dE5922eAd78Ff84d998343A01750f6A2
RPC=http://127.0.0.1:8545
ADMIN_KEY=$(cat ../../network/networkFiles/keys/$(ls ../../network/networkFiles/keys/ | head -1)/key)

echo "=== Opening voting ==="
cast send $CONTRACT "openVoting()" \
  --private-key $ADMIN_KEY --rpc-url $RPC --legacy

echo ""
echo "Voting is now open. Voters can now register and cast votes."
echo "Run register-voter.sh to register a voter."