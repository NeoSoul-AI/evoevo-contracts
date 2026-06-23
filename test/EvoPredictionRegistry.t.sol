// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EvoPredictionRegistry} from "../src/EvoPredictionRegistry.sol";

contract AgentNFTMock {
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

contract BindingRegistryStatusMock {
    mapping(uint256 => bool) private _bound;

    function setBound(uint256 tokenId, bool bound) external {
        _bound[tokenId] = bound;
    }

    function isEvoBound(uint256 tokenId) external view returns (bool) {
        return _bound[tokenId];
    }
}

contract EvoPredictionRegistryV2Mock is EvoPredictionRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract EvoPredictionRegistryTest is Test {
    event PredictionOpened(
        uint256 indexed predictionId,
        bytes32 indexed topicHash,
        uint64 openedAt,
        uint64 closeAt,
        uint32 optionCount,
        bytes32 contentHash,
        bytes32 optionsHash
    );

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

    AgentNFTMock internal nft;
    BindingRegistryStatusMock internal bindingRegistry;
    EvoPredictionRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal resultPublisher = makeAddr("resultPublisher");
    address internal snapshotPublisher = makeAddr("snapshotPublisher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant TOPIC_HASH = keccak256("prediction-topic");
    bytes32 internal constant CONTENT_HASH = keccak256("prediction-content");
    bytes32 internal constant OPTIONS_HASH = keccak256("prediction-options");
    bytes32 internal constant RESULT_HASH = keccak256("prediction-result");
    bytes32 internal constant JUDGEMENT_ROOT = keccak256("judgement-root");
    bytes32 internal constant JUDGEMENT_COUNTS_HASH = keccak256("judgement-counts");

    function setUp() public {
        nft = new AgentNFTMock();
        bindingRegistry = new BindingRegistryStatusMock();
        nft.mint(alice, 11);
        nft.mint(bob, 12);
        bindingRegistry.setBound(11, true);
        bindingRegistry.setBound(12, true);

        vm.startPrank(admin);
        registry = _deployRegistry();
        vm.stopPrank();
    }

    function test_Initialize_InitialState() public view {
        assertEq(address(registry.nft()), address(nft));
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.MANAGER_ROLE(), manager));
        assertTrue(registry.hasRole(registry.RESULT_PUBLISHER_ROLE(), resultPublisher));
        assertTrue(registry.hasRole(registry.SNAPSHOT_PUBLISHER_ROLE(), snapshotPublisher));
        assertEq(registry.nextPredictionId(), 1);
    }

    function test_OpenPrediction_StoresThinMeta() public {
        uint64 closeAt = uint64(block.timestamp + 1 days);

        vm.prank(manager);
        vm.expectEmit(true, true, false, true, address(registry));
        emit PredictionOpened(1, TOPIC_HASH, uint64(block.timestamp), closeAt, 2, CONTENT_HASH, OPTIONS_HASH);
        uint256 predictionId = registry.openPrediction(TOPIC_HASH, CONTENT_HASH, closeAt, 2, OPTIONS_HASH);

        assertEq(predictionId, 1);

        EvoPredictionRegistry.PredictionMeta memory meta = registry.getPredictionMeta(predictionId);
        assertEq(meta.openedAt, block.timestamp);
        assertEq(meta.closeAt, closeAt);
        assertEq(meta.optionCount, 2);
        assertEq(meta.topicHash, TOPIC_HASH);
        assertEq(meta.contentHash, CONTENT_HASH);
        assertEq(meta.optionsHash, OPTIONS_HASH);
    }

    function test_RecordJudgement_EmitsEventForOwner() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(registry));
        emit PredictionJudgementRecordedV2(predictionId, address(nft), 11, alice, true, 101, uint64(block.timestamp));
        registry.recordJudgement(predictionId, 11, true, 101);

        EvoPredictionRegistry.LatestJudgement memory latest = registry.getLatestJudgement(predictionId, 11);
        assertTrue(latest.exists);
        assertTrue(latest.agree);
        assertEq(latest.opinionId, 101);
        assertEq(latest.actionAt, block.timestamp);
    }

    function test_RecordJudgement_AllowsApprovedOperator() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(alice);
        nft.approve(stranger, 11);

        vm.prank(stranger);
        registry.recordJudgement(predictionId, 11, false, 202);
    }

    function test_RevertIf_RecordJudgement_Unauthorized() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(stranger);
        vm.expectRevert(EvoPredictionRegistry.Unauthorized.selector);
        registry.recordJudgement(predictionId, 11, true, 101);
    }

    function test_RevertIf_RecordJudgement_AgentNotBound() public {
        uint256 predictionId = _openDefaultPrediction();
        bindingRegistry.setBound(11, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoPredictionRegistry.AgentNotBound.selector, 11));
        registry.recordJudgement(predictionId, 11, true, 101);
    }

    function test_RecordJudgement_AllowsJudgementUpdateButKeepsSingleEffectiveState() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(alice);
        registry.recordJudgement(predictionId, 11, true, 101);

        vm.warp(block.timestamp + 5);

        vm.prank(alice);
        registry.recordJudgement(predictionId, 11, false, 202);

        EvoPredictionRegistry.LatestJudgement memory latest = registry.getLatestJudgement(predictionId, 11);
        assertTrue(latest.exists);
        assertFalse(latest.agree);
        assertEq(latest.opinionId, 202);
        assertEq(latest.actionAt, block.timestamp);
    }

    function test_RevertIf_RecordJudgement_DuplicateNoop() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(alice);
        registry.recordJudgement(predictionId, 11, true, 101);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EvoPredictionRegistry.JudgementAlreadyRecorded.selector, predictionId, 11, 101, true)
        );
        registry.recordJudgement(predictionId, 11, true, 101);
    }

    function test_PredictionOpinionLinks_AreOptionalUntilEnabled() public {
        uint256 predictionId = _openDefaultPrediction();

        assertFalse(registry.enforcesPredictionOpinionLinks(predictionId));

        vm.prank(alice);
        registry.recordJudgement(predictionId, 11, true, 777);
    }

    function test_RecordJudgement_RequiresLinkedOpinion_WhenPredictionLinksEnabled() public {
        uint256 predictionId = _openDefaultPrediction();

        vm.prank(manager);
        vm.expectEmit(true, true, false, true, address(registry));
        emit PredictionOpinionLinkUpdated(predictionId, 101, true);
        registry.setPredictionOpinionLink(predictionId, 101, true);

        assertTrue(registry.enforcesPredictionOpinionLinks(predictionId));
        assertTrue(registry.isPredictionOpinionLinked(predictionId, 101));

        vm.prank(alice);
        registry.recordJudgement(predictionId, 11, true, 101);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoPredictionRegistry.OpinionNotLinkedToPrediction.selector, predictionId, 202));
        registry.recordJudgement(predictionId, 11, false, 202);
    }

    function test_SetPredictionOpinionLinks_BatchUpdate() public {
        uint256 predictionId = _openDefaultPrediction();
        uint256[] memory opinionIds = new uint256[](2);
        opinionIds[0] = 101;
        opinionIds[1] = 202;

        vm.prank(manager);
        registry.setPredictionOpinionLinks(predictionId, opinionIds, true);

        assertTrue(registry.enforcesPredictionOpinionLinks(predictionId));
        assertTrue(registry.isPredictionOpinionLinked(predictionId, 101));
        assertTrue(registry.isPredictionOpinionLinked(predictionId, 202));

        vm.prank(manager);
        registry.setPredictionOpinionLink(predictionId, 101, false);

        assertFalse(registry.isPredictionOpinionLinked(predictionId, 101));
        assertTrue(registry.isPredictionOpinionLinked(predictionId, 202));
        assertTrue(registry.enforcesPredictionOpinionLinks(predictionId));
    }

    function test_PublishOracleResultSummary_WritesSummary() public {
        uint256 predictionId = _openDefaultPrediction();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(resultPublisher);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PredictionResultSummaryPublished(predictionId, 1, 1, 1, 2, uint64(block.timestamp), RESULT_HASH);
        registry.publishOracleResultSummary(predictionId, 1, 1, 1, 2, uint64(block.timestamp), RESULT_HASH);

        EvoPredictionRegistry.PredictionResultSummary memory result =
            registry.getPredictionResultSummary(predictionId);
        assertTrue(result.resolved);
        assertEq(result.resolutionKind, 1);
        assertEq(result.winningOptionIndex, 1);
        assertEq(result.finalStatus, 1);
        assertEq(result.finalEpoch, 2);
        assertEq(result.finalizedAt, block.timestamp);
        assertEq(result.resultHash, RESULT_HASH);
    }

    function test_PublishJudgementSnapshot_AfterClose() public {
        uint256 predictionId = _openDefaultPrediction();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(snapshotPublisher);
        vm.expectEmit(true, true, false, true, address(registry));
        emit JudgementSnapshotPublished(
            predictionId,
            JUDGEMENT_ROOT,
            2,
            JUDGEMENT_COUNTS_HASH,
            uint64(block.number),
            uint64(block.timestamp)
        );
        registry.publishJudgementSnapshot(
            predictionId, uint64(block.number), 2, JUDGEMENT_ROOT, JUDGEMENT_COUNTS_HASH
        );

        EvoPredictionRegistry.JudgementSnapshotSummary memory snapshot =
            registry.getJudgementSnapshotSummary(predictionId);
        assertTrue(snapshot.published);
        assertEq(snapshot.snapshotBlock, block.number);
        assertEq(snapshot.participantCount, 2);
        assertEq(snapshot.judgementRoot, JUDGEMENT_ROOT);
        assertEq(snapshot.judgementCountsHash, JUDGEMENT_COUNTS_HASH);
    }

    function test_BindPredictionSettlementSummary_ComputesStableHash() public {
        uint256 predictionId = _openDefaultPrediction();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(resultPublisher);
        registry.publishOracleResultSummary(predictionId, 1, 1, 1, 3, uint64(block.timestamp), RESULT_HASH);

        vm.prank(snapshotPublisher);
        registry.publishJudgementSnapshot(
            predictionId, uint64(block.number), 2, JUDGEMENT_ROOT, JUDGEMENT_COUNTS_HASH
        );

        bytes32 expected = keccak256(
            abi.encode(predictionId, RESULT_HASH, JUDGEMENT_ROOT, uint32(2), JUDGEMENT_COUNTS_HASH, uint32(3), uint8(1))
        );

        vm.expectEmit(true, true, true, true, address(registry));
        emit PredictionSettlementBound(predictionId, RESULT_HASH, JUDGEMENT_ROOT, expected, uint64(block.timestamp));
        bytes32 settlementHash = registry.bindPredictionSettlementSummary(predictionId);

        assertEq(settlementHash, expected);

        EvoPredictionRegistry.PredictionSettlementSummary memory summary =
            registry.getPredictionSettlementSummary(predictionId);
        assertTrue(summary.bound);
        assertEq(summary.boundAt, block.timestamp);
        assertEq(summary.settlementHash, expected);
    }

    function test_RevertIf_PublishOracleResultSummary_InvalidWinningOption() public {
        uint256 predictionId = _openDefaultPrediction();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(resultPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(EvoPredictionRegistry.InvalidWinningOptionIndex.selector, 3, uint32(2))
        );
        registry.publishOracleResultSummary(predictionId, 1, 3, 1, 1, uint64(block.timestamp), RESULT_HASH);
    }

    function _openDefaultPrediction() internal returns (uint256 predictionId) {
        vm.prank(manager);
        predictionId = registry.openPrediction(TOPIC_HASH, CONTENT_HASH, uint64(block.timestamp + 1 days), 2, OPTIONS_HASH);
    }

    function _deployRegistry() internal returns (EvoPredictionRegistry deployed) {
        EvoPredictionRegistry implementation = new EvoPredictionRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                EvoPredictionRegistry.initialize,
                (address(nft), address(bindingRegistry), manager, resultPublisher, snapshotPublisher)
            )
        );
        deployed = EvoPredictionRegistry(address(proxy));
    }
}
