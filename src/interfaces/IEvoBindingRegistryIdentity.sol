// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentOwnership} from "./IAgentOwnership.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @title IEvoBindingRegistryIdentity
/// @notice Identity surface needed by EvoBindingRegistry in self-hosted identity mode.
interface IEvoBindingRegistryIdentity is IERC8004IdentityRegistry, IAgentOwnership {
    function registerForByBindingRegistry(
        address to,
        string calldata agentURI,
        MetadataEntry[] calldata metadata
    ) external returns (uint256 agentId);
}
