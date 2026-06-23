// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentOwnership
/// @notice Minimal ERC-721 ownership and approval surface required by Evo business contracts.
interface IAgentOwnership {
    function ownerOf(uint256 tokenId) external view returns (address owner);

    function getApproved(uint256 tokenId) external view returns (address operator);

    function isApprovedForAll(address owner, address operator) external view returns (bool approved);
}
