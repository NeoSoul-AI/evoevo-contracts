// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IEvoBindingRegistryIdentity} from "./interfaces/IEvoBindingRegistryIdentity.sol";
import {IAgentOwnership} from "./interfaces/IAgentOwnership.sol";

/// @title EvoBindingRegistry
/// @notice On-chain binding layer that links an ERC-8004 agent identity to Evo's product surface.
/// @dev This contract intentionally does not model platform verification or future member registries.
///      It only proves that a given agent has been bound into Evo by its current controller.
contract EvoBindingRegistry is Initializable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    struct BindingRecord {
        address boundOwner;
        address evoAccount;
        bytes32 evoUserIdHash;
        uint64 boundAt;
        uint64 updatedAt;
        bool active;
    }

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // @dev `identityRegistry` is the LEGACY self-hosted identity registry. All bare-`agentId`
    //      state in `_bindings` is, by definition, data for this legacy registry.
    IEvoBindingRegistryIdentity public identityRegistry;
    address public trustedRouter;
    /// @dev Deprecated since the self-hosted registration entry points were removed.
    ///      Kept only as a storage placeholder (UUPS append-only layout) — do not remove or reorder.
    bool public selfHostedRegistrationEnabled;

    mapping(uint256 => BindingRecord) private _bindings;

    // --- Dual-registry support (appended; UUPS append-only storage) ---
    // The public ERC-8004 identity registry used for new registrations. Recorded for inspection.
    address public publicIdentityRegistry;
    // Allowlist of identity registries that Evo write paths will operate against.
    mapping(address => bool) public supportedIdentityRegistries;
    // Binding records keyed by (identityRegistry, agentId) for NON-legacy registries.
    // Legacy-registry bindings remain in `_bindings`.
    mapping(address => mapping(uint256 => BindingRecord)) private _bindingsByRegistry;
    uint256[47] private __gap;

    event TrustedRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event PauseUpdated(bool paused);
    event IdentityRegistrySupportUpdated(address indexed identityRegistry, bool supported);
    // @dev Legacy events. Retained for historical-log ABI decoding; no longer emitted (V2 events replace them).
    event AgentBound(
        uint256 indexed agentId,
        address indexed boundOwner,
        address indexed evoAccount,
        bytes32 evoUserIdHash,
        address actor
    );
    event AgentUnbound(
        uint256 indexed agentId, address indexed previousBoundOwner, address indexed previousEvoAccount, address actor
    );
    event AgentBoundV2(
        address indexed identityRegistry,
        uint256 indexed agentId,
        address indexed boundOwner,
        address evoAccount,
        bytes32 evoUserIdHash,
        address actor
    );
    event AgentUnboundV2(
        address indexed identityRegistry,
        uint256 indexed agentId,
        address previousBoundOwner,
        address previousEvoAccount,
        address actor
    );

    error ZeroAddress();
    error Unauthorized();
    error InvalidRouter(address router);
    error UnsupportedIdentityRegistry(address identityRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address identityRegistry_) external initializer {
        if (identityRegistry_ == address(0)) revert ZeroAddress();

        __Pausable_init();
        __AccessControl_init();

        identityRegistry = IEvoBindingRegistryIdentity(identityRegistry_);
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());
    }

    /// @notice Enable dual-registry support: record the public identity registry and seed the
    ///         allowlist with both the legacy and public registries. For single-registry chains
    ///         (e.g. BSC) pass the existing registry; the allowlist then has one entry and the
    ///         V2 paths alias the legacy `_bindings` store.
    function initializeV2(address publicIdentityRegistry_) external onlyRole(ADMIN_ROLE) reinitializer(2) {
        if (publicIdentityRegistry_ == address(0)) revert ZeroAddress();
        if (publicIdentityRegistry_.code.length == 0) revert UnsupportedIdentityRegistry(publicIdentityRegistry_);

        publicIdentityRegistry = publicIdentityRegistry_;

        address legacy = address(identityRegistry);
        supportedIdentityRegistries[legacy] = true;
        emit IdentityRegistrySupportUpdated(legacy, true);

        if (!supportedIdentityRegistries[publicIdentityRegistry_]) {
            supportedIdentityRegistries[publicIdentityRegistry_] = true;
            emit IdentityRegistrySupportUpdated(publicIdentityRegistry_, true);
        }
    }

    function setIdentityRegistrySupported(address identityRegistry_, bool supported) external onlyRole(ADMIN_ROLE) {
        if (identityRegistry_ == address(0)) revert ZeroAddress();
        if (supported && identityRegistry_.code.length == 0) revert UnsupportedIdentityRegistry(identityRegistry_);
        supportedIdentityRegistries[identityRegistry_] = supported;
        emit IdentityRegistrySupportUpdated(identityRegistry_, supported);
    }

    function isSupportedIdentityRegistry(address identityRegistry_) external view returns (bool) {
        return supportedIdentityRegistries[identityRegistry_];
    }

    /// @notice The legacy self-hosted identity registry (the registry backing `_bindings`).
    function legacyIdentityRegistry() external view returns (address) {
        return address(identityRegistry);
    }

    function setTrustedRouter(address newRouter) external onlyRole(ADMIN_ROLE) {
        if (newRouter != address(0) && newRouter.code.length == 0) revert InvalidRouter(newRouter);
        emit TrustedRouterUpdated(trustedRouter, newRouter);
        trustedRouter = newRouter;
    }

    function setPaused(bool isPaused) external onlyRole(PAUSER_ROLE) {
        if (isPaused) {
            if (!paused()) _pause();
        } else {
            if (paused()) _unpause();
        }
        emit PauseUpdated(isPaused);
    }

    // --- Legacy single-registry entrypoints (delegate to the legacy identity registry) ---

    function bindExistingAgent(uint256 agentId, address evoAccount, bytes32 evoUserIdHash) external whenNotPaused {
        address legacy = address(identityRegistry);
        _requireAgentControllerV2(_msgSender(), legacy, agentId);
        _bindV2(legacy, agentId, IAgentOwnership(legacy).ownerOf(agentId), evoAccount, evoUserIdHash, _msgSender());
    }

    function bindExistingAgentFor(address actor, uint256 agentId, address evoAccount, bytes32 evoUserIdHash)
        external
        whenNotPaused
    {
        if (_msgSender() != trustedRouter) revert Unauthorized();
        address legacy = address(identityRegistry);
        _requireAgentControllerV2(actor, legacy, agentId);
        _bindV2(legacy, agentId, IAgentOwnership(legacy).ownerOf(agentId), evoAccount, evoUserIdHash, actor);
    }

    function unbind(uint256 agentId) external whenNotPaused {
        address legacy = address(identityRegistry);
        _requireAgentControllerV2(_msgSender(), legacy, agentId);
        _unbindV2(legacy, agentId, _msgSender());
    }

    function forceUnbind(uint256 agentId) external onlyRole(ADMIN_ROLE) {
        _unbindV2(address(identityRegistry), agentId, _msgSender());
    }

    function getBinding(uint256 agentId)
        external
        view
        returns (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            uint256 boundAt,
            uint256 updatedAt,
            bool active,
            bool ownerStillMatches
        )
    {
        return _getBinding(address(identityRegistry), agentId);
    }

    function isEvoBound(uint256 agentId) external view returns (bool) {
        return _isBindingCurrentlyValidV2(address(identityRegistry), agentId);
    }

    // --- Dual-registry (V2) entrypoints ---

    function bindExistingAgentV2(address identityRegistry_, uint256 agentId, address evoAccount, bytes32 evoUserIdHash)
        external
        whenNotPaused
    {
        _requireSupportedRegistry(identityRegistry_);
        _requireAgentControllerV2(_msgSender(), identityRegistry_, agentId);
        _bindV2(
            identityRegistry_,
            agentId,
            IAgentOwnership(identityRegistry_).ownerOf(agentId),
            evoAccount,
            evoUserIdHash,
            _msgSender()
        );
    }

    function bindExistingAgentForV2(
        address actor,
        address identityRegistry_,
        uint256 agentId,
        address evoAccount,
        bytes32 evoUserIdHash
    ) external whenNotPaused {
        if (_msgSender() != trustedRouter) revert Unauthorized();
        _requireSupportedRegistry(identityRegistry_);
        _requireAgentControllerV2(actor, identityRegistry_, agentId);
        _bindV2(
            identityRegistry_,
            agentId,
            IAgentOwnership(identityRegistry_).ownerOf(agentId),
            evoAccount,
            evoUserIdHash,
            actor
        );
    }

    function unbindV2(address identityRegistry_, uint256 agentId) external whenNotPaused {
        _requireSupportedRegistry(identityRegistry_);
        _requireAgentControllerV2(_msgSender(), identityRegistry_, agentId);
        _unbindV2(identityRegistry_, agentId, _msgSender());
    }

    /// @dev Admin escape hatch; intentionally does not require the registry to still be allowlisted,
    ///      so a de-supported registry's stale bindings can be cleaned up.
    function forceUnbindV2(address identityRegistry_, uint256 agentId) external onlyRole(ADMIN_ROLE) {
        _unbindV2(identityRegistry_, agentId, _msgSender());
    }

    function isEvoBoundV2(address identityRegistry_, uint256 agentId) external view returns (bool) {
        return _isBindingCurrentlyValidV2(identityRegistry_, agentId);
    }

    function getBindingV2(address identityRegistry_, uint256 agentId)
        external
        view
        returns (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            uint256 boundAt,
            uint256 updatedAt,
            bool active,
            bool ownerStillMatches
        )
    {
        return _getBinding(identityRegistry_, agentId);
    }

    // --- Internal (dual-registry aware) ---

    /// @dev Returns the storage slot for a binding record. Legacy registry data lives in `_bindings`;
    ///      every other registry lives in `_bindingsByRegistry[reg]`.
    function _bindingRef(address reg, uint256 agentId) private view returns (BindingRecord storage) {
        if (reg == address(identityRegistry)) {
            return _bindings[agentId];
        }
        return _bindingsByRegistry[reg][agentId];
    }

    function _getBinding(address reg, uint256 agentId)
        private
        view
        returns (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            uint256 boundAt,
            uint256 updatedAt,
            bool active,
            bool ownerStillMatches
        )
    {
        BindingRecord storage bindingRecord = _bindingRef(reg, agentId);
        bool stillMatches = bindingRecord.boundOwner == IAgentOwnership(reg).ownerOf(agentId);
        return (
            bindingRecord.boundOwner,
            bindingRecord.evoAccount,
            bindingRecord.evoUserIdHash,
            bindingRecord.boundAt,
            bindingRecord.updatedAt,
            bindingRecord.active,
            stillMatches
        );
    }

    function _bindV2(
        address reg,
        uint256 agentId,
        address currentOwner,
        address evoAccount,
        bytes32 evoUserIdHash,
        address actor
    ) internal {
        address normalizedEvoAccount = evoAccount == address(0) ? currentOwner : evoAccount;
        BindingRecord storage bindingRecord = _bindingRef(reg, agentId);
        uint64 currentTimestamp = uint64(block.timestamp);

        if (bindingRecord.boundAt == 0) {
            bindingRecord.boundAt = currentTimestamp;
        }

        bindingRecord.boundOwner = currentOwner;
        bindingRecord.evoAccount = normalizedEvoAccount;
        bindingRecord.evoUserIdHash = evoUserIdHash;
        bindingRecord.updatedAt = currentTimestamp;
        bindingRecord.active = true;

        emit AgentBoundV2(reg, agentId, currentOwner, normalizedEvoAccount, evoUserIdHash, actor);
    }

    function _unbindV2(address reg, uint256 agentId, address actor) internal {
        BindingRecord storage bindingRecord = _bindingRef(reg, agentId);
        address previousBoundOwner = bindingRecord.boundOwner;
        address previousEvoAccount = bindingRecord.evoAccount;

        if (reg == address(identityRegistry)) {
            delete _bindings[agentId];
        } else {
            delete _bindingsByRegistry[reg][agentId];
        }

        emit AgentUnboundV2(reg, agentId, previousBoundOwner, previousEvoAccount, actor);
    }

    function _isBindingCurrentlyValidV2(address reg, uint256 agentId) internal view returns (bool) {
        BindingRecord storage bindingRecord = _bindingRef(reg, agentId);
        if (!bindingRecord.active) {
            return false;
        }
        return bindingRecord.boundOwner == IAgentOwnership(reg).ownerOf(agentId);
    }

    function _requireAgentControllerV2(address operator, address reg, uint256 agentId) internal view {
        IAgentOwnership idr = IAgentOwnership(reg);
        address tokenOwner = idr.ownerOf(agentId);
        if (operator != tokenOwner && idr.getApproved(agentId) != operator && !idr.isApprovedForAll(tokenOwner, operator))
        {
            revert Unauthorized();
        }
    }

    function _requireSupportedRegistry(address reg) internal view {
        if (!supportedIdentityRegistries[reg]) revert UnsupportedIdentityRegistry(reg);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
