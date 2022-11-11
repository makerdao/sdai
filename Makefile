all         :; forge build --use solc:0.8.17
clean       :; forge clean
test        :; ./test.sh $(match)
deploy	    :; forge script script/Deploy.s.sol:Deploy --use solc:0.8.17 --rpc-url $(ETH_RPC_URL) --sender $(ETH_FROM) --broadcast --verify -vvvv
