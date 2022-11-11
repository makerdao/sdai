#!/usr/bin/env bash
set -e

if [[ -z "$1" ]]; then
  forge test --use solc:0.8.17 --rpc-url "$ETH_RPC_URL"
else
  forge test --match "$1" -vvv --use solc:0.8.17 --rpc-url "$ETH_RPC_URL"
fi
