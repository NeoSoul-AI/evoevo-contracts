// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAgentOwnership} from "./interfaces/IAgentOwnership.sol";
import {IEvoBindingStatusRegistry} from "./interfaces/IEvoBindingStatusRegistry.sol";

/// @title EvoPredictionRegistry
/// @notice Thin prediction settlement registry that stores only:
/// - prediction metadata
/// - final oracle result summary
/// - final judgement snapshot summary
/// and emits owner judgement events instead of storing per-agent judgement state.
contract EvoPredictionRegistry is PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    enum ResolutionKind {
        Unresolved,
        Resolved,
        Void,
        Invalid
    }

    enum FinalStatus {
        Unresolved,
        Finalized,
        EmergencyResolved
    }

    struct PredictionMeta {
        uint64 openedAt;
        uint64 closeAt;
        uint32 optionCount;
        bytes32 topicHash;
        bytes32 contentHash;
        bytes32 optionsHash;
    }

    struct PredictionResultSummary {
        bool resolved;
        uint8 resolutionKind;
        uint8 winningOptionIndex;
        uint8 finalStatus;
        uint32 finalEpoch;
        uint64 finalizedAt;
        bytes32 resultHash;
    }

    struct JudgementSnapshotSummary {
        bool published;
        uint64 snapshotBlock;
        uint64 snapshottedAt;
        uint32 participantCount;
        bytes32 judgementRoot;
        bytes32 judgementCountsHash;
    }

    struct PredictionSettlementSummary {
        bool bound;
        uint64 boundAt;
        bytes32 settlementHash;
    }

    struct LatestJudgement {
        bool exists;
        bool agree;
        uint64 actionAt;
        uint256 opinionId;
    }

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant RESULT_PUBLISHER_ROLE = keccak256("RESULT_PUBLISHER_ROLE");
    bytes32 public constant SNAPSHOT_PUBLISHER_ROLE = keccak256("SNAPSHOT_PUBLISHER_ROLE");

    uint256 public nextPredictionId;
    // @dev `nft` is the LEGACY identity registry. Bare-tokenId judgement state in
    //      `_latestJudgements` is, by definition, data for this legacy registry.
    IAgentOwnership public nft;
    IEvoBindingStatusRegistry public bindingRegistry;

    mapping(uint256 => PredictionMeta) private _predictionMeta;
    mapping(uint256 => PredictionResultSummary) private _predictionResults;
    mapping(uint256 => JudgementSnapshotSummary) private _judgementSnapshots;
    mapping(uint256 => PredictionSettlementSummary) private _predictionSettlements;
    mapping(uint256 => mapping(uint256 => LatestJudgement)) private _latestJudgements;
    mapping(uint256 => mapping(uint256 => bool)) private _predictionOpinionLinks;
    mapping(uint256 => uint256) private _predictionOpinionLinkCounts;
    address public trustedRouter;

    // --- Dual-registry support (appended; UUPS append-only storage) ---
    // Latest judgement keyed by (predictionId, identityRegistry, agentTokenId) for NON-legacy registries.
    mapping(uint256 => mapping(address => mapping(uint256 => LatestJudgement))) private _latestJudgementsByRegistry;
    uint256[49] private __gap;

    event PredictionOpened(
        uint256 indexed predictionId,
        bytes32 indexed topicHash,
        uint64 openedAt,
        uint64 closeAt,
        uint32 optionCount,
        bytes32 contentHash,
        bytes32 optionsHash
    );

    // @dev Legacy event. Retained for historical-log ABI decoding; no longer emitted (V2 replaces it).
    event PredictionJudgementRecorded(
        uint256 indexed predictionId,
        uint256 indexed agentTokenId,
        address indexed actor,
        bool agree,
        uint256 opinionId,
        uint64 actionAt
    );

    event PredictionJudgementRecordedV2(
        uint256 indexed predictionId,
        address indexed identityRegistry,
        uint256 indexed agentTokenId,
        address actor,
        bool agree,
        uint256 opinionId,
        uint64 actionAt
    );

    event PredictionResultSummaryPublished(
        uint256 indexed predictionId,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint8 finalStatus,
        uint32 finalEpoch,
        uint64 finalizedAt,
        bytes32 resultHash
    );

    event JudgementSnapshotPublished(
        uint256 indexed predictionId,
        bytes32 indexed judgementRoot,
        uint32 participantCount,
        bytes32 judgementCountsHash,
        uint64 snapshotBlock,
        uint64 snapshottedAt
    );

    event PredictionSettlementBound(
        uint256 indexed predictionId,
        bytes32 indexed resultHash,
        bytes32 indexed judgementRoot,
        bytes32 settlementHash,
        uint64 boundAt
    );
    event PredictionOpinionLinkUpdated(uint256 indexed predictionId, uint256 indexed opinionId, bool linked);

    event ManagerUpdated(address indexed manager, bool enabled);
    event ResultPublisherUpdated(address indexed publisher, bool enabled);
    event SnapshotPublisherUpdated(address indexed publisher, bool enabled);
    event BindingRegistryUpdated(address indexed bindingRegistry);
    event TrustedRouterUpdated(address indexed router);
    event PauseUpdated(bool paused);

    error ZeroAddress();
    error InvalidNFTContract(address nftAddress);
    error InvalidTopicHash();
    error InvalidContentHash();
    error InvalidCloseTime(uint256 closeAt, uint256 currentTimestamp);
    error InvalidOptionCount(uint32 optionCount);
    error InvalidOptionsHash();
    error PredictionNotFound(uint256 predictionId);
    error PredictionClosed(uint256 closeAt, uint256 currentTimestamp);
    error PredictionNotClosed(uint256 closeAt, uint256 currentTimestamp);
    error PredictionAlreadyResolved(uint256 predictionId);
    error PredictionAlreadyBound(uint256 predictionId);
    error SnapshotAlreadyPublished(uint256 predictionId);
    error InvalidAgentTokenId();
    error InvalidOpinionId();
    error Unauthorized();
    error InvalidResolutionKind();
    error InvalidFinalStatus();
    error InvalidWinningOptionIndex(uint8 winningOptionIndex, uint32 optionCount);
    error InvalidResultHash();
    error ResultSummaryUnavailable(uint256 predictionId);
    error SnapshotUnavailable(uint256 predictionId);
    error AgentNotBound(uint256 agentTokenId);
    error InvalidBindingRegistry(address bindingRegistry);
    error InvalidRouter(address router);
    error OpinionNotLinkedToPrediction(uint256 predictionId, uint256 opinionId);
    error JudgementAlreadyRecorded(uint256 predictionId, uint256 agentTokenId, uint256 opinionId, bool agree);
    error UnsupportedIdentityRegistry(address identityRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address nftAddress,
        address bindingRegistryAddress,
        address initialManager,
        address initialResultPublisher,
        address initialSnapshotPublisher
    ) external initializer {
        if (
            nftAddress == address(0) || bindingRegistryAddress == address(0) || initialManager == address(0)
                || initialResultPublisher == address(0) || initialSnapshotPublisher == address(0)
        ) revert ZeroAddress();
        if (nftAddress.code.length == 0) revert InvalidNFTContract(nftAddress);
        if (bindingRegistryAddress.code.length == 0) revert InvalidBindingRegistry(bindingRegistryAddress);

        __Pausable_init();
        __AccessControl_init();

        nft = IAgentOwnership(nftAddress);
        bindingRegistry = IEvoBindingStatusRegistry(bindingRegistryAddress);
        nextPredictionId = 1;

        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(MANAGER_ROLE, initialManager);
        _grantRole(RESULT_PUBLISHER_ROLE, initialResultPublisher);
        _grantRole(SNAPSHOT_PUBLISHER_ROLE, initialSnapshotPublisher);
    }

    function setManager(address manager, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (manager == address(0)) revert ZeroAddress();
        if (enabled) {
            _grantRole(MANAGER_ROLE, manager);
        } else {
            _revokeRole(MANAGER_ROLE, manager);
        }
        emit ManagerUpdated(manager, enabled);
    }

    function setResultPublisher(address publisher, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (publisher == address(0)) revert ZeroAddress();
        if (enabled) {
            _grantRole(RESULT_PUBLISHER_ROLE, publisher);
        } else {
            _revokeRole(RESULT_PUBLISHER_ROLE, publisher);
        }
        emit ResultPublisherUpdated(publisher, enabled);
    }

    function setSnapshotPublisher(address publisher, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (publisher == address(0)) revert ZeroAddress();
        if (enabled) {
            _grantRole(SNAPSHOT_PUBLISHER_ROLE, publisher);
        } else {
            _revokeRole(SNAPSHOT_PUBLISHER_ROLE, publisher);
        }
        emit SnapshotPublisherUpdated(publisher, enabled);
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

    function setPaused(bool isPaused) external onlyRole(ADMIN_ROLE) {
        if (isPaused) {
            if (!paused()) _pause();
        } else {
            if (paused()) _unpause();
        }
        emit PauseUpdated(isPaused);
    }

    function openPrediction(
        bytes32 topicHash,
        bytes32 contentHash,
        uint64 closeAt,
        uint32 optionCount,
        bytes32 optionsHash
    ) external onlyRole(MANAGER_ROLE) whenNotPaused returns (uint256 predictionId) {
        if (topicHash == bytes32(0)) revert InvalidTopicHash();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (closeAt <= block.timestamp) revert InvalidCloseTime(closeAt, block.timestamp);
        if (optionCount == 0) revert InvalidOptionCount(optionCount);
        if (optionsHash == bytes32(0)) revert InvalidOptionsHash();

        predictionId = nextPredictionId++;
        _predictionMeta[predictionId] = PredictionMeta({
            openedAt: uint64(block.timestamp),
            closeAt: closeAt,
            optionCount: optionCount,
            topicHash: topicHash,
            contentHash: contentHash,
            optionsHash: optionsHash
        });

        emit PredictionOpened(
            predictionId, topicHash, uint64(block.timestamp), closeAt, optionCount, contentHash, optionsHash
        );
    }

    function setPredictionOpinionLink(uint256 predictionId, uint256 opinionId, bool linked)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        if (opinionId == 0) revert InvalidOpinionId();

        bool current = _predictionOpinionLinks[predictionId][opinionId];
        if (current == linked) return;

        _predictionOpinionLinks[predictionId][opinionId] = linked;
        if (linked) {
            _predictionOpinionLinkCounts[predictionId] += 1;
        } else {
            _predictionOpinionLinkCounts[predictionId] -= 1;
        }
        emit PredictionOpinionLinkUpdated(predictionId, opinionId, linked);
    }

    function setPredictionOpinionLinks(uint256 predictionId, uint256[] calldata opinionIds, bool linked)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);

        uint256 length = opinionIds.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 opinionId = opinionIds[i];
            if (opinionId == 0) revert InvalidOpinionId();

            bool current = _predictionOpinionLinks[predictionId][opinionId];
            if (current == linked) continue;

            _predictionOpinionLinks[predictionId][opinionId] = linked;
            if (linked) {
                _predictionOpinionLinkCounts[predictionId] += 1;
            } else {
                _predictionOpinionLinkCounts[predictionId] -= 1;
            }
            emit PredictionOpinionLinkUpdated(predictionId, opinionId, linked);
        }
    }

    function recordJudgement(uint256 predictionId, uint256 agentTokenId, bool agree, uint256 opinionId)
        external
        whenNotPaused
    {
        _recordJudgementV2(_msgSender(), predictionId, address(nft), agentTokenId, agree, opinionId);
    }

    function recordJudgementFor(
        address actor,
        uint256 predictionId,
        uint256 agentTokenId,
        bool agree,
        uint256 opinionId
    ) external onlyTrustedRouter whenNotPaused {
        _recordJudgementV2(actor, predictionId, address(nft), agentTokenId, agree, opinionId);
    }

    function recordJudgementV2(
        uint256 predictionId,
        address identityRegistry,
        uint256 agentTokenId,
        bool agree,
        uint256 opinionId
    ) external whenNotPaused {
        _recordJudgementV2(_msgSender(), predictionId, identityRegistry, agentTokenId, agree, opinionId);
    }

    function recordJudgementForV2(
        address actor,
        uint256 predictionId,
        address identityRegistry,
        uint256 agentTokenId,
        bool agree,
        uint256 opinionId
    ) external onlyTrustedRouter whenNotPaused {
        _recordJudgementV2(actor, predictionId, identityRegistry, agentTokenId, agree, opinionId);
    }

    function _recordJudgementV2(
        address actor,
        uint256 predictionId,
        address identityRegistry,
        uint256 agentTokenId,
        bool agree,
        uint256 opinionId
    ) internal {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        if (_predictionResults[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);
        if (block.timestamp >= meta.closeAt) revert PredictionClosed(meta.closeAt, block.timestamp);
        if (agentTokenId == 0) revert InvalidAgentTokenId();
        if (opinionId == 0) revert InvalidOpinionId();
        if (_predictionOpinionLinkCounts[predictionId] > 0 && !_predictionOpinionLinks[predictionId][opinionId]) {
            revert OpinionNotLinkedToPrediction(predictionId, opinionId);
        }
        // The legacy registry (`address(nft)`) is the contract's own configured identity registry and
        // is implicitly trusted; it resolves binding via the legacy `isEvoBound`. Any other registry
        // must be allowlisted (checked BEFORE any external call into the caller-supplied registry).
        bool isLegacy = identityRegistry == address(nft);
        if (!isLegacy && !bindingRegistry.isSupportedIdentityRegistry(identityRegistry)) {
            revert UnsupportedIdentityRegistry(identityRegistry);
        }
        bool bound = isLegacy
            ? bindingRegistry.isEvoBound(agentTokenId)
            : bindingRegistry.isEvoBoundV2(identityRegistry, agentTokenId);
        if (!bound) revert AgentNotBound(agentTokenId);
        if (!_isApprovedOrOwnerOn(identityRegistry, actor, agentTokenId)) revert Unauthorized();

        LatestJudgement storage latest = _judgementRef(predictionId, identityRegistry, agentTokenId);
        if (latest.exists && latest.opinionId == opinionId && latest.agree == agree) {
            revert JudgementAlreadyRecorded(predictionId, agentTokenId, opinionId, agree);
        }

        latest.exists = true;
        latest.agree = agree;
        latest.actionAt = uint64(block.timestamp);
        latest.opinionId = opinionId;

        emit PredictionJudgementRecordedV2(
            predictionId, identityRegistry, agentTokenId, actor, agree, opinionId, uint64(block.timestamp)
        );
    }

    function _judgementRef(uint256 predictionId, address identityRegistry, uint256 agentTokenId)
        private
        view
        returns (LatestJudgement storage)
    {
        if (identityRegistry == address(nft)) {
            return _latestJudgements[predictionId][agentTokenId];
        }
        return _latestJudgementsByRegistry[predictionId][identityRegistry][agentTokenId];
    }

    function publishOracleResultSummary(
        uint256 predictionId,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint8 finalStatus,
        uint32 finalEpoch,
        uint64 finalizedAt,
        bytes32 resultHash
    ) external onlyRole(RESULT_PUBLISHER_ROLE) whenNotPaused {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        if (_predictionResults[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);
        if (block.timestamp < meta.closeAt) revert PredictionNotClosed(meta.closeAt, block.timestamp);
        if (resultHash == bytes32(0)) revert InvalidResultHash();

        ResolutionKind decodedKind = ResolutionKind(resolutionKind);
        FinalStatus decodedStatus = FinalStatus(finalStatus);
        if (decodedKind == ResolutionKind.Unresolved) revert InvalidResolutionKind();
        if (decodedStatus == FinalStatus.Unresolved) revert InvalidFinalStatus();
        if (decodedKind == ResolutionKind.Resolved) {
            if (winningOptionIndex == 0 || winningOptionIndex > meta.optionCount) {
                revert InvalidWinningOptionIndex(winningOptionIndex, meta.optionCount);
            }
        } else if (winningOptionIndex != 0) {
            revert InvalidWinningOptionIndex(winningOptionIndex, meta.optionCount);
        }

        _predictionResults[predictionId] = PredictionResultSummary({
            resolved: true,
            resolutionKind: resolutionKind,
            winningOptionIndex: winningOptionIndex,
            finalStatus: finalStatus,
            finalEpoch: finalEpoch,
            finalizedAt: finalizedAt,
            resultHash: resultHash
        });

        emit PredictionResultSummaryPublished(
            predictionId, resolutionKind, winningOptionIndex, finalStatus, finalEpoch, finalizedAt, resultHash
        );
    }

    function publishJudgementSnapshot(
        uint256 predictionId,
        uint64 snapshotBlock,
        uint32 participantCount,
        bytes32 judgementRoot,
        bytes32 judgementCountsHash
    ) external onlyRole(SNAPSHOT_PUBLISHER_ROLE) whenNotPaused {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        if (block.timestamp < meta.closeAt) revert PredictionNotClosed(meta.closeAt, block.timestamp);
        if (_judgementSnapshots[predictionId].published) revert SnapshotAlreadyPublished(predictionId);

        _judgementSnapshots[predictionId] = JudgementSnapshotSummary({
            published: true,
            snapshotBlock: snapshotBlock,
            snapshottedAt: uint64(block.timestamp),
            participantCount: participantCount,
            judgementRoot: judgementRoot,
            judgementCountsHash: judgementCountsHash
        });

        emit JudgementSnapshotPublished(
            predictionId, judgementRoot, participantCount, judgementCountsHash, snapshotBlock, uint64(block.timestamp)
        );
    }

    function bindPredictionSettlementSummary(uint256 predictionId)
        external
        whenNotPaused
        returns (bytes32 settlementHash)
    {
        PredictionMeta storage meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);

        PredictionResultSummary storage result = _predictionResults[predictionId];
        if (!result.resolved) revert ResultSummaryUnavailable(predictionId);

        JudgementSnapshotSummary storage snapshot = _judgementSnapshots[predictionId];
        if (!snapshot.published) revert SnapshotUnavailable(predictionId);

        PredictionSettlementSummary storage settlement = _predictionSettlements[predictionId];
        if (settlement.bound) revert PredictionAlreadyBound(predictionId);

        settlementHash = keccak256(
            abi.encode(
                predictionId,
                result.resultHash,
                snapshot.judgementRoot,
                snapshot.participantCount,
                snapshot.judgementCountsHash,
                result.finalEpoch,
                result.finalStatus
            )
        );

        settlement.bound = true;
        settlement.boundAt = uint64(block.timestamp);
        settlement.settlementHash = settlementHash;

        emit PredictionSettlementBound(
            predictionId, result.resultHash, snapshot.judgementRoot, settlementHash, uint64(block.timestamp)
        );
    }

    function getPredictionMeta(uint256 predictionId) external view returns (PredictionMeta memory) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return meta;
    }

    function getPredictionResultSummary(uint256 predictionId) external view returns (PredictionResultSummary memory) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _predictionResults[predictionId];
    }

    function getLatestJudgement(uint256 predictionId, uint256 agentTokenId) external view returns (LatestJudgement memory) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _latestJudgements[predictionId][agentTokenId];
    }

    function getLatestJudgementV2(uint256 predictionId, address identityRegistry, uint256 agentTokenId)
        external
        view
        returns (LatestJudgement memory)
    {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _judgementRef(predictionId, identityRegistry, agentTokenId);
    }

    function isPredictionOpinionLinked(uint256 predictionId, uint256 opinionId) external view returns (bool) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _predictionOpinionLinks[predictionId][opinionId];
    }

    function enforcesPredictionOpinionLinks(uint256 predictionId) external view returns (bool) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _predictionOpinionLinkCounts[predictionId] > 0;
    }

    function getJudgementSnapshotSummary(uint256 predictionId)
        external
        view
        returns (JudgementSnapshotSummary memory)
    {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _judgementSnapshots[predictionId];
    }

    function getPredictionSettlementSummary(uint256 predictionId)
        external
        view
        returns (PredictionSettlementSummary memory)
    {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        if (meta.openedAt == 0) revert PredictionNotFound(predictionId);
        return _predictionSettlements[predictionId];
    }

    function isOpen(uint256 predictionId) external view returns (bool) {
        PredictionMeta memory meta = _predictionMeta[predictionId];
        return meta.openedAt != 0 && !_predictionResults[predictionId].resolved && block.timestamp < meta.closeAt;
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
