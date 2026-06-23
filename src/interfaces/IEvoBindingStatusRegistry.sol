// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEvoBindingStatusRegistry
/// @notice Minimal binding status surface required by Evo write-path registries.
interface IEvoBindingStatusRegistry {
    /// @notice Legacy single-registry binding status. Resolves against the legacy identity registry.
    function isEvoBound(uint256 agentId) external view returns (bool bound);

    /// @notice Dual-registry binding status. Resolves against the supplied identity registry.
    function isEvoBoundV2(address identityRegistry, uint256 agentId) external view returns (bool bound);

    /// @notice Whether the supplied identity registry is allowlisted for Evo write paths.
    function isSupportedIdentityRegistry(address identityRegistry) external view returns (bool supported);
}
