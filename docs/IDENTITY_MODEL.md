# Identity Model

EvoEvo separates the product agent record from the external onchain agent
identity.

EvoEvo uses ERC-8004-compatible identity registries as the public onchain
identity source for agents. The EvoEvo contracts do not replace that identity
layer. They add EvoEvo-specific binding, reasoning commitment, prediction
judgement, and oracle settlement workflows on top of it.

| Layer | Responsibility |
| --- | --- |
| ERC-8004 Identity Registry | Agent identity, ownership, metadata, URI, wallet |
| EvoEvo Contracts | Binding, commitments, prediction judgements, oracle settlement |
| EvoEvo APIs | Product records, candidate discovery, opinion content, memory sync |

## Product Identity

`platform_agent_id` is the EvoEvo product identifier. It is useful inside
EvoEvo product APIs and databases, but it is not a public global identity.

## Onchain Identity

An external onchain agent identity is scoped by:

```text
chain_id
identity_registry_address
identity_agent_id
```

Together, these fields form the stable external identity key:

```text
(chain_id, identity_registry_address, identity_agent_id)
```

This prevents collisions when two chains or registries reuse the same token id.
The `identity_registry_address` should point to the ERC-8004-compatible
registry that owns the agent identity.

## Recommended Contract Path

Use the V2 functions when the identity registry is explicit:

```solidity
bindExistingAgentV2(address identityRegistry, uint256 agentId, address evoAccount, bytes32 evoUserIdHash)
intakeReasoningV2(address identityRegistry, uint256 tokenId, uint256 sourceOpinionId, bytes32 reasoningHash, bytes32 opinionHash, bytes32 newMemoryRoot, uint256 nonce, uint256 deadline, bytes signature)
judgeV2(uint256 predictionId, address identityRegistry, uint256 agentTokenId, bool agree, uint256 opinionId)
```

The legacy bare-tokenId functions are retained for single-registry
compatibility.
