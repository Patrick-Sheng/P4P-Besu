#!/bin/bash
ENODE="enode://be4af04b365cdd1a9df45df2b2ded88fc00fb5437491df54df2456725586c035909853b34f6479ef32ffeb095c231cee5c127b7382833bb3f979bb63d814cc62@127.0.0.1:30303"

echo "Starting Node 1 (bootnode)..."
besu \
  --data-path=network/node1/data \
  --genesis-file=network/node1/genesis.json \
  --node-private-key-file=network/node1/key \
  --rpc-http-enabled \
  --rpc-http-api=ETH,NET,IBFT,ADMIN \
  --host-allowlist="*" \
  --rpc-http-cors-origins="*" \
  --rpc-http-port=8545 \
  --p2p-port=30303 \
  --profile=ENTERPRISE \
  --logging=INFO &

sleep 3

echo "Starting Node 2..."
besu \
  --data-path=network/node2/data \
  --genesis-file=network/node2/genesis.json \
  --node-private-key-file=network/node2/key \
  --bootnodes="$ENODE" \
  --rpc-http-enabled \
  --rpc-http-api=ETH,NET,IBFT,ADMIN \
  --host-allowlist="*" \
  --rpc-http-cors-origins="*" \
  --rpc-http-port=8546 \
  --p2p-port=30304 \
  --profile=ENTERPRISE \
  --logging=INFO &

echo "Starting Node 3..."
besu \
  --data-path=network/node3/data \
  --genesis-file=network/node3/genesis.json \
  --node-private-key-file=network/node3/key \
  --bootnodes="$ENODE" \
  --rpc-http-enabled \
  --rpc-http-api=ETH,NET,IBFT,ADMIN \
  --host-allowlist="*" \
  --rpc-http-cors-origins="*" \
  --rpc-http-port=8547 \
  --p2p-port=30305 \
  --profile=ENTERPRISE \
  --logging=INFO &

echo "Starting Node 4..."
besu \
  --data-path=network/node4/data \
  --genesis-file=network/node4/genesis.json \
  --node-private-key-file=network/node4/key \
  --bootnodes="$ENODE" \
  --rpc-http-enabled \
  --rpc-http-api=ETH,NET,IBFT,ADMIN \
  --host-allowlist="*" \
  --rpc-http-cors-origins="*" \
  --rpc-http-port=8548 \
  --p2p-port=30306 \
  --profile=ENTERPRISE \
  --logging=INFO &

echo "All nodes started."
