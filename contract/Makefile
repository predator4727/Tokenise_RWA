-include .env

.PHONY: deploy

deploy:; @forge script script/DeployDTsla.s.sol:DeployDTsla --sender 0x8042A7936f5d02f0f85d064029c3Ae3F9fbb1B98 --account defaultKey --rpc-url ${SEPOLIA_RPC_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --priority-gas-price 1 --verify --broadcast

