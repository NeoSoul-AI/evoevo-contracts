// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC8004IdentityRegistry
/// @notice ERC-8004 Identity Registry interface.
interface IERC8004IdentityRegistry {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue);

    function register() external returns (uint256 agentId);

    function register(string calldata agentURI) external returns (uint256 agentId);

    function register(string calldata agentURI, MetadataEntry[] calldata metadata)
        external
        returns (uint256 agentId);

    function setAgentURI(uint256 agentId, string calldata newURI) external;

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory);

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external;

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata authorization)
        external;

    function getAgentWallet(uint256 agentId) external view returns (address);

    function unsetAgentWallet(uint256 agentId) external;
}
