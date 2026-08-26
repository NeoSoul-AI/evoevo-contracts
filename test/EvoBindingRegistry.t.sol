// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EvoBindingRegistry} from "../src/EvoBindingRegistry.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {PublicIdentityRegistryMock} from "./mocks/PublicIdentityRegistryMock.sol";

contract EvoBindingRegistryV2 is EvoBindingRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract EvoBindingRegistryTest is Test {
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

    PublicIdentityRegistryMock public nft;
    EvoBindingRegistry public bindingRegistry;

    address public admin = makeAddr("admin");
    address public signer = makeAddr("signer");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public stranger = makeAddr("stranger");

    string constant URI_1 = "ipfs://binding-agent-1";
    bytes32 constant USER_HASH_1 = keccak256("evo-user-1");
    bytes32 constant USER_HASH_2 = keccak256("evo-user-2");

    function setUp() public {
        vm.startPrank(admin);
        nft = new PublicIdentityRegistryMock();
        bindingRegistry = _deployBindingRegistry(address(nft));
        nft.setBindingRegistry(address(bindingRegistry));
        vm.stopPrank();
    }

    function test_BindExistingAgent_HappyPath() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(alice);
        bindingRegistry.bindExistingAgent(agentId, bob, USER_HASH_2);

        (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            uint256 boundAt,
            uint256 updatedAt,
            bool active,
            bool ownerStillMatches
        ) = bindingRegistry.getBinding(agentId);

        assertEq(boundOwner, alice);
        assertEq(evoAccount, bob);
        assertEq(evoUserIdHash, USER_HASH_2);
        assertGt(boundAt, 0);
        assertGt(updatedAt, 0);
        assertTrue(active);
        assertTrue(ownerStillMatches);
        assertTrue(bindingRegistry.isEvoBound(agentId));
    }

    function test_BindExistingAgentFor_HappyPath() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        address router = address(new RouterStub());

        vm.startPrank(admin);
        bindingRegistry.setTrustedRouter(router);
        vm.stopPrank();

        vm.prank(router);
        bindingRegistry.bindExistingAgentFor(alice, agentId, bob, USER_HASH_2);

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
        assertEq(evoUserIdHash, USER_HASH_2);
        assertTrue(active);
        assertTrue(ownerStillMatches);
        assertTrue(bindingRegistry.isEvoBound(agentId));
    }

    function test_Transfer_InvalidatesBindingWithoutCouplingTransferHook() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(alice);
        bindingRegistry.bindExistingAgent(agentId, carol, USER_HASH_1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, agentId);

        (
            address boundOwner,
            address evoAccount,
            ,
            ,
            ,
            bool active,
            bool ownerStillMatches
        ) = bindingRegistry.getBinding(agentId);

        assertEq(boundOwner, alice);
        assertEq(evoAccount, carol);
        assertTrue(active);
        assertFalse(ownerStillMatches);
        assertFalse(bindingRegistry.isEvoBound(agentId));
    }

    function test_Unbind_HappyPath() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(alice);
        bindingRegistry.bindExistingAgent(agentId, address(0), USER_HASH_1);

        vm.expectEmit(true, true, true, true);
        emit AgentUnboundV2(address(nft), agentId, alice, alice, alice);

        vm.prank(alice);
        bindingRegistry.unbind(agentId);

        (
            address boundOwner,
            address evoAccount,
            bytes32 evoUserIdHash,
            uint256 boundAt,
            uint256 updatedAt,
            bool active,
            bool ownerStillMatches
        ) = bindingRegistry.getBinding(agentId);

        assertEq(boundOwner, address(0));
        assertEq(evoAccount, address(0));
        assertEq(evoUserIdHash, bytes32(0));
        assertEq(boundAt, 0);
        assertEq(updatedAt, 0);
        assertFalse(active);
        assertFalse(ownerStillMatches);
        assertFalse(bindingRegistry.isEvoBound(agentId));
    }

    function test_RevertIf_UnauthorizedBindExistingAgent() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(stranger);
        vm.expectRevert(EvoBindingRegistry.Unauthorized.selector);
        bindingRegistry.bindExistingAgent(agentId, bob, USER_HASH_1);
    }

    function test_RevertIf_DirectRegisterForByBindingRegistryUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(PublicIdentityRegistryMock.Unauthorized.selector);
        nft.registerForByBindingRegistry(alice, URI_1, _emptyMetadata());
    }

    function test_DeprecatedRegistrationFlagDefaultsFalse() public {
        vm.startPrank(admin);
        EvoBindingRegistry freshBinding = _deployBindingRegistry(address(nft));
        vm.stopPrank();

        assertFalse(freshBinding.selfHostedRegistrationEnabled());
    }

    function test_RevertIf_UnauthorizedBindExistingAgentFor() public {
        vm.prank(alice);
        uint256 agentId = nft.register(URI_1);

        vm.prank(alice);
        vm.expectRevert(EvoBindingRegistry.Unauthorized.selector);
        bindingRegistry.bindExistingAgentFor(alice, agentId, bob, USER_HASH_1);
    }

    function test_RevertIf_SetTrustedRouter_NonContract() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EvoBindingRegistry.InvalidRouter.selector, stranger));
        bindingRegistry.setTrustedRouter(stranger);
    }

    function test_Upgrade_HappyPath() public {
        EvoBindingRegistryV2 nextImpl = new EvoBindingRegistryV2();

        vm.prank(admin);
        EvoBindingRegistryV2(address(bindingRegistry)).upgradeToAndCall(address(nextImpl), "");

        assertEq(EvoBindingRegistryV2(address(bindingRegistry)).version(), 2);
    }

    /// @notice Pausing a registry blocks NEW binds against it but leaves existing bindings valid
    ///         and still unbindable — the "new binds only" guarantee. Re-enabling restores binding.
    function test_PauseRegistryBinding_BlocksNewBinds_LeavesExistingValid() public {
        address reg = address(nft);
        assertFalse(bindingRegistry.bindingDisabledByRegistry(reg));

        // Existing binding made while the registry is still enabled.
        vm.prank(alice);
        uint256 boundAgent = nft.register(URI_1);
        vm.prank(alice);
        bindingRegistry.bindExistingAgent(boundAgent, bob, USER_HASH_1);
        assertTrue(bindingRegistry.isEvoBound(boundAgent));

        // A second agent registered but not yet bound.
        vm.prank(carol);
        uint256 freshAgent = nft.register(URI_1);

        // Admin pauses new binds for this registry.
        vm.prank(admin);
        bindingRegistry.setRegistryBindingDisabled(reg, true);
        assertTrue(bindingRegistry.bindingDisabledByRegistry(reg));

        // First-time binds now revert.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(EvoBindingRegistry.RegistryBindingDisabled.selector, reg));
        bindingRegistry.bindExistingAgent(freshAgent, carol, USER_HASH_2);

        // Existing binding is untouched: still valid and still readable.
        assertTrue(bindingRegistry.isEvoBound(boundAgent));

        // The owner can still UPDATE the existing binding (re-point evoAccount) while paused.
        vm.prank(alice);
        bindingRegistry.bindExistingAgent(boundAgent, carol, USER_HASH_2);
        (, address updatedEvoAccount,,,,,) = bindingRegistry.getBinding(boundAgent);
        assertEq(updatedEvoAccount, carol);
        assertTrue(bindingRegistry.isEvoBound(boundAgent));

        // And the owner can still unbind it (unbind does not pass through the guard).
        vm.prank(alice);
        bindingRegistry.unbind(boundAgent);
        assertFalse(bindingRegistry.isEvoBound(boundAgent));

        // After a full unbind, re-binding counts as new again -> still blocked while paused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EvoBindingRegistry.RegistryBindingDisabled.selector, reg));
        bindingRegistry.bindExistingAgent(boundAgent, bob, USER_HASH_1);

        // Re-enabling restores new binds.
        vm.prank(admin);
        bindingRegistry.setRegistryBindingDisabled(reg, false);
        vm.prank(carol);
        bindingRegistry.bindExistingAgent(freshAgent, carol, USER_HASH_2);
        assertTrue(bindingRegistry.isEvoBound(freshAgent));
    }

    function test_RevertIf_SetRegistryBindingDisabled_NonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        bindingRegistry.setRegistryBindingDisabled(address(nft), true);
    }

    function test_RevertIf_SetRegistryBindingDisabled_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(EvoBindingRegistry.ZeroAddress.selector);
        bindingRegistry.setRegistryBindingDisabled(address(0), true);
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
    }

    function _deployBindingRegistry(address identityRegistry) internal returns (EvoBindingRegistry deployed) {
        EvoBindingRegistry implementation = new EvoBindingRegistry();
        bytes memory initData = abi.encodeCall(EvoBindingRegistry.initialize, (identityRegistry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        deployed = EvoBindingRegistry(address(proxy));
    }
}

contract RouterStub {}
