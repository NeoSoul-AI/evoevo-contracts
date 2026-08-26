// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EvoBindingRegistry} from "../src/EvoBindingRegistry.sol";
import {EvoEvolutionRegistry} from "../src/EvoEvolutionRegistry.sol";
import {EvoPredictionRegistry} from "../src/EvoPredictionRegistry.sol";
import {EvoUserActionRouter} from "../src/EvoUserActionRouter.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {PublicIdentityRegistryMock} from "./mocks/PublicIdentityRegistryMock.sol";

contract EvoUserActionRouterTest is Test {
    event AgentBound(
        uint256 indexed agentId,
        address indexed boundOwner,
        address indexed evoAccount,
        bytes32 evoUserIdHash,
        address actor
    );
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
    event PredictionJudgementRecorded(
        uint256 indexed predictionId,
        uint256 indexed agentTokenId,
        address indexed actor,
        bool agree,
        uint256 opinionId,
        uint64 actionAt
    );
    event AgentBoundV2(
        address indexed identityRegistry,
        uint256 indexed agentId,
        address indexed boundOwner,
        address evoAccount,
        bytes32 evoUserIdHash,
        address actor
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
    event PredictionJudgementRecordedV2(
        uint256 indexed predictionId,
        address indexed identityRegistry,
        uint256 indexed agentTokenId,
        address actor,
        bool agree,
        uint256 opinionId,
        uint64 actionAt
    );

    PublicIdentityRegistryMock internal nft;
    EvoBindingRegistry internal bindingRegistry;
    EvoEvolutionRegistry internal evolutionRegistry;
    EvoPredictionRegistry internal ownerJudgementRegistry;
    EvoUserActionRouter internal router;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal resultPublisher = makeAddr("resultPublisher");
    address internal snapshotPublisher = makeAddr("snapshotPublisher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    bytes32 internal constant TOPIC_HASH = keccak256("topic-hash");
    bytes32 internal constant CONTENT_HASH = keccak256("content-hash");
    bytes32 internal constant OPTIONS_HASH = keccak256("options-hash");
    bytes32 internal constant REASONING_HASH = keccak256("reasoning-hash");
    bytes32 internal constant OPINION_HASH = keccak256("opinion-hash");
    bytes32 internal constant MEMORY_ROOT = keccak256("memory-root");
    string internal constant URI_1 = "ipfs://agent-1";

    function setUp() public {
        signer = vm.addr(signerPk);

        vm.startPrank(admin);
        nft = new PublicIdentityRegistryMock();
        bindingRegistry = _deployBindingRegistry(address(nft));
        evolutionRegistry = _deployEvolutionRegistry(address(nft), signer);
        ownerJudgementRegistry =
            _deployOwnerJudgementRegistry(address(nft), manager, resultPublisher, snapshotPublisher);
        router = _deployRouter(address(evolutionRegistry), address(ownerJudgementRegistry));
        router.setBindingRegistry(address(bindingRegistry));
        bindingRegistry.setTrustedRouter(address(router));
        evolutionRegistry.setTrustedRouter(address(router));
        ownerJudgementRegistry.setTrustedRouter(address(router));
        vm.stopPrank();
    }

    function test_BindExistingAgent_RoutedActorPreserved() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.expectEmit(true, true, true, true, address(bindingRegistry));
        emit AgentBoundV2(address(nft), agentId, alice, bob, bytes32(uint256(202)), alice);

        vm.prank(alice);
        router.bindExistingAgent(agentId, bob, bytes32(uint256(202)));

        (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            ,
            ,
            bool active,
            bool ownerStillMatches
        ) = bindingRegistry.getBinding(agentId);

        assertEq(boundOwner, alice);
        assertEq(evoAccount, bob);
        assertEq(evoUserIdHash, bytes32(uint256(202)));
        assertTrue(active);
        assertTrue(ownerStillMatches);
        assertTrue(bindingRegistry.isEvoBound(agentId));
    }

    /// @notice Pausing a registry on the binding registry propagates through the router's forwarder
    ///         (the router holds no binding logic; it reverts transitively at `_bindV2`).
    function test_BindExistingAgent_RevertsWhenRegistryBindingPaused() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(admin);
        bindingRegistry.setRegistryBindingDisabled(address(nft), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoBindingRegistry.RegistryBindingDisabled.selector, address(nft)));
        router.bindExistingAgent(agentId, bob, bytes32(uint256(202)));
    }

    function test_IntakeReasoning_RoutedActorPreserved() public {
        _registerAndBindViaRouter(alice, URI_1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature =
            _signReasoningIntake(alice, 1, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline);

        vm.expectEmit(true, true, true, true, address(evolutionRegistry));
        emit ReasoningIntakeCommittedV2(address(nft), 1, alice, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, signer, 0);

        vm.prank(alice);
        router.intakeReasoning(1, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline, signature);

        assertEq(evolutionRegistry.evolutionNonces(1), 1);
    }

    function test_RevertIf_IntakeReasoning_AgentNotBound() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature =
            _signReasoningIntake(alice, agentId, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoEvolutionRegistry.AgentNotBound.selector, agentId));
        router.intakeReasoning(agentId, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline, signature);
    }

    function test_Judge_RoutedActorPreserved() public {
        _registerAndBindViaRouter(alice, URI_1);
        uint256 predictionId = _openPrediction();

        vm.expectEmit(true, true, true, true, address(ownerJudgementRegistry));
        emit PredictionJudgementRecordedV2(predictionId, address(nft), 1, alice, true, 101, uint64(block.timestamp));

        vm.prank(alice);
        router.judge(predictionId, 1, true, 101);
    }

    function test_Judge_RoutedApprovedOperatorAllowed() public {
        _registerAndBindViaRouter(alice, URI_1);
        uint256 predictionId = _openPrediction();

        vm.prank(alice);
        nft.approve(bob, 1);

        vm.prank(bob);
        router.judge(predictionId, 1, false, 202);
    }

    function test_RevertIf_Judge_AgentNotBound() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);
        uint256 predictionId = _openPrediction();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoPredictionRegistry.AgentNotBound.selector, agentId));
        router.judge(predictionId, agentId, true, 101);
    }

    function test_RevertIf_TargetRouterTrustMissing() public {
        _registerAndBindViaRouter(alice, URI_1);
        uint256 predictionId = _openPrediction();

        vm.prank(admin);
        ownerJudgementRegistry.setTrustedRouter(address(0));

        vm.prank(alice);
        vm.expectRevert(EvoPredictionRegistry.Unauthorized.selector);
        router.judge(predictionId, 1, true, 101);
    }

    function test_RevertIf_BindExistingAgent_BindingRouterTrustMissing() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(admin);
        bindingRegistry.setTrustedRouter(address(0));

        vm.prank(alice);
        vm.expectRevert(EvoBindingRegistry.Unauthorized.selector);
        router.bindExistingAgent(agentId, bob, bytes32(uint256(202)));
    }

    function test_RevertIf_BindExistingAgent_BindingRegistryNotConfigured() public {
        EvoUserActionRouter unconfiguredRouter;
        vm.startPrank(admin);
        unconfiguredRouter = _deployRouter(address(evolutionRegistry), address(ownerJudgementRegistry));
        vm.stopPrank();

        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(alice);
        vm.expectRevert(EvoUserActionRouter.BindingRegistryNotConfigured.selector);
        unconfiguredRouter.bindExistingAgent(agentId, bob, bytes32(uint256(202)));
    }

    function _registerAndBindViaRouter(address actor, string memory uri) internal returns (uint256) {
        vm.prank(actor);
        uint256 agentId = nft.register(uri);

        vm.prank(actor);
        router.bindExistingAgent(agentId, address(0), bytes32(uint256(uint160(actor))));
        return agentId;
    }

    function _openPrediction() internal returns (uint256 predictionId) {
        vm.prank(manager);
        predictionId = ownerJudgementRegistry.openPrediction(
            TOPIC_HASH, CONTENT_HASH, uint64(block.timestamp + 1 days), 2, OPTIONS_HASH
        );
    }

    function _signReasoningIntake(
        address actor,
        uint256 tokenId,
        uint256 sourceOpinionId,
        bytes32 reasoningHash,
        bytes32 opinionHash,
        bytes32 newMemoryRoot,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = evolutionRegistry.hashIntakeReasoningRequest(
            actor, tokenId, sourceOpinionId, reasoningHash, opinionHash, newMemoryRoot, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deployEvolutionRegistry(address nftAddress, address initialSigner)
        internal
        returns (EvoEvolutionRegistry deployed)
    {
        EvoEvolutionRegistry implementation = new EvoEvolutionRegistry();
        bytes memory initData =
            abi.encodeCall(EvoEvolutionRegistry.initialize, (nftAddress, address(bindingRegistry), initialSigner));
        deployed = EvoEvolutionRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
    }

    function _deployBindingRegistry(address identityRegistry) internal returns (EvoBindingRegistry deployed) {
        EvoBindingRegistry implementation = new EvoBindingRegistry();
        bytes memory initData = abi.encodeCall(EvoBindingRegistry.initialize, (identityRegistry));
        deployed = EvoBindingRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployOwnerJudgementRegistry(
        address nftAddress,
        address initialManager,
        address initialResultPublisher,
        address initialSnapshotPublisher
    ) internal returns (EvoPredictionRegistry deployed) {
        EvoPredictionRegistry implementation = new EvoPredictionRegistry();
        bytes memory initData = abi.encodeCall(
            EvoPredictionRegistry.initialize,
            (nftAddress, address(bindingRegistry), initialManager, initialResultPublisher, initialSnapshotPublisher)
        );
        deployed = EvoPredictionRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRouter(address evolutionRegistryAddress, address ownerJudgementRegistryAddress)
        internal
        returns (EvoUserActionRouter deployed)
    {
        EvoUserActionRouter implementation = new EvoUserActionRouter();
        bytes memory initData =
            abi.encodeCall(EvoUserActionRouter.initialize, (evolutionRegistryAddress, ownerJudgementRegistryAddress));
        deployed = EvoUserActionRouter(address(new ERC1967Proxy(address(implementation), initData)));
    }
}
