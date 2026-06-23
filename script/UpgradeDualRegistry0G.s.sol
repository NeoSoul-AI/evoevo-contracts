// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EvoBindingRegistry} from "../src/EvoBindingRegistry.sol";
import {EvoEvolutionRegistry} from "../src/EvoEvolutionRegistry.sol";
import {EvoPredictionRegistry} from "../src/EvoPredictionRegistry.sol";
import {EvoUserActionRouter} from "../src/EvoUserActionRouter.sol";

/// @title UpgradeDualRegistry0G
/// @notice In-place UUPS upgrade of the Evo stack to add dual identity-registry support
///         (legacy self-hosted registry + public ERC-8004 registry) on one chain.
///
/// @dev Upgrade ORDER matters and is enforced by this script:
///   1. EvoBindingRegistry first, with `initializeV2(publicIdentityRegistry)` to seed the
///      registry allowlist (legacy + public). The other registries depend on its
///      `isSupportedIdentityRegistry` / `isEvoBoundV2` surface.
///   2. EvoEvolutionRegistry, 3. EvoPredictionRegistry (empty-calldata upgrades; no new scalar state).
///   4. EvoUserActionRouter last (its V2 forwarders call functions that must already exist downstream).
///
/// On single-registry chains (e.g. BSC, already on the public registry), set
/// PUBLIC_IDENTITY_REGISTRY to the registry the binding registry was initialized with; the
/// allowlist then has one entry and the V2 entrypoints alias the legacy storage.
///
/// Required env (read from the active `.env`):
///   PRIVATE_KEY                  deployer/admin key holding ADMIN_ROLE on the proxies
///   EVO_BINDING_REGISTRY_PROXY
///   EVO_EVOLUTION_REGISTRY_PROXY
///   EVO_PREDICTION_REGISTRY_PROXY
///   EVO_USER_ACTION_ROUTER_PROXY
///   PUBLIC_IDENTITY_REGISTRY     public ERC-8004 identity registry address
contract UpgradeDualRegistry0G is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address bindingProxy = vm.envAddress("EVO_BINDING_REGISTRY_PROXY");
        address evolutionProxy = vm.envAddress("EVO_EVOLUTION_REGISTRY_PROXY");
        address predictionProxy = vm.envAddress("EVO_PREDICTION_REGISTRY_PROXY");
        address routerProxy = vm.envAddress("EVO_USER_ACTION_ROUTER_PROXY");
        address publicRegistry = vm.envAddress("PUBLIC_IDENTITY_REGISTRY");

        require(publicRegistry != address(0), "PUBLIC_IDENTITY_REGISTRY unset");

        vm.startBroadcast(deployerKey);

        // 1. Binding registry first (provides isEvoBoundV2 + allowlist the others depend on).
        EvoBindingRegistry newBinding = new EvoBindingRegistry();
        EvoBindingRegistry(bindingProxy).upgradeToAndCall(
            address(newBinding), abi.encodeCall(EvoBindingRegistry.initializeV2, (publicRegistry))
        );

        // 2 & 3. Evolution + Prediction (no new scalar state -> empty init calldata).
        EvoEvolutionRegistry newEvolution = new EvoEvolutionRegistry();
        EvoEvolutionRegistry(evolutionProxy).upgradeToAndCall(address(newEvolution), "");

        EvoPredictionRegistry newPrediction = new EvoPredictionRegistry();
        EvoPredictionRegistry(predictionProxy).upgradeToAndCall(address(newPrediction), "");

        // 4. Router last (forwards to V2 functions that must already exist downstream).
        EvoUserActionRouter newRouter = new EvoUserActionRouter();
        EvoUserActionRouter(routerProxy).upgradeToAndCall(address(newRouter), "");

        vm.stopBroadcast();

        console2.log("EvoBindingRegistry impl:   ", address(newBinding));
        console2.log("EvoEvolutionRegistry impl: ", address(newEvolution));
        console2.log("EvoPredictionRegistry impl:", address(newPrediction));
        console2.log("EvoUserActionRouter impl:  ", address(newRouter));
        console2.log("publicIdentityRegistry:    ", publicRegistry);
        console2.log("legacyIdentityRegistry:    ", EvoBindingRegistry(bindingProxy).legacyIdentityRegistry());
    }
}
