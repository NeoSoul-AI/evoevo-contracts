// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {IAgentOwnership} from "./interfaces/IAgentOwnership.sol";
import {IPredictionOracle} from "./interfaces/IPredictionOracle.sol";

/// @title EvoCommitteeOracle
/// @notice Mainline decentralized committee oracle with juror pool, verifiable selection,
///         evidence-hash-bound proposals, pending finality, and challenge support.
contract EvoCommitteeOracle is AccessControlUpgradeable, EIP712Upgradeable, IPredictionOracle, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant TIMELOCK_EXECUTOR_ROLE = keccak256("TIMELOCK_EXECUTOR_ROLE");
    bytes32 public constant EMERGENCY_GUARDIAN_ROLE = keccak256("EMERGENCY_GUARDIAN_ROLE");
    bytes32 public constant AUTOMATION_ROLE = keccak256("AUTOMATION_ROLE");
    bytes32 public constant CHALLENGE_ROLE = keccak256("CHALLENGE_ROLE");
    bytes32 public constant JUROR_MANAGER_ROLE = keccak256("JUROR_MANAGER_ROLE");
    bytes32 public constant JUROR_APPROVER_ROLE = keccak256("JUROR_APPROVER_ROLE");
    bytes32 public constant REGISTER_JUROR_TYPEHASH =
        keccak256("RegisterJuror(address owner,uint256 memberTokenId,bytes32 metadataHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_JUROR_ACTIVE_TYPEHASH =
        keccak256("SetJurorActive(address owner,uint256 memberTokenId,bool active,uint256 nonce,uint256 deadline)");

    uint8 public constant OUTCOME_YES = 1;
    uint8 public constant OUTCOME_NO = 2;
    uint8 public constant OUTCOME_INVALID = 3;
    uint8 public constant RESOLUTION_RESOLVED = 1;
    uint8 public constant RESOLUTION_VOID = 2;
    uint8 public constant RESOLUTION_INVALID = 3;

    enum PredictionStatus {
        Unassigned,
        SelectionPending,
        Voting,
        PendingFinality,
        Challenged,
        Finalized,
        Stalled,
        EmergencyResolved
    }

    struct ProtocolConfig {
        uint16 primaryCount;
        uint16 reserveCount;
        uint16 quorum;
        uint64 selectionDelayBlocks;
        uint64 voteWindow;
        uint64 graceWindow;
        uint64 challengeWindow;
        uint96 challengeBond;
        bytes32 policyHash;
        uint16 maxEpochs;
    }

    struct Juror {
        bool registered;
        bool active;
        uint64 registeredAt;
        uint64 cooldownUntil;
        int64 reputationScore;
        bytes32 metadataHash;
    }

    struct PredictionAssignment {
        PredictionStatus status;
        uint64 selectionRequestedBlock;
        uint64 selectionTargetBlock;
        bytes32 selectionSeed;
        uint16 quorum;
        uint64 assignedAt;
        uint64 voteWindow;
        uint64 graceWindow;
        uint64 challengeWindow;
        bytes32 pendingProposalHash;
        uint64 pendingOpenedAt;
        uint64 challengeDeadline;
        uint16 currentEpoch;
        uint64 epochStartedAt;
    }

    struct ProposalTally {
        bool exists;
        uint8 resolutionKind;
        uint8 winningOptionIndex;
        uint16 approvalCount;
        uint256 yesVotes;
        uint256 noVotes;
        uint256[] optionVotes;
        bytes32 evidenceBundleHash;
    }

    struct Challenge {
        bool exists;
        address challenger;
        bytes32 evidenceBundleHash;
        bytes32 reasonCode;
        uint96 bondAmount;
        uint64 openedAt;
    }

    struct Result {
        bool resolved;
        bool emergency;
        uint8 resolutionKind;
        uint8 winningOptionIndex;
        uint8 outcome;
        uint256 yesVotes;
        uint256 noVotes;
        uint256[] optionVotes;
        uint256 finalizedAt;
        address finalizer;
        bytes32 proposalHash;
        bytes32 evidenceBundleHash;
    }

    IAgentOwnership public nft;
    ProtocolConfig public protocolConfig;
    mapping(uint256 => uint256) public jurorRegisterNonces;
    mapping(uint256 => uint256) public jurorActivationNonces;

    uint256[] private _jurorTokenIds;
    mapping(uint256 => Juror) private _jurors;

    mapping(uint256 => PredictionAssignment) private _predictionAssignments;
    mapping(uint256 => uint256[]) private _predictionPrimaryMembers;
    mapping(uint256 => uint256[]) private _predictionReserveMembers;
    mapping(uint256 => mapping(uint256 => bool)) private _isPredictionPrimaryMember;
    mapping(uint256 => mapping(uint256 => bool)) private _isPredictionReserveMember;
    mapping(uint256 => mapping(uint256 => bytes32)) private _memberSubmissionHashes;
    mapping(uint256 => mapping(bytes32 => ProposalTally)) private _proposalTallies;
    mapping(uint256 => Challenge) private _challenges;
    mapping(uint256 => Result) private _results;

    // --- v2 appended storage (UUPS append-only; do not reorder) ---
    EnumerableSet.UintSet private _activeJurorTokenIds;
    uint256 public maxActiveJurors; // 0 = uncapped

    mapping(uint256 => mapping(bytes32 => uint16)) private _outcomeApprovalCounts;
    mapping(uint256 => mapping(bytes32 => bytes32)) private _outcomeCanonicalProposal;

    address public treasury;
    mapping(address => uint256) public pendingWithdrawals;

    event ProtocolConfigUpdated(
        uint16 primaryCount,
        uint16 reserveCount,
        uint16 quorum,
        uint64 selectionDelayBlocks,
        uint64 voteWindow,
        uint64 graceWindow,
        uint64 challengeWindow,
        uint96 challengeBond,
        uint16 maxEpochs,
        bytes32 indexed policyHash
    );
    event JurorRegistered(uint256 indexed memberTokenId, address indexed owner, bytes32 indexed metadataHash);
    event JurorActiveUpdated(uint256 indexed memberTokenId, bool active);
    event JurorPenaltyApplied(uint256 indexed memberTokenId, uint64 cooldownUntil, int64 reputationScore);
    event SelectionRequested(uint256 indexed predictionId, uint256 indexed targetBlock, uint16 primaryCount, uint16 reserveCount);
    event PredictionEpochSelectionRequested(
        uint256 indexed predictionId,
        uint16 indexed epoch,
        uint256 indexed targetBlock,
        uint16 primaryCount,
        uint16 reserveCount
    );
    event PredictionAssignmentFinalized(
        uint256 indexed predictionId, bytes32 indexed selectionSeed, uint256 assignedAt, uint256[] primaryMembers, uint256[] reserveMembers
    );
    event PredictionEpochSelectionFinalized(
        uint256 indexed predictionId,
        uint16 indexed epoch,
        bytes32 indexed selectionSeed,
        uint256 assignedAt,
        uint256[] primaryMembers,
        uint256[] reserveMembers
    );
    event PredictionEpochRolled(
        uint256 indexed predictionId,
        uint16 indexed previousEpoch,
        uint16 indexed nextEpoch,
        bytes32 reasonCode,
        uint256 rolledAt
    );
    event JurorResolutionSubmitted(
        uint256 indexed predictionId,
        uint256 indexed memberTokenId,
        bytes32 indexed proposalHash,
        bytes32 evidenceBundleHash,
        uint16 approvalCount,
        bool reserveMember
    );
    event PendingFinalityOpened(
        uint256 indexed predictionId,
        bytes32 indexed proposalHash,
        bytes32 indexed evidenceBundleHash,
        uint256 challengeDeadline
    );
    event PredictionChallenged(
        uint256 indexed predictionId,
        address indexed challenger,
        bytes32 indexed challengerEvidenceBundleHash,
        bytes32 reasonCode,
        uint96 bondAmount
    );
    event PredictionResolvedByCommittee(
        uint256 indexed predictionId,
        bytes32 indexed proposalHash,
        bytes32 indexed evidenceBundleHash,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256 finalizedAt,
        address finalizer
    );
    event PredictionStalled(uint256 indexed predictionId, uint8 indexed previousStatus, uint256 markedAt);
    event MaxActiveJurorsUpdated(uint256 maxActiveJurors);
    event PredictionResolvedByEmergency(
        uint256 indexed predictionId,
        bytes32 indexed proposalHash,
        bytes32 indexed evidenceBundleHash,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256 finalizedAt,
        address finalizer
    );
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ChallengeBondSettled(uint256 indexed predictionId, address indexed recipient, uint96 amount, bool challengeUpheld);
    event BondWithdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error InvalidAgentContract(address agentContract);
    error InvalidPredictionId();
    error InvalidProtocolConfig();
    error PredictionAlreadyResolved(uint256 predictionId);
    error UnexpectedPredictionStatus(uint256 predictionId, uint8 status);
    error SelectionTargetBlockNotReached(uint256 predictionId, uint256 currentBlock, uint256 targetBlock);
    error SelectionEntropyUnavailable(uint256 predictionId, uint256 targetBlock);
    error SelectionEntropyStillAvailable(uint256 predictionId, uint256 currentBlock, uint256 targetBlock);
    error MaxSelectionEpochsExceeded(uint256 predictionId, uint16 currentEpoch, uint16 maxEpochs);
    error JurorAlreadyRegistered(uint256 memberTokenId);
    error JurorNotRegistered(uint256 memberTokenId);
    error JurorInactive(uint256 memberTokenId);
    error InsufficientEligibleJurors(uint256 requiredCount, uint256 availableCount);
    error Unauthorized();
    error InvalidSignature();
    error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
    error InvalidNonce(uint256 expected, uint256 actual);
    error MemberNotEligible(uint256 predictionId, uint256 memberTokenId);
    error ReserveWindowNotOpen(uint256 predictionId, uint256 currentTimestamp, uint256 reserveWindowOpensAt);
    error SubmissionWindowClosed(uint256 predictionId, uint256 currentTimestamp, uint256 submissionWindowClosesAt);
    error AlreadySubmitted(uint256 predictionId, uint256 memberTokenId);
    error InvalidResolutionKind(uint8 resolutionKind);
    error InvalidWinningOptionIndex(uint8 winningOptionIndex, uint256 optionCount);
    error InvalidOptionVotesLength();
    error ZeroEvidenceBundleHash();
    error ChallengeWindowStillOpen(uint256 predictionId, uint256 currentTimestamp, uint256 challengeDeadline);
    error ChallengeWindowClosed(uint256 predictionId, uint256 currentTimestamp, uint256 challengeDeadline);
    error AlreadyChallenged(uint256 predictionId);
    error ChallengeNotFound(uint256 predictionId);
    error InsufficientChallengeBond(uint256 requiredBond, uint256 actualBond);
    error MaxActiveJurorsReached(uint256 maxActiveJurors);
    error TreasuryNotSet();
    error NothingToWithdraw();
    error WithdrawTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address nftAddress,
        address initialAdmin,
        address initialGovernor,
        address initialTimelockExecutor,
        address initialEmergencyGuardian,
        address initialAutomationOperator,
        address initialChallengeOperator,
        address initialJurorManager,
        address initialJurorApprover,
        ProtocolConfig calldata initialConfig
    ) external initializer {
        if (
            nftAddress == address(0) || initialAdmin == address(0) || initialGovernor == address(0)
                || initialTimelockExecutor == address(0) || initialEmergencyGuardian == address(0)
                || initialAutomationOperator == address(0) || initialChallengeOperator == address(0)
                || initialJurorManager == address(0) || initialJurorApprover == address(0)
        ) revert ZeroAddress();
        if (nftAddress.code.length == 0) revert InvalidAgentContract(nftAddress);

        __AccessControl_init();
        __EIP712_init("EvoCommitteeOracle", "1");

        nft = IAgentOwnership(nftAddress);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(GOVERNOR_ROLE, initialGovernor);
        _grantRole(TIMELOCK_EXECUTOR_ROLE, initialTimelockExecutor);
        _grantRole(EMERGENCY_GUARDIAN_ROLE, initialEmergencyGuardian);
        _grantRole(AUTOMATION_ROLE, initialAutomationOperator);
        _grantRole(CHALLENGE_ROLE, initialChallengeOperator);
        _grantRole(JUROR_MANAGER_ROLE, initialJurorManager);
        _grantRole(JUROR_APPROVER_ROLE, initialJurorApprover);

        _setProtocolConfig(initialConfig);
    }

    /// @notice V2 migration: backfill the active-juror index from pre-upgrade storage.
    ///         Call atomically via upgradeToAndCall. Idempotent set inserts; safe on fresh deployments.
    function initializeV2() external onlyRole(ADMIN_ROLE) reinitializer(2) {
        for (uint256 i = 0; i < _jurorTokenIds.length; i++) {
            uint256 tokenId = _jurorTokenIds[i];
            Juror storage juror = _jurors[tokenId];
            if (juror.registered && juror.active) {
                _activeJurorTokenIds.add(tokenId);
            }
        }
    }

    function setProtocolConfig(ProtocolConfig calldata nextConfig) external onlyRole(GOVERNOR_ROLE) {
        _setProtocolConfig(nextConfig);
    }

    function setMaxActiveJurors(uint256 newMax) external onlyRole(GOVERNOR_ROLE) {
        maxActiveJurors = newMax;
        emit MaxActiveJurorsUpdated(newMax);
    }

    function getActiveJurorTokenIds() external view returns (uint256[] memory) {
        return _activeJurorTokenIds.values();
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawTransferFailed();
        emit BondWithdrawn(msg.sender, amount);
    }

    function registerJuror(uint256 memberTokenId, bytes32 metadataHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        address owner = _assertStrictPredictionTokenOwner(msg.sender, memberTokenId);
        if (_jurors[memberTokenId].registered) revert JurorAlreadyRegistered(memberTokenId);
        _consumeRegisterJurorApproval(owner, memberTokenId, metadataHash, nonce, deadline, signature);

        _jurors[memberTokenId] = Juror({
            registered: true,
            active: false,
            registeredAt: uint64(block.timestamp),
            cooldownUntil: 0,
            reputationScore: 0,
            metadataHash: metadataHash
        });
        _jurorTokenIds.push(memberTokenId);

        emit JurorRegistered(memberTokenId, owner, metadataHash);
    }

    function setJurorActive(uint256 memberTokenId, bool active) external onlyRole(JUROR_MANAGER_ROLE) {
        _setJurorActive(memberTokenId, active);
    }

    function setJurorActiveWithSig(
        uint256 memberTokenId,
        bool active,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        address owner = _assertStrictPredictionTokenOwner(msg.sender, memberTokenId);
        _consumeSetJurorActiveApproval(owner, memberTokenId, active, nonce, deadline, signature);
        _setJurorActive(memberTokenId, active);
    }

    function applyJurorPenalty(uint256 memberTokenId, uint64 cooldownUntil, int64 reputationScoreDelta)
        external
        onlyRole(TIMELOCK_EXECUTOR_ROLE)
    {
        Juror storage juror = _getJurorStorage(memberTokenId);
        if (cooldownUntil > juror.cooldownUntil) {
            juror.cooldownUntil = cooldownUntil;
        }
        juror.reputationScore += reputationScoreDelta;
        emit JurorPenaltyApplied(memberTokenId, juror.cooldownUntil, juror.reputationScore);
    }

    function requestSelectionForPrediction(uint256 predictionId) external onlyRole(AUTOMATION_ROLE) {
        if (predictionId == 0) revert InvalidPredictionId();
        if (_results[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);

        PredictionAssignment storage assignment = _predictionAssignments[predictionId];
        if (assignment.status != PredictionStatus.Unassigned) {
            revert UnexpectedPredictionStatus(predictionId, uint8(assignment.status));
        }

        assignment.currentEpoch = 1;
        _setSelectionPending(predictionId, assignment, assignment.currentEpoch);
    }

    function retrySelectionForPrediction(uint256 predictionId) external onlyRole(AUTOMATION_ROLE) {
        if (predictionId == 0) revert InvalidPredictionId();
        if (_results[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);

        PredictionAssignment storage assignment = _getAssignmentStorage(predictionId, PredictionStatus.SelectionPending);
        if (block.number <= assignment.selectionTargetBlock) {
            revert SelectionTargetBlockNotReached(predictionId, block.number, assignment.selectionTargetBlock);
        }
        if (blockhash(assignment.selectionTargetBlock) != bytes32(0)) {
            revert SelectionEntropyStillAvailable(predictionId, block.number, assignment.selectionTargetBlock);
        }
        if (assignment.currentEpoch >= protocolConfig.maxEpochs) {
            revert MaxSelectionEpochsExceeded(predictionId, assignment.currentEpoch, protocolConfig.maxEpochs);
        }

        uint16 previousEpoch = assignment.currentEpoch;
        uint16 nextEpoch = previousEpoch + 1;
        assignment.currentEpoch = nextEpoch;
        assignment.selectionSeed = bytes32(0);

        emit PredictionEpochRolled(predictionId, previousEpoch, nextEpoch, bytes32("selection_retry"), block.timestamp);
        _setSelectionPending(predictionId, assignment, nextEpoch);
    }

    function finalizeSelectionForPrediction(uint256 predictionId) external onlyRole(AUTOMATION_ROLE) {
        PredictionAssignment storage assignment = _getAssignmentStorage(predictionId, PredictionStatus.SelectionPending);
        if (block.number <= assignment.selectionTargetBlock) {
            revert SelectionTargetBlockNotReached(predictionId, block.number, assignment.selectionTargetBlock);
        }

        bytes32 selectionSeed = blockhash(assignment.selectionTargetBlock);
        if (selectionSeed == bytes32(0)) {
            revert SelectionEntropyUnavailable(predictionId, assignment.selectionTargetBlock);
        }

        uint256 totalCount = uint256(protocolConfig.primaryCount) + uint256(protocolConfig.reserveCount);
        uint256[] memory selectedJurors = _drawJurors(selectionSeed, totalCount);

        assignment.status = PredictionStatus.Voting;
        assignment.selectionSeed = selectionSeed;
        assignment.quorum = protocolConfig.quorum;
        assignment.assignedAt = uint64(block.timestamp);
        assignment.epochStartedAt = uint64(block.timestamp);
        assignment.voteWindow = protocolConfig.voteWindow;
        assignment.graceWindow = protocolConfig.graceWindow;
        assignment.challengeWindow = protocolConfig.challengeWindow;

        for (uint256 i = 0; i < protocolConfig.primaryCount; i++) {
            uint256 tokenId = selectedJurors[i];
            _predictionPrimaryMembers[predictionId].push(tokenId);
            _isPredictionPrimaryMember[predictionId][tokenId] = true;
        }
        for (uint256 i = protocolConfig.primaryCount; i < selectedJurors.length; i++) {
            uint256 tokenId = selectedJurors[i];
            _predictionReserveMembers[predictionId].push(tokenId);
            _isPredictionReserveMember[predictionId][tokenId] = true;
        }

        emit PredictionAssignmentFinalized(
            predictionId, selectionSeed, block.timestamp, _predictionPrimaryMembers[predictionId], _predictionReserveMembers[predictionId]
        );
        emit PredictionEpochSelectionFinalized(
            predictionId,
            assignment.currentEpoch,
            selectionSeed,
            block.timestamp,
            _predictionPrimaryMembers[predictionId],
            _predictionReserveMembers[predictionId]
        );
    }

    function submitJurorResolution(
        uint256 predictionId,
        uint256 memberTokenId,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256[] calldata optionVotes,
        bytes32 evidenceBundleHash
    ) external {
        PredictionAssignment storage assignment = _getAssignmentStorage(predictionId, PredictionStatus.Voting);
        if (_results[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);

        uint256 submissionWindowClosesAt = getSubmissionWindowClosesAt(predictionId);
        if (block.timestamp > submissionWindowClosesAt) {
            revert SubmissionWindowClosed(predictionId, block.timestamp, submissionWindowClosesAt);
        }

        bool reserveMember = _isPredictionReserveMember[predictionId][memberTokenId];
        bool primaryMember = _isPredictionPrimaryMember[predictionId][memberTokenId];
        if (!primaryMember && !reserveMember) revert MemberNotEligible(predictionId, memberTokenId);
        if (reserveMember) {
            uint256 reserveWindowOpensAt = getReserveWindowOpensAt(predictionId);
            if (block.timestamp < reserveWindowOpensAt) {
                revert ReserveWindowNotOpen(predictionId, block.timestamp, reserveWindowOpensAt);
            }
        }
        _assertPredictionTokenOwner(msg.sender, memberTokenId);
        if (_memberSubmissionHashes[predictionId][memberTokenId] != bytes32(0)) {
            revert AlreadySubmitted(predictionId, memberTokenId);
        }

        _validateResolution(resolutionKind, winningOptionIndex, optionVotes, evidenceBundleHash);

        bytes32 proposalHash = hashCommitteeResolution(
            predictionId, resolutionKind, winningOptionIndex, optionVotes, evidenceBundleHash
        );
        _memberSubmissionHashes[predictionId][memberTokenId] = proposalHash;

        ProposalTally storage tally = _proposalTallies[predictionId][proposalHash];
        if (!tally.exists) {
            tally.exists = true;
            tally.resolutionKind = resolutionKind;
            tally.winningOptionIndex = winningOptionIndex;
            tally.yesVotes = _legacyYesVotes(optionVotes);
            tally.noVotes = _legacyNoVotes(optionVotes);
            tally.evidenceBundleHash = evidenceBundleHash;
            for (uint256 i = 0; i < optionVotes.length; i++) {
                tally.optionVotes.push(optionVotes[i]);
            }
        }
        tally.approvalCount += 1;

        bytes32 outcomeKey = _outcomeKey(predictionId, resolutionKind, winningOptionIndex);
        if (_outcomeCanonicalProposal[predictionId][outcomeKey] == bytes32(0)) {
            _outcomeCanonicalProposal[predictionId][outcomeKey] = proposalHash;
        }
        uint16 outcomeCount = _outcomeApprovalCounts[predictionId][outcomeKey] + 1;
        _outcomeApprovalCounts[predictionId][outcomeKey] = outcomeCount;

        emit JurorResolutionSubmitted(
            predictionId, memberTokenId, proposalHash, evidenceBundleHash, tally.approvalCount, reserveMember
        );

        if (outcomeCount >= assignment.quorum) {
            bytes32 canonicalHash = _outcomeCanonicalProposal[predictionId][outcomeKey];
            ProposalTally storage canonicalTally = _proposalTallies[predictionId][canonicalHash];
            assignment.status = PredictionStatus.PendingFinality;
            assignment.pendingProposalHash = canonicalHash;
            assignment.pendingOpenedAt = uint64(block.timestamp);
            assignment.challengeDeadline = uint64(block.timestamp + assignment.challengeWindow);
            emit PendingFinalityOpened(
                predictionId, canonicalHash, canonicalTally.evidenceBundleHash, assignment.challengeDeadline
            );
        }
    }

    function challengePendingResult(uint256 predictionId, bytes32 challengerEvidenceBundleHash, bytes32 reasonCode)
        external
        payable
        onlyRole(CHALLENGE_ROLE)
    {
        PredictionAssignment storage assignment = _getAssignmentStorage(predictionId, PredictionStatus.PendingFinality);
        if (block.timestamp > assignment.challengeDeadline) {
            revert ChallengeWindowClosed(predictionId, block.timestamp, assignment.challengeDeadline);
        }
        if (_challenges[predictionId].exists) revert AlreadyChallenged(predictionId);
        if (challengerEvidenceBundleHash == bytes32(0)) revert ZeroEvidenceBundleHash();
        if (msg.value < protocolConfig.challengeBond) {
            revert InsufficientChallengeBond(protocolConfig.challengeBond, msg.value);
        }

        _challenges[predictionId] = Challenge({
            exists: true,
            challenger: msg.sender,
            evidenceBundleHash: challengerEvidenceBundleHash,
            reasonCode: reasonCode,
            bondAmount: uint96(msg.value),
            openedAt: uint64(block.timestamp)
        });
        assignment.status = PredictionStatus.Challenged;

        emit PredictionChallenged(predictionId, msg.sender, challengerEvidenceBundleHash, reasonCode, uint96(msg.value));
    }

    function finalizePendingResult(uint256 predictionId) external onlyRole(AUTOMATION_ROLE) {
        _finalizePendingResult(predictionId, msg.sender);
    }

    function markPredictionStalled(uint256 predictionId) external onlyRole(AUTOMATION_ROLE) {
        _markPredictionStalled(predictionId);
    }

    function emergencyResolvePrediction(
        uint256 predictionId,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256[] calldata optionVotes,
        bytes32 evidenceBundleHash
    ) external onlyRole(EMERGENCY_GUARDIAN_ROLE) {
        PredictionAssignment storage assignment = _predictionAssignments[predictionId];
        if (
            assignment.status != PredictionStatus.Challenged && assignment.status != PredictionStatus.Stalled
                && assignment.status != PredictionStatus.SelectionPending
        ) {
            revert UnexpectedPredictionStatus(predictionId, uint8(assignment.status));
        }
        if (_results[predictionId].resolved) revert PredictionAlreadyResolved(predictionId);

        bytes32 pendingHash = assignment.pendingProposalHash;

        _validateResolution(resolutionKind, winningOptionIndex, optionVotes, evidenceBundleHash);
        bytes32 proposalHash = hashCommitteeResolution(
            predictionId, resolutionKind, winningOptionIndex, optionVotes, evidenceBundleHash
        );

        ProposalTally storage tally = _proposalTallies[predictionId][proposalHash];
        if (!tally.exists) {
            tally.exists = true;
            tally.resolutionKind = resolutionKind;
            tally.winningOptionIndex = winningOptionIndex;
            tally.yesVotes = _legacyYesVotes(optionVotes);
            tally.noVotes = _legacyNoVotes(optionVotes);
            tally.evidenceBundleHash = evidenceBundleHash;
            for (uint256 i = 0; i < optionVotes.length; i++) {
                tally.optionVotes.push(optionVotes[i]);
            }
        }

        _storeResult(predictionId, proposalHash, tally, msg.sender, true);
        assignment.status = PredictionStatus.EmergencyResolved;

        _settleChallengeBond(predictionId, resolutionKind, winningOptionIndex, pendingHash);

        emit PredictionResolvedByEmergency(
            predictionId,
            proposalHash,
            evidenceBundleHash,
            resolutionKind,
            winningOptionIndex,
            block.timestamp,
            msg.sender
        );
    }

    function _settleChallengeBond(
        uint256 predictionId,
        uint8 finalResolutionKind,
        uint8 finalWinningOptionIndex,
        bytes32 pendingProposalHash
    ) internal {
        Challenge storage challenge = _challenges[predictionId];
        if (!challenge.exists || challenge.bondAmount == 0) return;

        ProposalTally storage pendingTally = _proposalTallies[predictionId][pendingProposalHash];
        bool upheld = finalResolutionKind != pendingTally.resolutionKind
            || finalWinningOptionIndex != pendingTally.winningOptionIndex;

        address recipient = upheld ? challenge.challenger : treasury;
        if (recipient == address(0)) revert TreasuryNotSet();

        uint96 amount = challenge.bondAmount;
        challenge.bondAmount = 0;
        pendingWithdrawals[recipient] += amount;
        emit ChallengeBondSettled(predictionId, recipient, amount, upheld);
    }

    function getPredictionOutcome(uint256 predictionId) external view override returns (bool resolved, uint8 outcome) {
        Result memory result = _results[predictionId];
        return (result.resolved, result.outcome);
    }

    function getPredictionResolution(uint256 predictionId)
        external
        view
        override
        returns (bool resolved, uint8 resolutionKind, uint8 winningOptionIndex)
    {
        Result memory result = _results[predictionId];
        return (result.resolved, result.resolutionKind, result.winningOptionIndex);
    }

    function getPredictionStatus(uint256 predictionId) external view returns (PredictionStatus) {
        return _predictionAssignments[predictionId].status;
    }

    function getProtocolConfig() external view returns (ProtocolConfig memory) {
        return protocolConfig;
    }

    function getJuror(uint256 memberTokenId) external view returns (Juror memory) {
        return _getJurorStorage(memberTokenId);
    }

    function getJurorTokenIds() external view returns (uint256[] memory) {
        return _jurorTokenIds;
    }

    function getPredictionAssignment(uint256 predictionId) external view returns (PredictionAssignment memory) {
        return _predictionAssignments[predictionId];
    }

    function getPrimaryMembers(uint256 predictionId) external view returns (uint256[] memory) {
        return _predictionPrimaryMembers[predictionId];
    }

    function getReserveMembers(uint256 predictionId) external view returns (uint256[] memory) {
        return _predictionReserveMembers[predictionId];
    }

    function getMemberSubmissionHash(uint256 predictionId, uint256 memberTokenId) external view returns (bytes32) {
        return _memberSubmissionHashes[predictionId][memberTokenId];
    }

    function getProposalApprovalCount(uint256 predictionId, bytes32 proposalHash) external view returns (uint16) {
        return _proposalTallies[predictionId][proposalHash].approvalCount;
    }

    function getOutcomeApprovalCount(uint256 predictionId, uint8 resolutionKind, uint8 winningOptionIndex)
        external
        view
        returns (uint16)
    {
        return _outcomeApprovalCounts[predictionId][_outcomeKey(predictionId, resolutionKind, winningOptionIndex)];
    }

    function getChallenge(uint256 predictionId) external view returns (Challenge memory) {
        return _challenges[predictionId];
    }

    function getResult(uint256 predictionId) external view returns (Result memory) {
        return _results[predictionId];
    }

    function getSubmissionWindowClosesAt(uint256 predictionId) public view returns (uint256) {
        PredictionAssignment storage assignment = _predictionAssignments[predictionId];
        return uint256(assignment.assignedAt) + uint256(assignment.voteWindow) + uint256(assignment.graceWindow);
    }

    function getReserveWindowOpensAt(uint256 predictionId) public view returns (uint256) {
        PredictionAssignment storage assignment = _predictionAssignments[predictionId];
        return uint256(assignment.assignedAt) + uint256(assignment.voteWindow);
    }

    function hashCommitteeResolution(
        uint256 predictionId,
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256[] memory optionVotes,
        bytes32 evidenceBundleHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(predictionId, resolutionKind, winningOptionIndex, optionVotes, evidenceBundleHash));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashRegisterJurorRequest(
        address owner,
        uint256 memberTokenId,
        bytes32 metadataHash,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(REGISTER_JUROR_TYPEHASH, owner, memberTokenId, metadataHash, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function hashSetJurorActiveRequest(
        address owner,
        uint256 memberTokenId,
        bool active,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(SET_JUROR_ACTIVE_TYPEHASH, owner, memberTokenId, active, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function _setProtocolConfig(ProtocolConfig calldata nextConfig) internal {
        if (
            nextConfig.primaryCount == 0 || nextConfig.quorum == 0
                || nextConfig.quorum > nextConfig.primaryCount + nextConfig.reserveCount
                || nextConfig.selectionDelayBlocks == 0 || nextConfig.voteWindow == 0 || nextConfig.challengeWindow == 0
                || nextConfig.maxEpochs == 0
        ) {
            revert InvalidProtocolConfig();
        }
        protocolConfig = nextConfig;
        emit ProtocolConfigUpdated(
            nextConfig.primaryCount,
            nextConfig.reserveCount,
            nextConfig.quorum,
            nextConfig.selectionDelayBlocks,
            nextConfig.voteWindow,
            nextConfig.graceWindow,
            nextConfig.challengeWindow,
            nextConfig.challengeBond,
            nextConfig.maxEpochs,
            nextConfig.policyHash
        );
    }

    function _setSelectionPending(uint256 predictionId, PredictionAssignment storage assignment, uint16 epoch) internal {
        assignment.status = PredictionStatus.SelectionPending;
        assignment.selectionRequestedBlock = uint64(block.number);
        assignment.selectionTargetBlock = uint64(block.number + protocolConfig.selectionDelayBlocks);

        emit SelectionRequested(predictionId, assignment.selectionTargetBlock, protocolConfig.primaryCount, protocolConfig.reserveCount);
        emit PredictionEpochSelectionRequested(
            predictionId,
            epoch,
            assignment.selectionTargetBlock,
            protocolConfig.primaryCount,
            protocolConfig.reserveCount
        );
    }

    function _finalizePendingResult(uint256 predictionId, address finalizer) internal {
        PredictionAssignment storage assignment = _getAssignmentStorage(predictionId, PredictionStatus.PendingFinality);
        if (block.timestamp <= assignment.challengeDeadline) {
            revert ChallengeWindowStillOpen(predictionId, block.timestamp, assignment.challengeDeadline);
        }

        bytes32 proposalHash = assignment.pendingProposalHash;
        ProposalTally storage tally = _proposalTallies[predictionId][proposalHash];
        _storeResult(predictionId, proposalHash, tally, finalizer, false);
        assignment.status = PredictionStatus.Finalized;

        emit PredictionResolvedByCommittee(
            predictionId,
            proposalHash,
            tally.evidenceBundleHash,
            tally.resolutionKind,
            tally.winningOptionIndex,
            block.timestamp,
            finalizer
        );
    }

    function _markPredictionStalled(uint256 predictionId) internal {
        PredictionAssignment storage assignment = _predictionAssignments[predictionId];
        if (assignment.status != PredictionStatus.Voting) {
            revert UnexpectedPredictionStatus(predictionId, uint8(assignment.status));
        }
        uint256 submissionWindowClosesAt = getSubmissionWindowClosesAt(predictionId);
        if (block.timestamp <= submissionWindowClosesAt) {
            revert SubmissionWindowClosed(predictionId, block.timestamp, submissionWindowClosesAt);
        }

        assignment.status = PredictionStatus.Stalled;
        emit PredictionStalled(predictionId, uint8(PredictionStatus.Voting), block.timestamp);
    }

    function _drawJurors(bytes32 selectionSeed, uint256 neededCount) internal view returns (uint256[] memory selected) {
        uint256[] memory eligible = _eligibleJurors();
        if (eligible.length < neededCount) {
            revert InsufficientEligibleJurors(neededCount, eligible.length);
        }

        bytes32[] memory scores = new bytes32[](eligible.length);
        for (uint256 i = 0; i < eligible.length; i++) {
            scores[i] = keccak256(abi.encode(selectionSeed, eligible[i]));
        }

        for (uint256 i = 0; i < neededCount; i++) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < eligible.length; j++) {
                if (uint256(scores[j]) < uint256(scores[minIndex])) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                (scores[i], scores[minIndex]) = (scores[minIndex], scores[i]);
                (eligible[i], eligible[minIndex]) = (eligible[minIndex], eligible[i]);
            }
        }

        selected = new uint256[](neededCount);
        for (uint256 i = 0; i < neededCount; i++) {
            selected[i] = eligible[i];
        }
    }

    function _eligibleJurors() internal view returns (uint256[] memory out) {
        uint256 activeCount = _activeJurorTokenIds.length();
        out = new uint256[](activeCount);
        uint256 count;
        for (uint256 i = 0; i < activeCount; i++) {
            uint256 tokenId = _activeJurorTokenIds.at(i);
            if (_jurors[tokenId].cooldownUntil <= block.timestamp) {
                out[count] = tokenId;
                count++;
            }
        }
        assembly {
            mstore(out, count)
        }
    }

    function _validateResolution(
        uint8 resolutionKind,
        uint8 winningOptionIndex,
        uint256[] calldata optionVotes,
        bytes32 evidenceBundleHash
    ) internal pure {
        if (evidenceBundleHash == bytes32(0)) revert ZeroEvidenceBundleHash();
        if (optionVotes.length < 2) revert InvalidOptionVotesLength();
        if (
            resolutionKind != RESOLUTION_RESOLVED && resolutionKind != RESOLUTION_VOID
                && resolutionKind != RESOLUTION_INVALID
        ) {
            revert InvalidResolutionKind(resolutionKind);
        }
        if (resolutionKind == RESOLUTION_RESOLVED) {
            if (winningOptionIndex == 0 || winningOptionIndex > optionVotes.length) {
                revert InvalidWinningOptionIndex(winningOptionIndex, optionVotes.length);
            }
        } else if (winningOptionIndex != 0) {
            revert InvalidWinningOptionIndex(winningOptionIndex, optionVotes.length);
        }
    }

    function _storeResult(
        uint256 predictionId,
        bytes32 proposalHash,
        ProposalTally storage tally,
        address finalizer,
        bool emergency
    ) internal {
        Result storage result = _results[predictionId];
        result.resolved = true;
        result.emergency = emergency;
        result.resolutionKind = tally.resolutionKind;
        result.winningOptionIndex = tally.winningOptionIndex;
        result.outcome = _legacyOutcome(tally.resolutionKind, tally.winningOptionIndex, tally.optionVotes.length);
        result.yesVotes = tally.yesVotes;
        result.noVotes = tally.noVotes;
        delete result.optionVotes;
        for (uint256 i = 0; i < tally.optionVotes.length; i++) {
            result.optionVotes.push(tally.optionVotes[i]);
        }
        result.finalizedAt = block.timestamp;
        result.finalizer = finalizer;
        result.proposalHash = proposalHash;
        result.evidenceBundleHash = tally.evidenceBundleHash;
    }

    function _legacyOutcome(uint8 resolutionKind, uint8 winningOptionIndex, uint256 optionCount)
        internal
        pure
        returns (uint8 outcome)
    {
        if (resolutionKind != RESOLUTION_RESOLVED || optionCount != 2) {
            return OUTCOME_INVALID;
        }
        if (winningOptionIndex == 1) return OUTCOME_YES;
        if (winningOptionIndex == 2) return OUTCOME_NO;
        return OUTCOME_INVALID;
    }

    function _legacyYesVotes(uint256[] calldata optionVotes) internal pure returns (uint256) {
        return optionVotes.length > 0 ? optionVotes[0] : 0;
    }

    function _legacyNoVotes(uint256[] calldata optionVotes) internal pure returns (uint256) {
        return optionVotes.length > 1 ? optionVotes[1] : 0;
    }

    function _outcomeKey(uint256 predictionId, uint8 resolutionKind, uint8 winningOptionIndex)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(predictionId, resolutionKind, winningOptionIndex));
    }

    function _consumeRegisterJurorApproval(
        address owner,
        uint256 memberTokenId,
        bytes32 metadataHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);

        uint256 expectedNonce = jurorRegisterNonces[memberTokenId];
        if (nonce != expectedNonce) revert InvalidNonce(expectedNonce, nonce);

        bytes32 digest = hashRegisterJurorRequest(owner, memberTokenId, metadataHash, nonce, deadline);
        (address signer, ECDSA.RecoverError recoverError,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (recoverError != ECDSA.RecoverError.NoError || !hasRole(JUROR_APPROVER_ROLE, signer)) revert InvalidSignature();

        jurorRegisterNonces[memberTokenId] = expectedNonce + 1;
    }

    function _consumeSetJurorActiveApproval(
        address owner,
        uint256 memberTokenId,
        bool active,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);

        uint256 expectedNonce = jurorActivationNonces[memberTokenId];
        if (nonce != expectedNonce) revert InvalidNonce(expectedNonce, nonce);

        bytes32 digest = hashSetJurorActiveRequest(owner, memberTokenId, active, nonce, deadline);
        (address signer, ECDSA.RecoverError recoverError,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (recoverError != ECDSA.RecoverError.NoError || !hasRole(JUROR_APPROVER_ROLE, signer)) revert InvalidSignature();

        jurorActivationNonces[memberTokenId] = expectedNonce + 1;
    }

    function _getAssignmentStorage(uint256 predictionId, PredictionStatus expectedStatus)
        internal
        view
        returns (PredictionAssignment storage assignment)
    {
        if (predictionId == 0) revert InvalidPredictionId();
        assignment = _predictionAssignments[predictionId];
        if (assignment.status != expectedStatus) {
            revert UnexpectedPredictionStatus(predictionId, uint8(assignment.status));
        }
    }

    function _getJurorStorage(uint256 memberTokenId) internal view returns (Juror storage juror) {
        juror = _jurors[memberTokenId];
        if (!juror.registered) revert JurorNotRegistered(memberTokenId);
    }

    function _setJurorActive(uint256 memberTokenId, bool active) internal {
        Juror storage juror = _getJurorStorage(memberTokenId);
        if (juror.active == active) return;
        if (active) {
            if (maxActiveJurors != 0 && _activeJurorTokenIds.length() >= maxActiveJurors) {
                revert MaxActiveJurorsReached(maxActiveJurors);
            }
            _activeJurorTokenIds.add(memberTokenId);
        } else {
            _activeJurorTokenIds.remove(memberTokenId);
        }
        juror.active = active;
        emit JurorActiveUpdated(memberTokenId, active);
    }

    function _assertPredictionTokenOwner(address operator, uint256 tokenId) internal view {
        address tokenOwner = nft.ownerOf(tokenId);
        if (operator != tokenOwner && nft.getApproved(tokenId) != operator && !nft.isApprovedForAll(tokenOwner, operator)) {
            revert Unauthorized();
        }
    }

    function _assertStrictPredictionTokenOwner(address operator, uint256 tokenId) internal view returns (address tokenOwner) {
        tokenOwner = nft.ownerOf(tokenId);
        if (operator != tokenOwner) revert Unauthorized();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
