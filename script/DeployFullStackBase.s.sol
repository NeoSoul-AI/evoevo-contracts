// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EvoBindingRegistry} from "../src/EvoBindingRegistry.sol";
import {EvoEvolutionRegistry} from "../src/EvoEvolutionRegistry.sol";
import {EvoCommitteeOracle} from "../src/EvoCommitteeOracle.sol";
import {EvoPredictionRegistry} from "../src/EvoPredictionRegistry.sol";
import {EvoUserActionRouter} from "../src/EvoUserActionRouter.sol";

abstract contract DeployFullStackBase is Script {
    struct DeployConfig {
        address deployer;
        address identityRegistry;
        bool strictRoleConfiguration;
        address evoCoreAdmin;
        address agentSigner;
        address predictionManager;
        address predictionResultPublisher;
        address predictionSnapshotPublisher;
        address committeeAdmin;
        address committeeGovernor;
        address committeeTimelockExecutor;
        address committeeEmergencyGuardian;
        address committeeAutomationOperator;
        address committeeChallengeOperator;
        address committeeJurorManager;
        address committeeJurorApprover;
        EvoCommitteeOracle.ProtocolConfig committeeConfig;
    }

    struct DeployArtifacts {
        address agent;
        address bindingImplementation;
        address binding;
        address evolutionRegistryImplementation;
        address evolutionRegistry;
        address committeeImplementation;
        address committee;
        address predictionImplementation;
        address prediction;
        address routerImplementation;
        address router;
    }

    function _envAddressOr(string memory key, address defaultValue) internal view returns (address) {
        if (vm.envExists(key)) return vm.envAddress(key);
        return defaultValue;
    }

    function _envUintOr(string memory key, uint256 defaultValue) internal view returns (uint256) {
        if (vm.envExists(key)) return vm.envUint(key);
        return defaultValue;
    }

    function _envBoolOr(string memory key, bool defaultValue) internal view returns (bool) {
        if (vm.envExists(key)) return vm.envBool(key);
        return defaultValue;
    }

    function _envAddressAliasOr(string memory primaryKey, string memory legacyKey, address defaultValue)
        internal
        view
        returns (address)
    {
        if (vm.envExists(primaryKey)) return vm.envAddress(primaryKey);
        if (vm.envExists(legacyKey)) return vm.envAddress(legacyKey);
        return defaultValue;
    }

    function _envExistsEither(string memory primaryKey, string memory legacyKey) internal view returns (bool) {
        return vm.envExists(primaryKey) || vm.envExists(legacyKey);
    }

    function _envUintAliasOr(string memory primaryKey, string memory legacyKey, uint256 defaultValue)
        internal
        view
        returns (uint256)
    {
        if (vm.envExists(primaryKey)) return vm.envUint(primaryKey);
        if (vm.envExists(legacyKey)) return vm.envUint(legacyKey);
        return defaultValue;
    }

    function _envPolicyHash() internal view returns (bytes32) {
        if (vm.envExists("COMMITTEE_ORACLE_POLICY_HASH")) return vm.envBytes32("COMMITTEE_ORACLE_POLICY_HASH");
        if (vm.envExists("COMMITTEE_V2_POLICY_HASH")) return vm.envBytes32("COMMITTEE_V2_POLICY_HASH");
        return keccak256("committee-mainline-default-policy");
    }

    function _protocolConfig() internal view returns (EvoCommitteeOracle.ProtocolConfig memory config) {
        config = EvoCommitteeOracle.ProtocolConfig({
            primaryCount: uint16(_envUintAliasOr("COMMITTEE_ORACLE_PRIMARY_COUNT", "COMMITTEE_V2_PRIMARY_COUNT", 3)),
            reserveCount: uint16(_envUintAliasOr("COMMITTEE_ORACLE_RESERVE_COUNT", "COMMITTEE_V2_RESERVE_COUNT", 2)),
            quorum: uint16(_envUintAliasOr("COMMITTEE_ORACLE_QUORUM", "COMMITTEE_V2_QUORUM", 2)),
            selectionDelayBlocks: uint64(
                _envUintAliasOr("COMMITTEE_ORACLE_SELECTION_DELAY_BLOCKS", "COMMITTEE_V2_SELECTION_DELAY_BLOCKS", 2)
            ),
            voteWindow: uint64(_envUintAliasOr("COMMITTEE_ORACLE_VOTE_WINDOW", "COMMITTEE_V2_VOTE_WINDOW", 1 days)),
            graceWindow: uint64(
                _envUintAliasOr("COMMITTEE_ORACLE_GRACE_WINDOW", "COMMITTEE_V2_GRACE_WINDOW", 1 days)
            ),
            challengeWindow: uint64(
                _envUintAliasOr("COMMITTEE_ORACLE_CHALLENGE_WINDOW", "COMMITTEE_V2_CHALLENGE_WINDOW", 5 minutes)
            ),
            challengeBond: uint96(
                _envUintAliasOr("COMMITTEE_ORACLE_CHALLENGE_BOND", "COMMITTEE_V2_CHALLENGE_BOND", 0 ether)
            ),
            policyHash: _envPolicyHash(),
            maxEpochs: uint16(_envUintAliasOr("COMMITTEE_ORACLE_MAX_EPOCHS", "COMMITTEE_V2_MAX_EPOCHS", 32))
        });
    }

    function _loadCommonConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.deployer = deployer;
        cfg.evoCoreAdmin = _envAddressOr("EVO_CORE_ADMIN_ADDRESS", deployer);
        cfg.agentSigner = _envAddressOr("AGENT_SIGNER_ADDRESS", deployer);
        cfg.predictionManager = _envAddressOr("PREDICTION_MANAGER_ADDRESS", deployer);
        cfg.predictionResultPublisher = _envAddressOr("PREDICTION_RESULT_PUBLISHER_ADDRESS", deployer);
        cfg.predictionSnapshotPublisher = _envAddressOr("PREDICTION_SNAPSHOT_PUBLISHER_ADDRESS", deployer);
        cfg.committeeAdmin =
            _envAddressAliasOr("COMMITTEE_ORACLE_ADMIN_ADDRESS", "COMMITTEE_V2_ADMIN_ADDRESS", deployer);
        cfg.committeeGovernor =
            _envAddressAliasOr("COMMITTEE_ORACLE_GOVERNOR_ADDRESS", "COMMITTEE_V2_GOVERNOR_ADDRESS", deployer);
        cfg.committeeTimelockExecutor = _envAddressAliasOr(
            "COMMITTEE_ORACLE_TIMELOCK_EXECUTOR_ADDRESS", "COMMITTEE_V2_TIMELOCK_EXECUTOR_ADDRESS", deployer
        );
        cfg.committeeEmergencyGuardian = _envAddressAliasOr(
            "COMMITTEE_ORACLE_EMERGENCY_GUARDIAN_ADDRESS",
            "COMMITTEE_V2_EMERGENCY_GUARDIAN_ADDRESS",
            deployer
        );
        cfg.committeeAutomationOperator = _envAddressAliasOr(
            "COMMITTEE_ORACLE_AUTOMATION_ADDRESS", "COMMITTEE_V2_AUTOMATION_ADDRESS", deployer
        );
        cfg.committeeChallengeOperator = _envAddressAliasOr(
            "COMMITTEE_ORACLE_CHALLENGE_ADDRESS", "COMMITTEE_V2_CHALLENGE_ADDRESS", deployer
        );
        cfg.committeeJurorManager = _envAddressAliasOr(
            "COMMITTEE_ORACLE_JUROR_MANAGER_ADDRESS", "COMMITTEE_V2_JUROR_MANAGER_ADDRESS", deployer
        );
        cfg.committeeJurorApprover = _envAddressAliasOr(
            "COMMITTEE_ORACLE_JUROR_APPROVER_ADDRESS", "COMMITTEE_V2_JUROR_APPROVER_ADDRESS", deployer
        );
        cfg.committeeConfig = _protocolConfig();
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg = _loadCommonConfig(deployer);
        cfg = _applyIdentityModeConfig(cfg);
    }

    function _applyIdentityModeConfig(DeployConfig memory cfg) internal view virtual returns (DeployConfig memory);

    function _validateConfig(DeployConfig memory cfg) internal pure {
        require(cfg.identityRegistry != address(0), "identity registry zero");
        require(cfg.agentSigner != address(0), "agent signer zero");
        require(cfg.evoCoreAdmin != address(0), "evo core admin zero");
        require(cfg.predictionManager != address(0), "prediction manager zero");
        require(cfg.committeeAdmin != address(0), "committee admin zero");
        require(cfg.committeeGovernor != address(0), "committee governor zero");
        require(cfg.committeeTimelockExecutor != address(0), "committee timelock executor zero");
        require(cfg.committeeEmergencyGuardian != address(0), "committee emergency guardian zero");
        require(cfg.committeeAutomationOperator != address(0), "committee automation operator zero");
        require(cfg.committeeChallengeOperator != address(0), "committee challenge operator zero");
        require(cfg.committeeJurorManager != address(0), "committee juror manager zero");
        require(cfg.committeeJurorApprover != address(0), "committee juror approver zero");
        require(cfg.predictionResultPublisher != address(0), "result publisher zero");
        require(cfg.predictionSnapshotPublisher != address(0), "snapshot publisher zero");
        require(cfg.committeeAdmin != address(0), "committee admin zero");
        require(cfg.committeeGovernor != address(0), "committee governor zero");
        require(cfg.committeeTimelockExecutor != address(0), "committee timelock zero");
        require(cfg.committeeEmergencyGuardian != address(0), "committee emergency guardian zero");
        require(cfg.committeeConfig.primaryCount > 0, "committee primary zero");
        require(cfg.committeeConfig.quorum > 0, "committee quorum zero");
        require(
            cfg.committeeConfig.quorum <= cfg.committeeConfig.primaryCount + cfg.committeeConfig.reserveCount,
            "committee quorum too high"
        );
        require(cfg.committeeConfig.selectionDelayBlocks > 0, "committee selection delay zero");
        require(cfg.committeeConfig.voteWindow > 0, "committee vote window zero");
        require(cfg.committeeConfig.challengeWindow > 0, "committee challenge window zero");
        require(cfg.committeeConfig.maxEpochs > 0, "committee max epochs zero");
    }

    function _validateRuntimeConfig(DeployConfig memory cfg) internal view {
        require(cfg.identityRegistry.code.length > 0, "external identity no code");
        if (cfg.strictRoleConfiguration) {
            require(vm.envExists("EVO_CORE_ADMIN_ADDRESS"), "missing EVO_CORE_ADMIN_ADDRESS");
            require(vm.envExists("AGENT_SIGNER_ADDRESS"), "missing AGENT_SIGNER_ADDRESS");
            require(vm.envExists("PREDICTION_MANAGER_ADDRESS"), "missing PREDICTION_MANAGER_ADDRESS");
            require(
                vm.envExists("PREDICTION_RESULT_PUBLISHER_ADDRESS"), "missing PREDICTION_RESULT_PUBLISHER_ADDRESS"
            );
            require(
                vm.envExists("PREDICTION_SNAPSHOT_PUBLISHER_ADDRESS"),
                "missing PREDICTION_SNAPSHOT_PUBLISHER_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_ADMIN_ADDRESS", "COMMITTEE_V2_ADMIN_ADDRESS"),
                "missing COMMITTEE_ORACLE_ADMIN_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_GOVERNOR_ADDRESS", "COMMITTEE_V2_GOVERNOR_ADDRESS"),
                "missing COMMITTEE_ORACLE_GOVERNOR_ADDRESS"
            );
            require(
                _envExistsEither(
                    "COMMITTEE_ORACLE_TIMELOCK_EXECUTOR_ADDRESS", "COMMITTEE_V2_TIMELOCK_EXECUTOR_ADDRESS"
                ),
                "missing COMMITTEE_ORACLE_TIMELOCK_EXECUTOR_ADDRESS"
            );
            require(
                _envExistsEither(
                    "COMMITTEE_ORACLE_EMERGENCY_GUARDIAN_ADDRESS", "COMMITTEE_V2_EMERGENCY_GUARDIAN_ADDRESS"
                ),
                "missing COMMITTEE_ORACLE_EMERGENCY_GUARDIAN_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_AUTOMATION_ADDRESS", "COMMITTEE_V2_AUTOMATION_ADDRESS"),
                "missing COMMITTEE_ORACLE_AUTOMATION_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_CHALLENGE_ADDRESS", "COMMITTEE_V2_CHALLENGE_ADDRESS"),
                "missing COMMITTEE_ORACLE_CHALLENGE_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_JUROR_MANAGER_ADDRESS", "COMMITTEE_V2_JUROR_MANAGER_ADDRESS"),
                "missing COMMITTEE_ORACLE_JUROR_MANAGER_ADDRESS"
            );
            require(
                _envExistsEither("COMMITTEE_ORACLE_JUROR_APPROVER_ADDRESS", "COMMITTEE_V2_JUROR_APPROVER_ADDRESS"),
                "missing COMMITTEE_ORACLE_JUROR_APPROVER_ADDRESS"
            );
        }
    }

    function run()
        external
        virtual
        returns (
            address agentAddress,
            address evolutionRegistryAddress,
            address committeeOracleAddress,
            address predictionAddress,
            address userActionRouterAddress
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        DeployConfig memory cfg = _loadConfig(deployer);
        _validateConfig(cfg);
        _validateRuntimeConfig(cfg);

        console.log("Deploying Evo full stack...");
        console.log("  Chain ID             :", block.chainid);
        console.log("  Deployer             :", cfg.deployer);
        console.log("  Identity registry    :", cfg.identityRegistry);
        console.log("  Strict role config   :", cfg.strictRoleConfiguration);
        console.log("  Evo core admin       :", cfg.evoCoreAdmin);
        console.log("  Agent signer         :", cfg.agentSigner);
        console.log("  Prediction manager   :", cfg.predictionManager);
        console.log("  Result publisher     :", cfg.predictionResultPublisher);
        console.log("  Snapshot publisher   :", cfg.predictionSnapshotPublisher);
        console.log("  Committee admin      :", cfg.committeeAdmin);
        console.log("  Committee governor   :", cfg.committeeGovernor);
        console.log("  Committee timelock   :", cfg.committeeTimelockExecutor);
        console.log("  Committee emergency  :", cfg.committeeEmergencyGuardian);

        vm.startBroadcast(deployerKey);
        DeployArtifacts memory deployed;
        deployed.agent = cfg.identityRegistry;
        {
            EvoBindingRegistry bindingImplementation_ = new EvoBindingRegistry();
            EvoBindingRegistry binding_ = EvoBindingRegistry(
                address(
                    new ERC1967Proxy(
                        address(bindingImplementation_),
                        abi.encodeCall(EvoBindingRegistry.initialize, (deployed.agent))
                    )
                )
            );
            deployed.bindingImplementation = address(bindingImplementation_);
            deployed.binding = address(binding_);
            EvoBindingRegistry(deployed.binding).initializeV2(deployed.agent);
        }
        {
            EvoEvolutionRegistry evolutionRegistryImplementation_ = new EvoEvolutionRegistry();
            EvoEvolutionRegistry evolutionRegistry_ = EvoEvolutionRegistry(
                address(
                    new ERC1967Proxy(
                        address(evolutionRegistryImplementation_),
                        abi.encodeCall(EvoEvolutionRegistry.initialize, (deployed.agent, deployed.binding, cfg.agentSigner))
                    )
                )
            );
            deployed.evolutionRegistryImplementation = address(evolutionRegistryImplementation_);
            deployed.evolutionRegistry = address(evolutionRegistry_);
        }
        EvoBindingRegistry(deployed.binding).setSelfHostedRegistrationEnabled(false);
        {
            EvoCommitteeOracle committeeImplementation_ = new EvoCommitteeOracle();
            EvoCommitteeOracle committee_ = EvoCommitteeOracle(
                address(
                    new ERC1967Proxy(
                        address(committeeImplementation_),
                        abi.encodeCall(
                            EvoCommitteeOracle.initialize,
                            (
                                deployed.agent,
                                cfg.committeeAdmin,
                                cfg.committeeGovernor,
                                cfg.committeeTimelockExecutor,
                                cfg.committeeEmergencyGuardian,
                                cfg.committeeAutomationOperator,
                                cfg.committeeChallengeOperator,
                                cfg.committeeJurorManager,
                                cfg.committeeJurorApprover,
                                cfg.committeeConfig
                            )
                        )
                    )
                )
            );
            deployed.committeeImplementation = address(committeeImplementation_);
            deployed.committee = address(committee_);
        }
        {
            EvoPredictionRegistry predictionImplementation_ = new EvoPredictionRegistry();
            EvoPredictionRegistry prediction_ = EvoPredictionRegistry(
                address(
                    new ERC1967Proxy(
                        address(predictionImplementation_),
                        abi.encodeCall(
                            EvoPredictionRegistry.initialize,
                            (
                                deployed.agent,
                                deployed.binding,
                                cfg.predictionManager,
                                cfg.predictionResultPublisher,
                                cfg.predictionSnapshotPublisher
                            )
                        )
                    )
                )
            );
            deployed.predictionImplementation = address(predictionImplementation_);
            deployed.prediction = address(prediction_);
        }
        {
            EvoUserActionRouter routerImplementation_ = new EvoUserActionRouter();
            EvoUserActionRouter router_ = EvoUserActionRouter(
                address(
                    new ERC1967Proxy(
                        address(routerImplementation_),
                        abi.encodeCall(EvoUserActionRouter.initialize, (deployed.evolutionRegistry, deployed.prediction))
                    )
                )
            );
            deployed.routerImplementation = address(routerImplementation_);
            deployed.router = address(router_);
        }
        EvoBindingRegistry(deployed.binding).setTrustedRouter(deployed.router);
        EvoEvolutionRegistry(deployed.evolutionRegistry).setTrustedRouter(deployed.router);
        EvoPredictionRegistry(deployed.prediction).setTrustedRouter(deployed.router);
        EvoUserActionRouter(deployed.router).setBindingRegistry(deployed.binding);
        _handoffCoreAdminRoles(cfg, deployed);
        vm.stopBroadcast();

        agentAddress = deployed.agent;
        evolutionRegistryAddress = deployed.evolutionRegistry;
        committeeOracleAddress = deployed.committee;
        predictionAddress = deployed.prediction;
        userActionRouterAddress = deployed.router;

        console.log("========================================");
        console.log("  Full stack deployed");
        console.log("========================================");
        console.log("  External identity      :", agentAddress);
        console.log("  EvoBindingRegistry impl:", deployed.bindingImplementation);
        console.log("  EvoBindingRegistry     :", deployed.binding);
        console.log("  EvoEvolutionRegistry impl:", deployed.evolutionRegistryImplementation);
        console.log("  EvoEvolutionRegistry     :", evolutionRegistryAddress);
        console.log("  CommitteeOracle impl      :", deployed.committeeImplementation);
        console.log("  CommitteeOracle           :", committeeOracleAddress);
        console.log("  PredictionRegistry impl   :", deployed.predictionImplementation);
        console.log("  PredictionRegistry        :", predictionAddress);
        console.log("  EvoUserActionRouter impl  :", deployed.routerImplementation);
        console.log("  EvoUserActionRouter       :", userActionRouterAddress);
        console.log("========================================");
    }

    function _handoffCoreAdminRoles(DeployConfig memory cfg, DeployArtifacts memory deployed) internal {
        if (cfg.evoCoreAdmin == cfg.deployer) return;

        EvoBindingRegistry binding = EvoBindingRegistry(deployed.binding);
        binding.grantRole(binding.ADMIN_ROLE(), cfg.evoCoreAdmin);
        binding.grantRole(binding.PAUSER_ROLE(), cfg.evoCoreAdmin);
        binding.renounceRole(binding.PAUSER_ROLE(), cfg.deployer);
        binding.renounceRole(binding.ADMIN_ROLE(), cfg.deployer);

        EvoEvolutionRegistry evolution = EvoEvolutionRegistry(deployed.evolutionRegistry);
        evolution.grantRole(evolution.ADMIN_ROLE(), cfg.evoCoreAdmin);
        evolution.grantRole(evolution.SIGNER_ADMIN_ROLE(), cfg.evoCoreAdmin);
        evolution.grantRole(evolution.PAUSER_ROLE(), cfg.evoCoreAdmin);
        evolution.renounceRole(evolution.PAUSER_ROLE(), cfg.deployer);
        evolution.renounceRole(evolution.SIGNER_ADMIN_ROLE(), cfg.deployer);
        evolution.renounceRole(evolution.ADMIN_ROLE(), cfg.deployer);

        EvoPredictionRegistry prediction = EvoPredictionRegistry(deployed.prediction);
        prediction.grantRole(prediction.ADMIN_ROLE(), cfg.evoCoreAdmin);
        prediction.renounceRole(prediction.ADMIN_ROLE(), cfg.deployer);

        EvoUserActionRouter router = EvoUserActionRouter(deployed.router);
        router.grantRole(router.ADMIN_ROLE(), cfg.evoCoreAdmin);
        router.grantRole(router.ROUTE_ADMIN_ROLE(), cfg.evoCoreAdmin);
        router.grantRole(router.PAUSER_ROLE(), cfg.evoCoreAdmin);
        router.renounceRole(router.PAUSER_ROLE(), cfg.deployer);
        router.renounceRole(router.ROUTE_ADMIN_ROLE(), cfg.deployer);
        router.renounceRole(router.ADMIN_ROLE(), cfg.deployer);
    }
}
