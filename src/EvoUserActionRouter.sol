// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC8004IdentityRegistry} from "./interfaces/IERC8004IdentityRegistry.sol";
import {EvoBindingRegistry} from "./EvoBindingRegistry.sol";
import {EvoEvolutionRegistry} from "./EvoEvolutionRegistry.sol";
import {EvoPredictionRegistry} from "./EvoPredictionRegistry.sol";

/// @title EvoUserActionRouter
/// @notice Main user-facing on-chain entrypoint for wallet actions. The router preserves the
/// original actor when forwarding to downstream registries so ownership and signature checks
/// remain bound to the wallet that initiated the action.
contract EvoUserActionRouter is PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROUTE_ADMIN_ROLE = keccak256("ROUTE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    EvoBindingRegistry public bindingRegistry;
    EvoEvolutionRegistry public evolutionRegistry;
    EvoPredictionRegistry public ownerJudgementRegistry;

    event BindingRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event EvolutionRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event OwnerJudgementRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event PauseUpdated(bool paused);

    error ZeroAddress();
    error InvalidTarget(address target);
    error BindingRegistryNotConfigured();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address evolutionRegistryAddress, address ownerJudgementRegistryAddress) external initializer {
        __Pausable_init();
        __AccessControl_init();

        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(ROUTE_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());

        _setEvolutionRegistry(evolutionRegistryAddress);
        _setOwnerJudgementRegistry(ownerJudgementRegistryAddress);
    }

    function setEvolutionRegistry(address newRegistry) external onlyRole(ROUTE_ADMIN_ROLE) {
        _setEvolutionRegistry(newRegistry);
    }

    function setBindingRegistry(address newRegistry) external onlyRole(ROUTE_ADMIN_ROLE) {
        _setBindingRegistry(newRegistry);
    }

    function setOwnerJudgementRegistry(address newRegistry) external onlyRole(ROUTE_ADMIN_ROLE) {
        _setOwnerJudgementRegistry(newRegistry);
    }

    function setPaused(bool isPaused) external onlyRole(PAUSER_ROLE) {
        if (isPaused) {
            if (!paused()) _pause();
        } else {
            if (paused()) _unpause();
        }
        emit PauseUpdated(isPaused);
    }

    function registerAndBind(
        address evoAccount,
        bytes32 evoUserIdHash,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external whenNotPaused returns (uint256 agentId) {
        if (address(bindingRegistry) == address(0)) revert BindingRegistryNotConfigured();
        agentId = bindingRegistry.registerAndBindFor(_msgSender(), evoAccount, evoUserIdHash, agentURI, metadata);
    }

    function bindExistingAgent(uint256 agentId, address evoAccount, bytes32 evoUserIdHash) external whenNotPaused {
        if (address(bindingRegistry) == address(0)) revert BindingRegistryNotConfigured();
        bindingRegistry.bindExistingAgentFor(_msgSender(), agentId, evoAccount, evoUserIdHash);
    }

    function intakeReasoning(
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        evolutionRegistry.intakeReasoningFor(
            _msgSender(),
            tokenId,
            sourceOpinionId,
            reasoningHash,
            opinionHash,
            newMemoryRoot,
            nonce,
            deadline,
            signature
        );
    }

    function judge(uint256 predictionId, uint256 agentTokenId, bool agree, uint256 opinionId) external whenNotPaused {
        ownerJudgementRegistry.recordJudgementFor(_msgSender(), predictionId, agentTokenId, agree, opinionId);
    }

    // --- Dual-registry (V2) forwarders ---

    function bindExistingAgentV2(
        address identityRegistry,
        uint256 agentId,
        address evoAccount,
        bytes32 evoUserIdHash
    ) external whenNotPaused {
        if (address(bindingRegistry) == address(0)) revert BindingRegistryNotConfigured();
        bindingRegistry.bindExistingAgentForV2(_msgSender(), identityRegistry, agentId, evoAccount, evoUserIdHash);
    }

    function intakeReasoningV2(
        address identityRegistry,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        evolutionRegistry.intakeReasoningForV2(
            _msgSender(),
            identityRegistry,
            tokenId,
            sourceOpinionId,
            reasoningHash,
            opinionHash,
            newMemoryRoot,
            nonce,
            deadline,
            signature
        );
    }

    function judgeV2(
        uint256 predictionId,
        address identityRegistry,
        uint256 agentTokenId,
        bool agree,
        uint256 opinionId
    ) external whenNotPaused {
        ownerJudgementRegistry.recordJudgementForV2(
            _msgSender(), predictionId, identityRegistry, agentTokenId, agree, opinionId
        );
    }

    function _setEvolutionRegistry(address newRegistry) internal {
        _validateTarget(newRegistry);
        address oldRegistry = address(evolutionRegistry);
        evolutionRegistry = EvoEvolutionRegistry(newRegistry);
        emit EvolutionRegistryUpdated(oldRegistry, newRegistry);
    }

    function _setBindingRegistry(address newRegistry) internal {
        _validateTarget(newRegistry);
        address oldRegistry = address(bindingRegistry);
        bindingRegistry = EvoBindingRegistry(newRegistry);
        emit BindingRegistryUpdated(oldRegistry, newRegistry);
    }

    function _setOwnerJudgementRegistry(address newRegistry) internal {
        _validateTarget(newRegistry);
        address oldRegistry = address(ownerJudgementRegistry);
        ownerJudgementRegistry = EvoPredictionRegistry(newRegistry);
        emit OwnerJudgementRegistryUpdated(oldRegistry, newRegistry);
    }

    function _validateTarget(address target) internal view {
        if (target == address(0)) revert ZeroAddress();
        if (target.code.length == 0) revert InvalidTarget(target);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
