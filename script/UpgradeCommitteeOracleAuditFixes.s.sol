// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {EvoCommitteeOracle} from "../src/EvoCommitteeOracle.sol";

/// @notice Upgrades the EvoCommitteeOracle proxy to the audit-fix implementation and
///         runs initializeV2 atomically. Broadcaster must hold ADMIN_ROLE on the proxy.
/// Env: COMMITTEE_ORACLE_PROXY=<proxy address>
contract UpgradeCommitteeOracleAuditFixes is Script {
    function run() external {
        address oracleProxy = vm.envAddress("COMMITTEE_ORACLE_PROXY");

        vm.startBroadcast();
        EvoCommitteeOracle newImplementation = new EvoCommitteeOracle();
        EvoCommitteeOracle(oracleProxy).upgradeToAndCall(
            address(newImplementation), abi.encodeCall(EvoCommitteeOracle.initializeV2, ())
        );
        vm.stopBroadcast();
    }
}
