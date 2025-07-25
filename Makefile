include .env

##
# Solidity Setup / Testing
##
.PHONY: install-foundry
install-foundry:
	curl -L https://foundry.paradigm.xyz | bash
	~/.foundry/bin/foundryup

.PHONY: deps
deps: clean-lib checkout-op-commit patch-kailua
	forge install --no-git github.com/foundry-rs/forge-std \
		github.com/OpenZeppelin/openzeppelin-contracts@v4.9.3 \
		github.com/OpenZeppelin/openzeppelin-contracts-upgradeable@v4.7.3 \
		github.com/rari-capital/solmate@8f9b23f8838670afda0fd8983f2c41e8037ae6bc \
		github.com/Vectorized/solady@862a0afd3e66917f50e987e91886b9b90c4018a1 \
		github.com/ethereum-optimism/lib-keccak@3b1e7bbb4cc23e9228097cfebe42aedaf3b8f2b9 \
		github.com/base/op-enclave@6b67399eff20153ffeb735a07c2253bac2567a5b

.PHONY: build
build:
	forge build; \
	cd lib/kailua/crates/contracts/foundry; \
	forge build

.PHONY: test
test:
	forge test --ffi -vvv

.PHONY: clean-lib
clean-lib:
	rm -rf lib

.PHONY: patch-kailua
patch-kailua:
	forge install github.com/risc0/kailua@e3381e7fde2d3b11d7087a41d85b0b12a0cd4b51; \
	cd lib/kailua/; \
	git apply ../../patch/kailua.patch

.PHONY: checkout-op-commit
checkout-op-commit:
	[ -n "$(OP_COMMIT)" ] || (echo "OP_COMMIT must be set in .env" && exit 1)
	rm -rf lib/optimism
	mkdir -p lib/optimism
	cd lib/optimism; \
	git init; \
	git remote add origin https://github.com/ethereum-optimism/optimism.git; \
	git fetch --depth=1 origin $(OP_COMMIT); \
	git reset --hard FETCH_HEAD; \
	git apply ../../patch/optimism.patch