// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IAgentOwnership} from "./interfaces/IAgentOwnership.sol";
import {IEvoBindingStatusRegistry} from "./interfaces/IEvoBindingStatusRegistry.sol";

/// @title EvoEvolutionRegistry
/// @notice Evolution commitment layer for Evo-managed agent actions.
contract EvoEvolutionRegistry is PausableUpgradeable, EIP712Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    struct IntakeReasoningRequest {
        uint256 tokenId;
        uint256 sourceOpinionId;
        bytes32 reasoningHash;
        bytes32 opinionHash;
        bytes32 newMemoryRoot;
        uint256 nonce;
        uint256 deadline;
    }

    struct IntakeReasoningRequestV2 {
        address identityRegistry;
        uint256 tokenId;
        uint256 sourceOpinionId;
        bytes32 reasoningHash;
        bytes32 opinionHash;
        bytes32 newMemoryRoot;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IAgentOwnership public nft;
    IEvoBindingStatusRegistry public bindingRegistry;

    bytes32 public constant INTAKE_REASONING_TYPEHASH = keccak256(
        "IntakeReasoningRequest(address updater,uint256 tokenId,uint256 sourceOpinionId,bytes32 reasoningHash,bytes32 opinionHash,bytes32 newMemoryRoot,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant INTAKE_REASONING_TYPEHASH_V2 = keccak256(
        "IntakeReasoningRequest(address updater,address identityRegistry,uint256 tokenId,uint256 sourceOpinionId,bytes32 reasoningHash,bytes32 opinionHash,bytes32 newMemoryRoot,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // @dev Legacy bare-tokenId nonces. By definition these belong to the legacy registry (`address(nft)`).
    mapping(uint256 => uint256) public evolutionNonces;
    address public trustedRouter;

    // --- Dual-registry support (appended; UUPS append-only storage) ---
    // Evolution nonces keyed by (identityRegistry, tokenId) for NON-legacy registries.
    mapping(address => mapping(uint256 => uint256)) private _evolutionNoncesByRegistry;
    uint256[49] private __gap;

    event SignerUpdated(address indexed signer, bool enabled);
    event BindingRegistryUpdated(address indexed bindingRegistry);
    event TrustedRouterUpdated(address indexed router);
    event PauseUpdated(bool paused);
    // @dev Legacy event. Retained for historical-log ABI decoding; no longer emitted (V2 replaces it).
    event ReasoningIntakeCommitted(
        uint256 indexed tokenId,
        address indexed updater,
        uint256 indexed sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        address signer,
        uint256 nonce
    );
    event ReasoningIntakeCommittedV2(
        address indexed identityRegistry,
        uint256 indexed tokenId,
        address indexed updater,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        address signer,
        uint256 nonce
    );

    error Unauthorized();
    error UnsupportedIdentityRegistry(address identityRegistry);
    error ZeroAddress();
    error InvalidOpinionId();
    error InvalidReasoningHash();
    error InvalidOpinionHash();
    error InvalidMemoryRoot();
    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
    error InvalidNonce(uint256 expected, uint256 actual);
    error AgentNotBound(uint256 tokenId);
    error InvalidBindingRegistry(address bindingRegistry);
    error InvalidRouter(address router);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address nftAddress, address bindingRegistryAddress, address initialSigner) external initializer {
        if (nftAddress == address(0) || bindingRegistryAddress == address(0) || initialSigner == address(0)) {
            revert ZeroAddress();
        }
        if (bindingRegistryAddress.code.length == 0) revert InvalidBindingRegistry(bindingRegistryAddress);

        __Pausable_init();
        __EIP712_init("EvoEvolutionRegistry", "1");
        __AccessControl_init();

        nft = IAgentOwnership(nftAddress);
        bindingRegistry = IEvoBindingStatusRegistry(bindingRegistryAddress);
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(SIGNER_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());
        _grantRole(SIGNER_ROLE, initialSigner);
    }

    function setSigner(address signer, bool enabled) external onlyRole(SIGNER_ADMIN_ROLE) {
        if (signer == address(0)) revert ZeroAddress();
        if (enabled) {
            _grantRole(SIGNER_ROLE, signer);
        } else {
            _revokeRole(SIGNER_ROLE, signer);
        }
        emit SignerUpdated(signer, enabled);
    }

    function setTrustedRouter(address router) external onlyRole(ADMIN_ROLE) {
        if (router != address(0) && router.code.length == 0) revert InvalidRouter(router);
        trustedRouter = router;
        emit TrustedRouterUpdated(router);
    }

    function setBindingRegistry(address nextBindingRegistry) external onlyRole(ADMIN_ROLE) {
        if (nextBindingRegistry == address(0)) revert ZeroAddress();
        if (nextBindingRegistry.code.length == 0) revert InvalidBindingRegistry(nextBindingRegistry);
        bindingRegistry = IEvoBindingStatusRegistry(nextBindingRegistry);
        emit BindingRegistryUpdated(nextBindingRegistry);
    }

    function isSigner(address account) public view returns (bool) {
        return hasRole(SIGNER_ROLE, account);
    }

    function setPaused(bool isPaused) external onlyRole(PAUSER_ROLE) {
        if (isPaused) {
            if (!paused()) _pause();
        } else {
            if (paused()) _unpause();
        }
        emit PauseUpdated(isPaused);
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
        _intakeReasoning(
            _msgSender(),
            IntakeReasoningRequest({
                tokenId: tokenId,
                sourceOpinionId: sourceOpinionId,
                reasoningHash: reasoningHash,
                opinionHash: opinionHash,
                newMemoryRoot: newMemoryRoot,
                nonce: nonce,
                deadline: deadline
            }),
            signature
        );
    }

    function intakeReasoningFor(
        address actor,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyTrustedRouter whenNotPaused {
        _intakeReasoning(
            actor,
            IntakeReasoningRequest({
                tokenId: tokenId,
                sourceOpinionId: sourceOpinionId,
                reasoningHash: reasoningHash,
                opinionHash: opinionHash,
                newMemoryRoot: newMemoryRoot,
                nonce: nonce,
                deadline: deadline
            }),
            signature
        );
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
        _intakeReasoningV2(
            _msgSender(),
            IntakeReasoningRequestV2({
                identityRegistry: identityRegistry,
                tokenId: tokenId,
                sourceOpinionId: sourceOpinionId,
                reasoningHash: reasoningHash,
                opinionHash: opinionHash,
                newMemoryRoot: newMemoryRoot,
                nonce: nonce,
                deadline: deadline
            }),
            signature
        );
    }

    function intakeReasoningForV2(
        address actor,
        address identityRegistry,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyTrustedRouter whenNotPaused {
        _intakeReasoningV2(
            actor,
            IntakeReasoningRequestV2({
                identityRegistry: identityRegistry,
                tokenId: tokenId,
                sourceOpinionId: sourceOpinionId,
                reasoningHash: reasoningHash,
                opinionHash: opinionHash,
                newMemoryRoot: newMemoryRoot,
                nonce: nonce,
                deadline: deadline
            }),
            signature
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Evolution nonce for an (identityRegistry, tokenId). Legacy registry resolves to `evolutionNonces`.
    function getEvolutionNonce(address identityRegistry, uint256 tokenId) public view returns (uint256) {
        if (identityRegistry == address(nft)) {
            return evolutionNonces[tokenId];
        }
        return _evolutionNoncesByRegistry[identityRegistry][tokenId];
    }

    function hashIntakeReasoningRequest(
        address updater,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                INTAKE_REASONING_TYPEHASH,
                updater,
                tokenId,
                sourceOpinionId,
                reasoningHash,
                opinionHash,
                newMemoryRoot,
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function hashIntakeReasoningRequestV2(
        address updater,
        address identityRegistry,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                INTAKE_REASONING_TYPEHASH_V2,
                updater,
                identityRegistry,
                tokenId,
                sourceOpinionId,
                reasoningHash,
                opinionHash,
                newMemoryRoot,
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _intakeReasoning(
        address actor,
        IntakeReasoningRequest memory request,
        bytes calldata signature
    ) internal {
        if (request.sourceOpinionId == 0) revert InvalidOpinionId();
        if (request.reasoningHash == bytes32(0)) revert InvalidReasoningHash();
        if (request.opinionHash == bytes32(0)) revert InvalidOpinionHash();
        if (request.newMemoryRoot == bytes32(0)) revert InvalidMemoryRoot();
        if (block.timestamp > request.deadline) revert SignatureExpired(request.deadline, block.timestamp);
        if (!bindingRegistry.isEvoBound(request.tokenId)) revert AgentNotBound(request.tokenId);
        if (!_isApprovedOrOwner(actor, request.tokenId)) revert Unauthorized();

        uint256 expectedNonce = evolutionNonces[request.tokenId];
        if (request.nonce != expectedNonce) revert InvalidNonce(expectedNonce, request.nonce);

        bytes32 digest = hashIntakeReasoningRequest(
            actor,
            request.tokenId,
            request.sourceOpinionId,
            request.reasoningHash,
            request.opinionHash,
            request.newMemoryRoot,
            request.nonce,
            request.deadline
        );
        (address signer, ECDSA.RecoverError recoverError,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (recoverError != ECDSA.RecoverError.NoError || !hasRole(SIGNER_ROLE, signer)) revert InvalidSignature();

        evolutionNonces[request.tokenId] = expectedNonce + 1;
        // Legacy entrypoint emits the V2 event with the legacy registry address.
        emit ReasoningIntakeCommittedV2(
            address(nft),
            request.tokenId,
            actor,
            request.sourceOpinionId,
            request.reasoningHash,
            request.opinionHash,
            request.newMemoryRoot,
            signer,
            request.nonce
        );
    }

    function _intakeReasoningV2(
        address actor,
        IntakeReasoningRequestV2 memory request,
        bytes calldata signature
    ) internal {
        if (request.sourceOpinionId == 0) revert InvalidOpinionId();
        if (request.reasoningHash == bytes32(0)) revert InvalidReasoningHash();
        if (request.opinionHash == bytes32(0)) revert InvalidOpinionHash();
        if (request.newMemoryRoot == bytes32(0)) revert InvalidMemoryRoot();
        if (block.timestamp > request.deadline) revert SignatureExpired(request.deadline, block.timestamp);
        // Allowlist check MUST precede any external call into the caller-supplied registry.
        if (!bindingRegistry.isSupportedIdentityRegistry(request.identityRegistry)) {
            revert UnsupportedIdentityRegistry(request.identityRegistry);
        }
        if (!bindingRegistry.isEvoBoundV2(request.identityRegistry, request.tokenId)) {
            revert AgentNotBound(request.tokenId);
        }
        if (!_isApprovedOrOwnerOn(request.identityRegistry, actor, request.tokenId)) revert Unauthorized();

        uint256 expectedNonce = getEvolutionNonce(request.identityRegistry, request.tokenId);
        if (request.nonce != expectedNonce) revert InvalidNonce(expectedNonce, request.nonce);

        bytes32 digest = hashIntakeReasoningRequestV2(
            actor,
            request.identityRegistry,
            request.tokenId,
            request.sourceOpinionId,
            request.reasoningHash,
            request.opinionHash,
            request.newMemoryRoot,
            request.nonce,
            request.deadline
        );
        (address signer, ECDSA.RecoverError recoverError,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (recoverError != ECDSA.RecoverError.NoError || !hasRole(SIGNER_ROLE, signer)) revert InvalidSignature();

        _bumpEvolutionNonce(request.identityRegistry, request.tokenId, expectedNonce);
        emit ReasoningIntakeCommittedV2(
            request.identityRegistry,
            request.tokenId,
            actor,
            request.sourceOpinionId,
            request.reasoningHash,
            request.opinionHash,
            request.newMemoryRoot,
            signer,
            request.nonce
        );
    }

    function _bumpEvolutionNonce(address identityRegistry, uint256 tokenId, uint256 expectedNonce) internal {
        if (identityRegistry == address(nft)) {
            evolutionNonces[tokenId] = expectedNonce + 1;
        } else {
            _evolutionNoncesByRegistry[identityRegistry][tokenId] = expectedNonce + 1;
        }
    }

    function _isApprovedOrOwner(address operator, uint256 tokenId) internal view returns (bool) {
        return _isApprovedOrOwnerOn(address(nft), operator, tokenId);
    }

    function _isApprovedOrOwnerOn(address identityRegistry, address operator, uint256 tokenId)
        internal
        view
        returns (bool)
    {
        IAgentOwnership idr = IAgentOwnership(identityRegistry);
        address tokenOwner = idr.ownerOf(tokenId);
        return operator == tokenOwner || idr.getApproved(tokenId) == operator || idr.isApprovedForAll(tokenOwner, operator);
    }

    modifier onlyTrustedRouter() {
        if (_msgSender() != trustedRouter) revert Unauthorized();
        _;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
