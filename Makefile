all         :; forge build --use solc:0.8.17
clean       :; forge clean
deploy	    :; forge script script/Deploy.s.sol:Deploy --rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --broadcast --verify -vvvv
