// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EvoBindingRegistry} from "../src/EvoBindingRegistry.sol";
import {EvoUserActionRouter} from "../src/EvoUserActionRouter.sol";

/// @notice Upgrades the EvoBindingRegistry and EvoUserActionRouter proxies to the audit-fix
///         implementations. Binding first (Router forwards to it), Router second.
///         Broadcaster must hold ADMIN_ROLE on both proxies.
/// Env:
///   EVO_BINDING_REGISTRY_PROXY   binding proxy
///   EVO_USER_ACTION_ROUTER_PROXY router proxy
///   INIT_V2_REGISTRY             (optional) public ERC-8004 registry to pass to initializeV2.
///                                Set on chains where initializeV2 has NOT been called yet (BSC:
///                                pass the existing registry 0x8004A169...); leave unset / zero on
///                                chains where it already ran (0G) -- reinitializer(2) would revert.
contract UpgradeRegistriesAuditFixes is Script {
    function run() external {
        address bindingProxy = vm.envAddress("EVO_BINDING_REGISTRY_PROXY");
        address routerProxy = vm.envAddress("EVO_USER_ACTION_ROUTER_PROXY");
        address initV2Registry = vm.envOr("INIT_V2_REGISTRY", address(0));

        vm.startBroadcast();
        EvoBindingRegistry newBinding = new EvoBindingRegistry();
        bytes memory bindingInit = initV2Registry == address(0)
            ? bytes("")
            : abi.encodeCall(EvoBindingRegistry.initializeV2, (initV2Registry));
        EvoBindingRegistry(bindingProxy).upgradeToAndCall(address(newBinding), bindingInit);

        EvoUserActionRouter newRouter = new EvoUserActionRouter();
        EvoUserActionRouter(routerProxy).upgradeToAndCall(address(newRouter), "");
        vm.stopBroadcast();

        EvoBindingRegistry binding = EvoBindingRegistry(bindingProxy);
        console2.log("EvoBindingRegistry impl:  ", address(newBinding));
        console2.log("EvoUserActionRouter impl: ", address(newRouter));
        console2.log("legacyIdentityRegistry:   ", binding.legacyIdentityRegistry());
        console2.log("publicIdentityRegistry:   ", binding.publicIdentityRegistry());
        console2.log("public registry supported:", binding.isSupportedIdentityRegistry(binding.publicIdentityRegistry()));
    }
}
