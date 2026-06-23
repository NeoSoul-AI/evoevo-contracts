.PHONY: deps deps-clean build clean test test-ci coverage abi-export

FORGE_STD_REF ?= v1.15.0
OPENZEPPELIN_REF ?= v5.6.1

deps:
	@if [ -d lib/forge-std/src ] && [ -d lib/openzeppelin-contracts/contracts ] && [ -d lib/openzeppelin-contracts-upgradeable/contracts ]; then \
		echo "Dependencies already installed."; \
	else \
		forge install foundry-rs/forge-std@$(FORGE_STD_REF) OpenZeppelin/openzeppelin-contracts@$(OPENZEPPELIN_REF) OpenZeppelin/openzeppelin-contracts-upgradeable@$(OPENZEPPELIN_REF) --no-git; \
	fi

deps-clean:
	rm -rf lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable
	forge install foundry-rs/forge-std@$(FORGE_STD_REF) OpenZeppelin/openzeppelin-contracts@$(OPENZEPPELIN_REF) OpenZeppelin/openzeppelin-contracts-upgradeable@$(OPENZEPPELIN_REF) --no-git

build:
	forge build

clean:
	forge clean

test:
	forge test --offline -vv

test-ci:
	FOUNDRY_PROFILE=ci forge test --offline -vv

coverage:
	forge coverage --report summary

abi-export: build
	mkdir -p abis
	python3 -c "import json; json.dump(json.load(open('out/EvoBindingRegistry.sol/EvoBindingRegistry.json'))['abi'], open('abis/EvoBindingRegistry.json','w'), indent=2)"
	python3 -c "import json; json.dump(json.load(open('out/EvoEvolutionRegistry.sol/EvoEvolutionRegistry.json'))['abi'], open('abis/EvoEvolutionRegistry.json','w'), indent=2)"
	python3 -c "import json; json.dump(json.load(open('out/EvoCommitteeOracle.sol/EvoCommitteeOracle.json'))['abi'], open('abis/EvoCommitteeOracle.json','w'), indent=2)"
	python3 -c "import json; json.dump(json.load(open('out/EvoPredictionRegistry.sol/EvoPredictionRegistry.json'))['abi'], open('abis/EvoPredictionRegistry.json','w'), indent=2)"
	python3 -c "import json; json.dump(json.load(open('out/EvoUserActionRouter.sol/EvoUserActionRouter.json'))['abi'], open('abis/EvoUserActionRouter.json','w'), indent=2)"
