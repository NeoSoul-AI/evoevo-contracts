// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEvoBindingRegistryIdentity} from "../../src/interfaces/IEvoBindingRegistryIdentity.sol";

contract PublicIdentityRegistryMock is IEvoBindingRegistryIdentity {
    error Unauthorized();
    error ZeroAddress();
    error NonexistentToken(uint256 tokenId);

    address public bindingRegistry;
    uint256 public nextTokenId = 1;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => address) private _agentWallets;
    mapping(uint256 => mapping(bytes32 => bytes)) private _metadata;

    function setBindingRegistry(address nextBindingRegistry) external {
        bindingRegistry = nextBindingRegistry;
    }

    function register() external returns (uint256 agentId) {
        return _register(msg.sender, "");
    }

    function register(string calldata agentURI) external returns (uint256 agentId) {
        return _register(msg.sender, agentURI);
    }

    function register(string calldata agentURI, MetadataEntry[] calldata metadata)
        external
        returns (uint256 agentId)
    {
        agentId = _register(msg.sender, agentURI);
        _writeMetadata(agentId, metadata);
    }

    function registerForByBindingRegistry(address to, string calldata agentURI, MetadataEntry[] calldata metadata)
        external
        returns (uint256 agentId)
    {
        if (msg.sender != bindingRegistry) revert Unauthorized();
        agentId = _register(to, agentURI);
        _writeMetadata(agentId, metadata);
    }

    function approve(address to, uint256 tokenId) external {
        if (msg.sender != ownerOf(tokenId)) revert Unauthorized();
        _approvals[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        if (tokenOwner != from || to == address(0)) revert Unauthorized();
        if (
            msg.sender != tokenOwner && _approvals[tokenId] != msg.sender
                && !_operatorApprovals[tokenOwner][msg.sender]
        ) revert Unauthorized();
        _owners[tokenId] = to;
        _approvals[tokenId] = address(0);
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address operator) {
        ownerOf(tokenId);
        return _approvals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool approved) {
        return _operatorApprovals[owner][operator];
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        _requireController(msg.sender, agentId);
        _tokenURIs[agentId] = newURI;
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        ownerOf(agentId);
        return _metadata[agentId][keccak256(bytes(metadataKey))];
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        _requireController(msg.sender, agentId);
        _metadata[agentId][keccak256(bytes(metadataKey))] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    function setAgentWallet(uint256 agentId, address newWallet, uint256, bytes calldata) external {
        _requireController(msg.sender, agentId);
        if (newWallet == address(0)) revert ZeroAddress();
        _agentWallets[agentId] = newWallet;
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        ownerOf(agentId);
        address wallet = _agentWallets[agentId];
        return wallet == address(0) ? _owners[agentId] : wallet;
    }

    function unsetAgentWallet(uint256 agentId) external {
        _requireController(msg.sender, agentId);
        delete _agentWallets[agentId];
    }

    function _register(address to, string memory agentURI) internal returns (uint256 agentId) {
        if (to == address(0)) revert ZeroAddress();
        agentId = nextTokenId++;
        _owners[agentId] = to;
        _tokenURIs[agentId] = agentURI;
        emit Registered(agentId, agentURI, to);
    }

    function _writeMetadata(uint256 agentId, MetadataEntry[] calldata metadata) internal {
        for (uint256 i = 0; i < metadata.length; i++) {
            _metadata[agentId][keccak256(bytes(metadata[i].metadataKey))] = metadata[i].metadataValue;
            emit MetadataSet(agentId, metadata[i].metadataKey, metadata[i].metadataKey, metadata[i].metadataValue);
        }
    }

    function _requireController(address operator, uint256 tokenId) internal view {
        address tokenOwner = ownerOf(tokenId);
        if (
            operator != tokenOwner && _approvals[tokenId] != operator
                && !_operatorApprovals[tokenOwner][operator]
        ) revert Unauthorized();
    }
}
