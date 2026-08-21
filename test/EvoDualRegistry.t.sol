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

/// @notice End-to-end coverage for dual identity-registry support: a legacy self-hosted registry and
///         the public ERC-8004 registry sharing one Evo stack on the same chain, with colliding tokenIds.
contract EvoDualRegistryTest is Test {
    PublicIdentityRegistryMock internal legacyNft;
    PublicIdentityRegistryMock internal publicNft;
    PublicIdentityRegistryMock internal rogueNft; // never allowlisted

    EvoBindingRegistry internal binding;
    EvoEvolutionRegistry internal evolution;
    EvoPredictionRegistry internal prediction;
    EvoUserActionRouter internal router;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal publisher = makeAddr("publisher");
    address internal legacyOwner = makeAddr("legacyOwner");
    address internal publicOwner = makeAddr("publicOwner");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    bytes32 internal constant TOPIC_HASH = keccak256("topic");
    bytes32 internal constant CONTENT_HASH = keccak256("content");
    bytes32 internal constant OPTIONS_HASH = keccak256("options");
    bytes32 internal constant REASONING_HASH = keccak256("reasoning");
    bytes32 internal constant OPINION_HASH = keccak256("opinion");
    bytes32 internal constant MEMORY_ROOT = keccak256("memory");

    function setUp() public {
        signer = vm.addr(signerPk);

        vm.startPrank(admin);
        legacyNft = new PublicIdentityRegistryMock();
        publicNft = new PublicIdentityRegistryMock();
        rogueNft = new PublicIdentityRegistryMock();

        // Binding: legacy registry is the init registry; public registry seeded via initializeV2.
        EvoBindingRegistry bindingImpl = new EvoBindingRegistry();
        binding = EvoBindingRegistry(
            address(
                new ERC1967Proxy(
                    address(bindingImpl), abi.encodeCall(EvoBindingRegistry.initialize, (address(legacyNft)))
                )
            )
        );
        binding.initializeV2(address(publicNft));

        EvoEvolutionRegistry evoImpl = new EvoEvolutionRegistry();
        evolution = EvoEvolutionRegistry(
            address(
                new ERC1967Proxy(
                    address(evoImpl),
                    abi.encodeCall(EvoEvolutionRegistry.initialize, (address(legacyNft), address(binding), signer))
                )
            )
        );

        EvoPredictionRegistry predImpl = new EvoPredictionRegistry();
        prediction = EvoPredictionRegistry(
            address(
                new ERC1967Proxy(
                    address(predImpl),
                    abi.encodeCall(
                        EvoPredictionRegistry.initialize,
                        (address(legacyNft), address(binding), manager, publisher, publisher)
                    )
                )
            )
        );

        EvoUserActionRouter routerImpl = new EvoUserActionRouter();
        router = EvoUserActionRouter(
            address(
                new ERC1967Proxy(
                    address(routerImpl),
                    abi.encodeCall(EvoUserActionRouter.initialize, (address(evolution), address(prediction)))
                )
            )
        );
        router.setBindingRegistry(address(binding));
        binding.setTrustedRouter(address(router));
        evolution.setTrustedRouter(address(router));
        prediction.setTrustedRouter(address(router));
        vm.stopPrank();
    }

    // --- Allowlist seeding ---

    function test_InitializeV2_SeedsAllowlist() public view {
        assertTrue(binding.isSupportedIdentityRegistry(address(legacyNft)));
        assertTrue(binding.isSupportedIdentityRegistry(address(publicNft)));
        assertFalse(binding.isSupportedIdentityRegistry(address(rogueNft)));
        assertEq(binding.publicIdentityRegistry(), address(publicNft));
        assertEq(binding.legacyIdentityRegistry(), address(legacyNft));
    }

    function test_RevertIf_InitializeV2_NotAdmin() public {
        // 部署一份只做 V1 初始化的 registry
        EvoBindingRegistry implementation = new EvoBindingRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EvoBindingRegistry.initialize, (address(legacyNft)))
        );
        EvoBindingRegistry freshBinding = EvoBindingRegistry(address(proxy));

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        freshBinding.initializeV2(address(publicNft));
    }

    function test_Allowlist_AdminCanAddAndRemove() public {
        vm.prank(admin);
        binding.setIdentityRegistrySupported(address(rogueNft), true);
        assertTrue(binding.isSupportedIdentityRegistry(address(rogueNft)));

        vm.prank(admin);
        binding.setIdentityRegistrySupported(address(rogueNft), false);
        assertFalse(binding.isSupportedIdentityRegistry(address(rogueNft)));
    }

    function test_RevertIf_BindV2_UnsupportedRegistry() public {
        uint256 id = _mint(rogueNft, legacyOwner); // rogue registry not allowlisted
        vm.prank(legacyOwner);
        vm.expectRevert(abi.encodeWithSelector(EvoBindingRegistry.UnsupportedIdentityRegistry.selector, address(rogueNft)));
        binding.bindExistingAgentV2(address(rogueNft), id, address(0), bytes32(0));
    }

    // --- Collision isolation: same tokenId on both registries ---

    function test_Collision_BindingsIndependent() public {
        uint256 legacyId = _mint(legacyNft, legacyOwner); // == 1
        uint256 publicId = _mint(publicNft, publicOwner); // == 1, collides
        assertEq(legacyId, publicId);

        vm.prank(legacyOwner);
        binding.bindExistingAgentV2(address(legacyNft), legacyId, address(0), keccak256("legacy"));
        vm.prank(publicOwner);
        binding.bindExistingAgentV2(address(publicNft), publicId, address(0), keccak256("public"));

        assertTrue(binding.isEvoBoundV2(address(legacyNft), legacyId));
        assertTrue(binding.isEvoBoundV2(address(publicNft), publicId));

        // Unbinding the public agent must not affect the legacy agent with the same tokenId.
        vm.prank(publicOwner);
        binding.unbindV2(address(publicNft), publicId);
        assertFalse(binding.isEvoBoundV2(address(publicNft), publicId));
        assertTrue(binding.isEvoBoundV2(address(legacyNft), legacyId));
    }

    function test_Collision_NoncesIndependent() public {
        uint256 legacyId = _bindV2(legacyNft, legacyOwner);
        uint256 publicId = _bindV2(publicNft, publicOwner);
        assertEq(legacyId, publicId);

        _intakeV2(legacyNft, legacyOwner, legacyId, 0);
        assertEq(evolution.getEvolutionNonce(address(legacyNft), legacyId), 1);
        assertEq(evolution.getEvolutionNonce(address(publicNft), publicId), 0); // untouched

        _intakeV2(publicNft, publicOwner, publicId, 0);
        assertEq(evolution.getEvolutionNonce(address(publicNft), publicId), 1);
        assertEq(evolution.getEvolutionNonce(address(legacyNft), legacyId), 1); // unchanged
    }

    function test_Collision_JudgementsIndependent() public {
        uint256 legacyId = _bindV2(legacyNft, legacyOwner);
        uint256 publicId = _bindV2(publicNft, publicOwner);
        uint256 predictionId = _openPrediction();

        vm.prank(legacyOwner);
        router.judgeV2(predictionId, address(legacyNft), legacyId, true, 101);
        vm.prank(publicOwner);
        router.judgeV2(predictionId, address(publicNft), publicId, false, 202);

        EvoPredictionRegistry.LatestJudgement memory legacyJ =
            prediction.getLatestJudgementV2(predictionId, address(legacyNft), legacyId);
        EvoPredictionRegistry.LatestJudgement memory publicJ =
            prediction.getLatestJudgementV2(predictionId, address(publicNft), publicId);

        assertTrue(legacyJ.exists);
        assertTrue(legacyJ.agree);
        assertEq(legacyJ.opinionId, 101);
        assertTrue(publicJ.exists);
        assertFalse(publicJ.agree);
        assertEq(publicJ.opinionId, 202);
    }

    function test_CrossRegistry_OwnershipIsolation() public {
        uint256 legacyId = _bindV2(legacyNft, legacyOwner);
        _bindV2(publicNft, publicOwner); // public tokenId 1, owned by publicOwner

        // legacyOwner owns legacy token 1 but NOT public token 1 -> cannot judge as (public, 1).
        uint256 predictionId = _openPrediction();
        vm.prank(legacyOwner);
        vm.expectRevert(EvoPredictionRegistry.Unauthorized.selector);
        router.judgeV2(predictionId, address(publicNft), legacyId, true, 101);
    }

    // --- Legacy nonce continuity across old + V2 entrypoints ---

    function test_LegacyNonceContinuity_AcrossEntrypoints() public {
        uint256 id = _bindV2(legacyNft, legacyOwner);

        // nonce 0 via the legacy entrypoint (old typehash)
        _intakeLegacy(legacyOwner, id, 0);
        assertEq(evolution.getEvolutionNonce(address(legacyNft), id), 1);
        assertEq(evolution.evolutionNonces(id), 1); // legacy slot

        // nonce 1 via the V2 entrypoint targeting the legacy registry (shares the same slot)
        _intakeV2(legacyNft, legacyOwner, id, 1);
        assertEq(evolution.evolutionNonces(id), 2);

        // nonce 2 via the legacy entrypoint again
        _intakeLegacy(legacyOwner, id, 2);
        assertEq(evolution.evolutionNonces(id), 3);
    }

    function test_RevertIf_IntakeV2_UnsupportedRegistry() public {
        uint256 id = _mint(rogueNft, legacyOwner);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signV2(rogueNft, legacyOwner, id, 0, deadline);
        vm.prank(legacyOwner);
        vm.expectRevert(
            abi.encodeWithSelector(EvoEvolutionRegistry.UnsupportedIdentityRegistry.selector, address(rogueNft))
        );
        router.intakeReasoningV2(address(rogueNft), id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline, sig);
    }

    // --- helpers ---

    function _mint(PublicIdentityRegistryMock reg, address owner) internal returns (uint256 id) {
        vm.prank(owner);
        id = reg.register("ipfs://agent");
    }

    function _bindV2(PublicIdentityRegistryMock reg, address owner) internal returns (uint256 id) {
        id = _mint(reg, owner);
        vm.prank(owner);
        router.bindExistingAgentV2(address(reg), id, address(0), bytes32(uint256(uint160(owner))));
    }

    function _openPrediction() internal returns (uint256 predictionId) {
        vm.prank(manager);
        predictionId =
            prediction.openPrediction(TOPIC_HASH, CONTENT_HASH, uint64(block.timestamp + 1 days), 2, OPTIONS_HASH);
    }

    function _intakeLegacy(address owner, uint256 id, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = evolution.hashIntakeReasoningRequest(
            owner, id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        vm.prank(owner);
        router.intakeReasoning(id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline, abi.encodePacked(r, s, v));
    }

    function _intakeV2(PublicIdentityRegistryMock reg, address owner, uint256 id, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signV2(reg, owner, id, nonce, deadline);
        vm.prank(owner);
        router.intakeReasoningV2(
            address(reg), id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline, sig
        );
    }

    function _signV2(PublicIdentityRegistryMock reg, address owner, uint256 id, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = evolution.hashIntakeReasoningRequestV2(
            owner, address(reg), id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}

/// @notice Verifies that an in-place upgrade preserving the proxy (deploy with `initialize` only,
///         seed legacy data, then `upgradeToAndCall` + `initializeV2`) keeps existing legacy
///         bindings/nonces/judgements intact while enabling the dual-registry V2 surface.
contract EvoDualRegistryUpgradeTest is Test {
    PublicIdentityRegistryMock internal legacyNft;
    PublicIdentityRegistryMock internal publicNft;
    EvoBindingRegistry internal binding;
    EvoEvolutionRegistry internal evolution;
    EvoPredictionRegistry internal prediction;
    EvoUserActionRouter internal router;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal publisher = makeAddr("publisher");
    address internal legacyOwner = makeAddr("legacyOwner");
    address internal publicOwner = makeAddr("publicOwner");
    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    bytes32 internal constant TOPIC_HASH = keccak256("topic");
    bytes32 internal constant CONTENT_HASH = keccak256("content");
    bytes32 internal constant OPTIONS_HASH = keccak256("options");
    bytes32 internal constant REASONING_HASH = keccak256("reasoning");
    bytes32 internal constant OPINION_HASH = keccak256("opinion");
    bytes32 internal constant MEMORY_ROOT = keccak256("memory");

    function setUp() public {
        signer = vm.addr(signerPk);
        vm.startPrank(admin);
        legacyNft = new PublicIdentityRegistryMock();
        publicNft = new PublicIdentityRegistryMock();

        // Deploy with `initialize` ONLY (pre-dual-registry state) — initializeV2 deferred to the upgrade.
        binding = EvoBindingRegistry(
            address(
                new ERC1967Proxy(
                    address(new EvoBindingRegistry()),
                    abi.encodeCall(EvoBindingRegistry.initialize, (address(legacyNft)))
                )
            )
        );
        evolution = EvoEvolutionRegistry(
            address(
                new ERC1967Proxy(
                    address(new EvoEvolutionRegistry()),
                    abi.encodeCall(EvoEvolutionRegistry.initialize, (address(legacyNft), address(binding), signer))
                )
            )
        );
        prediction = EvoPredictionRegistry(
            address(
                new ERC1967Proxy(
                    address(new EvoPredictionRegistry()),
                    abi.encodeCall(
                        EvoPredictionRegistry.initialize,
                        (address(legacyNft), address(binding), manager, publisher, publisher)
                    )
                )
            )
        );
        router = EvoUserActionRouter(
            address(
                new ERC1967Proxy(
                    address(new EvoUserActionRouter()),
                    abi.encodeCall(EvoUserActionRouter.initialize, (address(evolution), address(prediction)))
                )
            )
        );
        router.setBindingRegistry(address(binding));
        binding.setTrustedRouter(address(router));
        evolution.setTrustedRouter(address(router));
        prediction.setTrustedRouter(address(router));
        vm.stopPrank();
    }

    function test_Upgrade_PreservesLegacyStateAndEnablesV2() public {
        // --- Seed legacy state via legacy entrypoints (pre-upgrade) ---
        vm.prank(legacyOwner);
        uint256 id = legacyNft.register("ipfs://legacy");
        vm.prank(legacyOwner);
        router.bindExistingAgent(id, address(0), keccak256("legacy-user"));

        _intakeLegacy(id, 0);
        _intakeLegacy(id, 1);
        assertEq(evolution.evolutionNonces(id), 2);

        vm.prank(manager);
        uint256 predictionId =
            prediction.openPrediction(TOPIC_HASH, CONTENT_HASH, uint64(block.timestamp + 1 days), 2, OPTIONS_HASH);
        vm.prank(legacyOwner);
        router.judge(predictionId, id, true, 101);

        (address boundOwnerBefore,,,,, bool activeBefore,) = binding.getBinding(id);
        assertEq(boundOwnerBefore, legacyOwner);
        assertTrue(activeBefore);

        // --- Upgrade in place (Binding first + initializeV2, then the rest) ---
        vm.startPrank(admin);
        binding.upgradeToAndCall(
            address(new EvoBindingRegistry()), abi.encodeCall(EvoBindingRegistry.initializeV2, (address(publicNft)))
        );
        evolution.upgradeToAndCall(address(new EvoEvolutionRegistry()), "");
        prediction.upgradeToAndCall(address(new EvoPredictionRegistry()), "");
        router.upgradeToAndCall(address(new EvoUserActionRouter()), "");
        vm.stopPrank();

        // --- Legacy state preserved ---
        (address boundOwnerAfter,,,,, bool activeAfter,) = binding.getBinding(id);
        assertEq(boundOwnerAfter, legacyOwner);
        assertTrue(activeAfter);
        assertTrue(binding.isEvoBound(id));
        assertEq(evolution.evolutionNonces(id), 2);
        EvoPredictionRegistry.LatestJudgement memory j = prediction.getLatestJudgement(predictionId, id);
        assertTrue(j.exists);
        assertTrue(j.agree);
        assertEq(j.opinionId, 101);

        // --- V2 surface now enabled: allowlist seeded + a colliding public agent works independently ---
        assertTrue(binding.isSupportedIdentityRegistry(address(legacyNft)));
        assertTrue(binding.isSupportedIdentityRegistry(address(publicNft)));

        vm.prank(publicOwner);
        uint256 publicId = publicNft.register("ipfs://public");
        assertEq(publicId, id); // colliding tokenId
        vm.prank(publicOwner);
        router.bindExistingAgentV2(address(publicNft), publicId, address(0), keccak256("public-user"));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = evolution.hashIntakeReasoningRequestV2(
            publicOwner, address(publicNft), publicId, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        vm.prank(publicOwner);
        router.intakeReasoningV2(
            address(publicNft), publicId, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, 0, deadline, abi.encodePacked(r, s, v)
        );

        // public nonce advanced independently; legacy nonce untouched
        assertEq(evolution.getEvolutionNonce(address(publicNft), publicId), 1);
        assertEq(evolution.getEvolutionNonce(address(legacyNft), id), 2);
    }

    function test_RevertIf_InitializeV2_CalledTwice() public {
        vm.startPrank(admin);
        binding.upgradeToAndCall(
            address(new EvoBindingRegistry()), abi.encodeCall(EvoBindingRegistry.initializeV2, (address(publicNft)))
        );
        vm.expectRevert(); // InvalidInitialization
        binding.initializeV2(address(publicNft));
        vm.stopPrank();
    }

    function _intakeLegacy(uint256 id, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = evolution.hashIntakeReasoningRequest(
            legacyOwner, id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        vm.prank(legacyOwner);
        router.intakeReasoning(id, 25, REASONING_HASH, OPINION_HASH, MEMORY_ROOT, nonce, deadline, abi.encodePacked(r, s, v));
    }
}
