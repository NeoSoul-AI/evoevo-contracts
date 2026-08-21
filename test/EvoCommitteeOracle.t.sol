// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import {EvoCommitteeOracle} from "../src/EvoCommitteeOracle.sol";

contract CommitteeAgentMock {
    error NonexistentToken(uint256 tokenId);
    error Unauthorized();

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
        return owner;
    }

    function approve(address to, uint256 tokenId) external {
        if (msg.sender != _owners[tokenId]) revert Unauthorized();
        _approvals[tokenId] = to;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }
}

contract EvoCommitteeOracleUpgradeMock is EvoCommitteeOracle {
    function upgradeVersion() external pure returns (uint256) {
        return 5;
    }
}

contract EvoCommitteeOracleTest is Test {
    CommitteeAgentMock internal agentNFT;
    EvoCommitteeOracle internal oracle;

    uint256 internal adminPrivateKey = uint256(keccak256("admin"));
    address internal admin = vm.addr(adminPrivateKey);
    uint256 internal jurorApproverPrivateKey = uint256(keccak256("juror-approver"));
    address internal jurorApprover = vm.addr(jurorApproverPrivateKey);
    address internal governor = makeAddr("governor");
    address internal timelockExecutor = makeAddr("timelockExecutor");
    address internal emergencyGuardian = makeAddr("emergencyGuardian");
    address internal automationOperator = makeAddr("automationOperator");
    address internal challengeOperator = makeAddr("challengeOperator");
    address internal jurorManager = makeAddr("jurorManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal challenger = makeAddr("challenger");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant CHALLENGE_BOND = 0.1 ether;

    function setUp() public {
        agentNFT = new CommitteeAgentMock();
        agentNFT.mint(alice, 1);
        agentNFT.mint(bob, 2);
        agentNFT.mint(carol, 3);
        agentNFT.mint(dave, 4);
        agentNFT.mint(alice, 5);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave, 10 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(challengeOperator, 10 ether);
        vm.deal(stranger, 10 ether);

        oracle = _deployOracle();

        _registerJuror(alice, 1);
        _registerJuror(bob, 2);
        _registerJuror(carol, 3);
        _registerJuror(dave, 4);
    }

    function test_Initialize_InitialState() public view {
        assertEq(address(oracle.nft()), address(agentNFT));
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.GOVERNOR_ROLE(), governor));
        assertTrue(oracle.hasRole(oracle.TIMELOCK_EXECUTOR_ROLE(), timelockExecutor));
        assertTrue(oracle.hasRole(oracle.EMERGENCY_GUARDIAN_ROLE(), emergencyGuardian));
        assertTrue(oracle.hasRole(oracle.AUTOMATION_ROLE(), automationOperator));
        assertTrue(oracle.hasRole(oracle.CHALLENGE_ROLE(), challengeOperator));
        assertTrue(oracle.hasRole(oracle.JUROR_MANAGER_ROLE(), jurorManager));
        assertTrue(oracle.hasRole(oracle.JUROR_APPROVER_ROLE(), jurorApprover));

        EvoCommitteeOracle.ProtocolConfig memory config = oracle.getProtocolConfig();
        assertEq(config.primaryCount, 2);
        assertEq(config.reserveCount, 1);
        assertEq(config.quorum, 2);
        assertEq(config.selectionDelayBlocks, 2);
        assertEq(config.maxEpochs, 3);
    }

    function test_RegisterJuror_WithAdminSignature_DefaultsInactive() public {
        bytes32 metadataHash = keccak256("juror-5");
        uint256 nonce = oracle.jurorRegisterNonces(5);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegisterJuror(alice, 5, metadataHash, nonce, deadline);

        vm.prank(alice);
        oracle.registerJuror(5, metadataHash, nonce, deadline, signature);

        EvoCommitteeOracle.Juror memory juror = oracle.getJuror(5);
        assertTrue(juror.registered);
        assertFalse(juror.active);
        assertEq(juror.metadataHash, metadataHash);
        assertEq(oracle.jurorRegisterNonces(5), nonce + 1);
    }

    function test_RevertIf_RegisterJuror_WithoutApproverSignature() public {
        bytes32 metadataHash = keccak256("juror-5");
        uint256 nonce = oracle.jurorRegisterNonces(5);
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        vm.expectRevert(EvoCommitteeOracle.InvalidSignature.selector);
        oracle.registerJuror(5, metadataHash, nonce, deadline, hex"");
    }

    function test_RevertIf_RegisterJuror_WithRootAdminSignatureButWithoutApproverRole() public {
        bytes32 metadataHash = keccak256("juror-5");
        uint256 nonce = oracle.jurorRegisterNonces(5);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegisterJurorWithKey(adminPrivateKey, alice, 5, metadataHash, nonce, deadline);

        vm.prank(alice);
        vm.expectRevert(EvoCommitteeOracle.InvalidSignature.selector);
        oracle.registerJuror(5, metadataHash, nonce, deadline, signature);
    }

    function test_RevertIf_RegisterJuror_ApprovedOperatorCannotUseSignature() public {
        bytes32 metadataHash = keccak256("juror-5");
        uint256 nonce = oracle.jurorRegisterNonces(5);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegisterJuror(alice, 5, metadataHash, nonce, deadline);

        vm.prank(alice);
        agentNFT.approve(stranger, 5);

        vm.prank(stranger);
        vm.expectRevert(EvoCommitteeOracle.Unauthorized.selector);
        oracle.registerJuror(5, metadataHash, nonce, deadline, signature);
    }

    function test_SetJurorActiveWithSig_WorksForTokenOwner() public {
        vm.prank(jurorManager);
        oracle.setJurorActive(1, false);

        uint256 nonce = oracle.jurorActivationNonces(1);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signSetJurorActive(alice, 1, true, nonce, deadline);

        vm.prank(alice);
        oracle.setJurorActiveWithSig(1, true, nonce, deadline, signature);

        EvoCommitteeOracle.Juror memory juror = oracle.getJuror(1);
        assertTrue(juror.active);
        assertEq(oracle.jurorActivationNonces(1), nonce + 1);
    }

    function test_SetJurorActive_RepeatedCallSkipsWriteAndEvent() public {
        // tokenId 1 已在 setUp 中激活
        vm.recordLogs();
        vm.prank(jurorManager);
        oracle.setJurorActive(1, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no-op activation must not emit");
    }

    function test_RevertIf_SetJurorActive_NonManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, oracle.JUROR_MANAGER_ROLE()
            )
        );
        vm.prank(alice);
        oracle.setJurorActive(1, false);
    }

    function test_SetJurorActive_MaintainsActiveIndex() public {
        assertEq(oracle.getActiveJurorTokenIds().length, 4); // setUp 激活了 1-4
        vm.prank(jurorManager);
        oracle.setJurorActive(2, false);
        assertEq(oracle.getActiveJurorTokenIds().length, 3);
        vm.prank(jurorManager);
        oracle.setJurorActive(2, true);
        assertEq(oracle.getActiveJurorTokenIds().length, 4);
    }

    function test_RevertIf_MaxActiveJurorsReached() public {
        vm.prank(governor);
        oracle.setMaxActiveJurors(4); // 已有 4 个 active

        bytes32 metadataHash = bytes32(uint256(5));
        uint256 nonce = oracle.jurorRegisterNonces(5);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signRegisterJuror(alice, 5, metadataHash, nonce, deadline);
        vm.prank(alice);
        oracle.registerJuror(5, metadataHash, nonce, deadline, sig);

        vm.prank(jurorManager);
        vm.expectRevert(abi.encodeWithSelector(EvoCommitteeOracle.MaxActiveJurorsReached.selector, 4));
        oracle.setJurorActive(5, true);
    }

    function test_RevertIf_RequestSelection_NonAutomationOperator() public {
        uint256 predictionId = 999;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracle.AUTOMATION_ROLE()
            )
        );
        vm.prank(stranger);
        oracle.requestSelectionForPrediction(predictionId);
    }

    function test_RequestSelection_SubmitPendingFinality_ThenFinalize() public {
        uint256 predictionId = 1001;
        bytes32 evidenceBundleHash = keccak256("evidence-bundle-a");
        uint256[] memory optionVotes = _twoOptionVotes(8, 2);

        _finalizeSelection(predictionId);

        {
            EvoCommitteeOracle.PredictionAssignment memory assignment = oracle.getPredictionAssignment(predictionId);
            assertEq(assignment.currentEpoch, 1);
            assertEq(assignment.epochStartedAt, assignment.assignedAt);

            uint256[] memory primaryMembers = oracle.getPrimaryMembers(predictionId);
            assertEq(primaryMembers.length, 2);
            assertEq(oracle.getReserveMembers(predictionId).length, 1);

            _submitMatchingPrimaryMembers(predictionId, primaryMembers, 1, optionVotes, evidenceBundleHash);
        }

        assertEq(
            oracle.getProposalApprovalCount(
                predictionId,
                oracle.hashCommitteeResolution(predictionId, oracle.RESOLUTION_RESOLVED(), 1, optionVotes, evidenceBundleHash)
            ),
            2
        );
        assertEq(
            uint8(oracle.getPredictionStatus(predictionId)),
            uint8(EvoCommitteeOracle.PredictionStatus.PendingFinality)
        );

        (bool resolvedBefore,) = oracle.getPredictionOutcome(predictionId);
        assertFalse(resolvedBefore);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(automationOperator);
        oracle.finalizePendingResult(predictionId);

        (bool resolved, uint8 outcome) = oracle.getPredictionOutcome(predictionId);
        assertTrue(resolved);
        assertEq(outcome, oracle.OUTCOME_YES());
        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Finalized));

        EvoCommitteeOracle.Result memory result = oracle.getResult(predictionId);
        assertEq(result.evidenceBundleHash, evidenceBundleHash);
        assertEq(
            result.proposalHash,
            oracle.hashCommitteeResolution(predictionId, oracle.RESOLUTION_RESOLVED(), 1, optionVotes, evidenceBundleHash)
        );
    }

    function test_SubmitJurorResolution_SameOutcomeDifferentEvidenceAggregates() public {
        uint256 predictionId = 1;
        _finalizeSelection(predictionId);
        uint256[] memory primary = oracle.getPrimaryMembers(predictionId);
        uint8 kind = oracle.RESOLUTION_RESOLVED();

        vm.prank(_ownerOfToken(primary[0]));
        oracle.submitJurorResolution(predictionId, primary[0], kind, 1, _twoOptionVotes(2, 0), bytes32("evidence-a"));
        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Voting));

        // 同一获胜选项、不同 optionVotes、不同 evidence —— 修复前会分裂进不同桶、凑不齐 quorum
        vm.prank(_ownerOfToken(primary[1]));
        oracle.submitJurorResolution(predictionId, primary[1], kind, 1, _twoOptionVotes(1, 1), bytes32("evidence-b"));

        assertEq(
            uint8(oracle.getPredictionStatus(predictionId)),
            uint8(EvoCommitteeOracle.PredictionStatus.PendingFinality)
        );
        assertEq(oracle.getOutcomeApprovalCount(predictionId, kind, 1), 2);

        // canonical = 第一份提案
        EvoCommitteeOracle.PredictionAssignment memory a = oracle.getPredictionAssignment(predictionId);
        bytes32 expected =
            oracle.hashCommitteeResolution(predictionId, kind, 1, _twoOptionVotes(2, 0), bytes32("evidence-a"));
        assertEq(a.pendingProposalHash, expected);
    }

    function test_SubmitJurorResolution_DifferentOutcomesDoNotAggregate() public {
        uint256 predictionId = 1;
        _finalizeSelection(predictionId);
        uint256[] memory primary = oracle.getPrimaryMembers(predictionId);
        uint8 kind = oracle.RESOLUTION_RESOLVED();

        vm.prank(_ownerOfToken(primary[0]));
        oracle.submitJurorResolution(predictionId, primary[0], kind, 1, _twoOptionVotes(2, 0), bytes32("evidence-a"));
        vm.prank(_ownerOfToken(primary[1]));
        oracle.submitJurorResolution(predictionId, primary[1], kind, 2, _twoOptionVotes(0, 2), bytes32("evidence-b"));

        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Voting));
        assertEq(oracle.getOutcomeApprovalCount(predictionId, kind, 1), 1);
        assertEq(oracle.getOutcomeApprovalCount(predictionId, kind, 2), 1);
    }

    function test_RetrySelectionAfterEntropyExpires_ThenFinalize() public {
        uint256 predictionId = 1004;

        vm.prank(automationOperator);
        oracle.requestSelectionForPrediction(predictionId);
        EvoCommitteeOracle.PredictionAssignment memory initialAssignment =
            oracle.getPredictionAssignment(predictionId);

        vm.roll(uint256(initialAssignment.selectionTargetBlock) + 257);

        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.SelectionEntropyUnavailable.selector,
                predictionId,
                uint256(initialAssignment.selectionTargetBlock)
            )
        );
        vm.prank(automationOperator);
        oracle.finalizeSelectionForPrediction(predictionId);

        vm.prank(automationOperator);
        oracle.retrySelectionForPrediction(predictionId);

        EvoCommitteeOracle.PredictionAssignment memory retriedAssignment =
            oracle.getPredictionAssignment(predictionId);
        assertEq(retriedAssignment.currentEpoch, 2);
        assertGt(retriedAssignment.selectionTargetBlock, initialAssignment.selectionTargetBlock);
        assertEq(uint8(retriedAssignment.status), uint8(EvoCommitteeOracle.PredictionStatus.SelectionPending));

        vm.roll(block.number + 3);
        vm.prank(automationOperator);
        oracle.finalizeSelectionForPrediction(predictionId);

        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Voting));
        assertEq(oracle.getPrimaryMembers(predictionId).length, 2);
        assertEq(oracle.getReserveMembers(predictionId).length, 1);
    }

    function test_RevertIf_RetrySelectionBeforeEntropyExpires() public {
        uint256 predictionId = 1005;

        vm.prank(automationOperator);
        oracle.requestSelectionForPrediction(predictionId);
        EvoCommitteeOracle.PredictionAssignment memory assignment = oracle.getPredictionAssignment(predictionId);

        vm.roll(uint256(assignment.selectionTargetBlock) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.SelectionEntropyStillAvailable.selector,
                predictionId,
                block.number,
                uint256(assignment.selectionTargetBlock)
            )
        );
        vm.prank(automationOperator);
        oracle.retrySelectionForPrediction(predictionId);
    }

    function test_RevertIf_RetrySelectionExceedsMaxEpochs() public {
        uint256 predictionId = 1006;
        EvoCommitteeOracle.ProtocolConfig memory config = _defaultConfig();
        config.maxEpochs = 2;

        vm.prank(governor);
        oracle.setProtocolConfig(config);

        vm.prank(automationOperator);
        oracle.requestSelectionForPrediction(predictionId);
        EvoCommitteeOracle.PredictionAssignment memory assignment = oracle.getPredictionAssignment(predictionId);

        vm.roll(uint256(assignment.selectionTargetBlock) + 257);
        vm.prank(automationOperator);
        oracle.retrySelectionForPrediction(predictionId);

        EvoCommitteeOracle.PredictionAssignment memory secondAssignment = oracle.getPredictionAssignment(predictionId);
        vm.roll(uint256(secondAssignment.selectionTargetBlock) + 257);

        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.MaxSelectionEpochsExceeded.selector,
                predictionId,
                uint16(2),
                uint16(2)
            )
        );
        vm.prank(automationOperator);
        oracle.retrySelectionForPrediction(predictionId);
    }

    function test_MarkPredictionStalled_StallsOverdueVotingPrediction() public {
        uint256 predictionId = 1101;

        _finalizeSelection(predictionId);

        vm.warp(oracle.getSubmissionWindowClosesAt(predictionId) + 1);
        vm.prank(automationOperator);
        oracle.markPredictionStalled(predictionId);

        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Stalled));
    }

    function test_FinalizePendingResult_FinalizesExpiredPendingFinalityPrediction() public {
        uint256 predictionId = 1102;
        bytes32 evidenceBundleHash = keccak256("evidence-bundle-advance");
        uint256[] memory optionVotes = _twoOptionVotes(9, 1);
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();

        _finalizeSelection(predictionId);

        uint256[] memory primaryMembers = oracle.getPrimaryMembers(predictionId);
        vm.prank(_ownerOfToken(primaryMembers[0]));
        oracle.submitJurorResolution(predictionId, primaryMembers[0], resolvedKind, 1, optionVotes, evidenceBundleHash);
        vm.prank(_ownerOfToken(primaryMembers[1]));
        oracle.submitJurorResolution(predictionId, primaryMembers[1], resolvedKind, 1, optionVotes, evidenceBundleHash);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(automationOperator);
        oracle.finalizePendingResult(predictionId);

        (bool resolved, uint8 outcome) = oracle.getPredictionOutcome(predictionId);
        assertTrue(resolved);
        assertEq(outcome, oracle.OUTCOME_YES());
        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Finalized));
    }

    function test_RevertIf_MarkPredictionStalled_VotingWindowStillOpen() public {
        uint256 predictionId = 1103;

        _finalizeSelection(predictionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.SubmissionWindowClosed.selector,
                predictionId,
                block.timestamp,
                oracle.getSubmissionWindowClosesAt(predictionId)
            )
        );
        vm.prank(automationOperator);
        oracle.markPredictionStalled(predictionId);
    }

    function test_ReserveCannotSubmitBeforeVoteWindow_ButCanBackfillLater() public {
        uint256 predictionId = 2002;
        bytes32 evidenceBundleHash = keccak256("evidence-bundle-b");
        uint256[] memory optionVotes = _twoOptionVotes(2, 7);
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();

        _finalizeSelection(predictionId);

        uint256[] memory primaryMembers = oracle.getPrimaryMembers(predictionId);
        uint256 reserveMember = oracle.getReserveMembers(predictionId)[0];

        vm.prank(_ownerOfToken(primaryMembers[0]));
        oracle.submitJurorResolution(predictionId, primaryMembers[0], resolvedKind, 2, optionVotes, evidenceBundleHash);

        vm.prank(_ownerOfToken(reserveMember));
        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.ReserveWindowNotOpen.selector,
                predictionId,
                block.timestamp,
                oracle.getReserveWindowOpensAt(predictionId)
            )
        );
        oracle.submitJurorResolution(predictionId, reserveMember, resolvedKind, 2, optionVotes, evidenceBundleHash);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(_ownerOfToken(reserveMember));
        oracle.submitJurorResolution(predictionId, reserveMember, resolvedKind, 2, optionVotes, evidenceBundleHash);

        assertEq(
            uint8(oracle.getPredictionStatus(predictionId)),
            uint8(EvoCommitteeOracle.PredictionStatus.PendingFinality)
        );
    }

    function test_ChallengeMovesPredictionOutOfPendingFinality_AndEmergencyCanResolve() public {
        uint256 predictionId = 3003;
        bytes32 evidenceBundleHash = keccak256("evidence-bundle-c");
        bytes32 challengerEvidenceHash = keccak256("challenger-evidence");
        uint256[] memory optionVotes = _twoOptionVotes(5, 4);
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();
        uint8 invalidKind = oracle.RESOLUTION_INVALID();

        _finalizeSelection(predictionId);

        uint256[] memory primaryMembers = oracle.getPrimaryMembers(predictionId);
        vm.prank(_ownerOfToken(primaryMembers[0]));
        oracle.submitJurorResolution(predictionId, primaryMembers[0], resolvedKind, 1, optionVotes, evidenceBundleHash);
        vm.prank(_ownerOfToken(primaryMembers[1]));
        oracle.submitJurorResolution(predictionId, primaryMembers[1], resolvedKind, 1, optionVotes, evidenceBundleHash);

        vm.prank(challengeOperator);
        oracle.challengePendingResult{value: CHALLENGE_BOND}(predictionId, challengerEvidenceHash, bytes32("bad_source"));

        assertEq(
            uint8(oracle.getPredictionStatus(predictionId)),
            uint8(EvoCommitteeOracle.PredictionStatus.Challenged)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                EvoCommitteeOracle.UnexpectedPredictionStatus.selector,
                predictionId,
                uint8(EvoCommitteeOracle.PredictionStatus.Challenged)
            )
        );
        vm.prank(automationOperator);
        oracle.finalizePendingResult(predictionId);

        vm.prank(emergencyGuardian);
        oracle.emergencyResolvePrediction(predictionId, invalidKind, 0, _twoOptionVotes(0, 0), keccak256("emergency"));

        EvoCommitteeOracle.Result memory result = oracle.getResult(predictionId);
        assertTrue(result.resolved);
        assertTrue(result.emergency);
        assertEq(result.outcome, oracle.OUTCOME_INVALID());
        assertEq(
            uint8(oracle.getPredictionStatus(predictionId)),
            uint8(EvoCommitteeOracle.PredictionStatus.EmergencyResolved)
        );
    }

    function test_Upgrade_AuthorizedAdmin_Works() public {
        EvoCommitteeOracleUpgradeMock nextImpl = new EvoCommitteeOracleUpgradeMock();

        vm.prank(admin);
        EvoCommitteeOracleUpgradeMock(address(oracle)).upgradeToAndCall(address(nextImpl), "");

        assertEq(EvoCommitteeOracleUpgradeMock(address(oracle)).upgradeVersion(), 5);
    }

    function test_RevertIf_InitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(
            address(agentNFT),
            admin,
            governor,
            timelockExecutor,
            emergencyGuardian,
            automationOperator,
            challengeOperator,
            jurorManager,
            jurorApprover,
            _defaultConfig()
        );
    }

    function test_RevertIf_Upgrade_Unauthorized() public {
        EvoCommitteeOracleUpgradeMock nextImpl = new EvoCommitteeOracleUpgradeMock();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracle.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        oracle.upgradeToAndCall(address(nextImpl), "");
    }

    function test_EmergencyResolve_ChallengeUpheld_RefundsBond() public {
        uint256 predictionId = 1;
        vm.prank(admin);
        oracle.setTreasury(makeAddr("treasury"));

        _finalizeSelection(predictionId);
        _submitMatchingPrimaryMembers(
            predictionId, oracle.getPrimaryMembers(predictionId), 1, _twoOptionVotes(2, 0), bytes32("evidence")
        );

        vm.prank(challengeOperator);
        oracle.challengePendingResult{value: CHALLENGE_BOND}(predictionId, bytes32("challenge-ev"), bytes32("reason"));

        // 应急结果翻转获胜选项 => 挑战成立
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();
        vm.prank(emergencyGuardian);
        oracle.emergencyResolvePrediction(
            predictionId, resolvedKind, 2, _twoOptionVotes(0, 2), bytes32("final-ev")
        );

        assertEq(oracle.pendingWithdrawals(challengeOperator), CHALLENGE_BOND);

        uint256 balanceBefore = challengeOperator.balance;
        vm.prank(challengeOperator);
        oracle.withdraw();
        assertEq(challengeOperator.balance, balanceBefore + CHALLENGE_BOND);
        assertEq(address(oracle).balance, 0);
    }

    function test_EmergencyResolve_ChallengeRejected_ForfeitsBondToTreasury() public {
        uint256 predictionId = 1;
        address treasuryAddr = makeAddr("treasury");
        vm.prank(admin);
        oracle.setTreasury(treasuryAddr);

        _finalizeSelection(predictionId);
        _submitMatchingPrimaryMembers(
            predictionId, oracle.getPrimaryMembers(predictionId), 1, _twoOptionVotes(2, 0), bytes32("evidence")
        );

        vm.prank(challengeOperator);
        oracle.challengePendingResult{value: CHALLENGE_BOND}(predictionId, bytes32("challenge-ev"), bytes32("reason"));

        // 应急结果与 pending 一致 => 挑战失败
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();
        vm.prank(emergencyGuardian);
        oracle.emergencyResolvePrediction(
            predictionId, resolvedKind, 1, _twoOptionVotes(2, 0), bytes32("final-ev")
        );

        assertEq(oracle.pendingWithdrawals(challengeOperator), 0);
        assertEq(oracle.pendingWithdrawals(treasuryAddr), CHALLENGE_BOND);

        vm.prank(treasuryAddr);
        oracle.withdraw();
        assertEq(treasuryAddr.balance, CHALLENGE_BOND);
    }

    function test_RevertIf_SettlementNeedsTreasuryButUnset() public {
        uint256 predictionId = 1;
        _finalizeSelection(predictionId);
        _submitMatchingPrimaryMembers(
            predictionId, oracle.getPrimaryMembers(predictionId), 1, _twoOptionVotes(2, 0), bytes32("evidence")
        );
        vm.prank(challengeOperator);
        oracle.challengePendingResult{value: CHALLENGE_BOND}(predictionId, bytes32("challenge-ev"), bytes32("reason"));

        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();
        vm.prank(emergencyGuardian);
        vm.expectRevert(EvoCommitteeOracle.TreasuryNotSet.selector);
        oracle.emergencyResolvePrediction(
            predictionId, resolvedKind, 1, _twoOptionVotes(2, 0), bytes32("final-ev")
        );
    }

    function test_RevertIf_WithdrawWithNothingPending() public {
        vm.prank(stranger);
        vm.expectRevert(EvoCommitteeOracle.NothingToWithdraw.selector);
        oracle.withdraw();
    }

    function test_InitializeV2_OnlyAdminAndOnce() public {
        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        oracle.initializeV2();

        vm.prank(admin);
        oracle.initializeV2(); // 回填是幂等 set add，fresh 部署上调用无害
        assertEq(oracle.getActiveJurorTokenIds().length, 4);

        vm.prank(admin);
        vm.expectRevert(); // InvalidInitialization
        oracle.initializeV2();
    }

    function _deployOracle() internal returns (EvoCommitteeOracle deployed) {
        EvoCommitteeOracle implementation = new EvoCommitteeOracle();
        bytes memory initData = abi.encodeCall(
            EvoCommitteeOracle.initialize,
            (
                address(agentNFT),
                admin,
                governor,
                timelockExecutor,
                emergencyGuardian,
                automationOperator,
                challengeOperator,
                jurorManager,
                jurorApprover,
                _defaultConfig()
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        deployed = EvoCommitteeOracle(address(proxy));
    }

    function _defaultConfig() internal pure returns (EvoCommitteeOracle.ProtocolConfig memory config) {
        config = EvoCommitteeOracle.ProtocolConfig({
            primaryCount: 2,
            reserveCount: 1,
            quorum: 2,
            selectionDelayBlocks: 2,
            voteWindow: 1 days,
            graceWindow: 1 days,
            challengeWindow: 1 days,
            challengeBond: CHALLENGE_BOND,
            policyHash: bytes32("policy-mainline"),
            maxEpochs: 3
        });
    }

    function _registerJuror(address owner, uint256 tokenId) internal {
        bytes32 metadataHash = bytes32(tokenId);
        uint256 nonce = oracle.jurorRegisterNonces(tokenId);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegisterJuror(owner, tokenId, metadataHash, nonce, deadline);

        vm.prank(owner);
        oracle.registerJuror(tokenId, metadataHash, nonce, deadline, signature);

        vm.prank(jurorManager);
        oracle.setJurorActive(tokenId, true);
    }

    function _signRegisterJuror(address owner, uint256 tokenId, bytes32 metadataHash, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signRegisterJurorWithKey(jurorApproverPrivateKey, owner, tokenId, metadataHash, nonce, deadline);
    }

    function _signRegisterJurorWithKey(
        uint256 signerPrivateKey,
        address owner,
        uint256 tokenId,
        bytes32 metadataHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = oracle.hashRegisterJurorRequest(owner, tokenId, metadataHash, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSetJurorActive(address owner, uint256 tokenId, bool active, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = oracle.hashSetJurorActiveRequest(owner, tokenId, active, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(jurorApproverPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submitMatchingPrimaryMembers(
        uint256 predictionId,
        uint256[] memory primaryMembers,
        uint8 winningOptionIndex,
        uint256[] memory optionVotes,
        bytes32 evidenceBundleHash
    ) internal {
        uint8 resolvedKind = oracle.RESOLUTION_RESOLVED();

        vm.prank(_ownerOfToken(primaryMembers[0]));
        oracle.submitJurorResolution(
            predictionId,
            primaryMembers[0],
            resolvedKind,
            winningOptionIndex,
            optionVotes,
            evidenceBundleHash
        );

        assertEq(uint8(oracle.getPredictionStatus(predictionId)), uint8(EvoCommitteeOracle.PredictionStatus.Voting));

        vm.prank(_ownerOfToken(primaryMembers[1]));
        oracle.submitJurorResolution(
            predictionId,
            primaryMembers[1],
            resolvedKind,
            winningOptionIndex,
            optionVotes,
            evidenceBundleHash
        );
    }

    function _finalizeSelection(uint256 predictionId) internal {
        vm.prank(automationOperator);
        oracle.requestSelectionForPrediction(predictionId);
        vm.roll(block.number + 3);
        vm.prank(automationOperator);
        oracle.finalizeSelectionForPrediction(predictionId);
    }

    function _twoOptionVotes(uint256 yesVotes, uint256 noVotes) internal pure returns (uint256[] memory optionVotes) {
        optionVotes = new uint256[](2);
        optionVotes[0] = yesVotes;
        optionVotes[1] = noVotes;
    }

    function _ownerOfToken(uint256 tokenId) internal view returns (address) {
        if (tokenId == 1) return alice;
        if (tokenId == 2) return bob;
        if (tokenId == 3) return carol;
        if (tokenId == 4) return dave;
        if (tokenId == 5) return alice;
        return stranger;
    }
}
