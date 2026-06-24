# EvoEvo Contracts

EvoEvo Contracts contains the onchain business layer for EvoEvo agent workflows:
agent identity binding, reasoning commitments, prediction judgement, and
committee settlement.

The contracts can use an external onchain agent identity registry as the
identity source while keeping EvoEvo-specific product logic in separate
registries.

## Relationship To ERC-8004

EvoEvo Contracts do not replace the ERC-8004 identity registry.

ERC-8004 is used as the public onchain identity layer for agents: it defines
the agent id, owner or approved operator, metadata, URI, and agent wallet.

EvoEvo adds an application layer on top of ERC-8004:

- binding an ERC-8004 agent identity into EvoEvo product state
- recording reasoning, opinion, and memory commitments
- recording prediction judgements from bound agents
- publishing prediction and oracle result summaries
- coordinating committee-based settlement

For this reason, EvoEvo identifies an external agent by:

```text
(chain_id, identity_registry_address, identity_agent_id)
```

A bare token id is never treated as globally unique.

| Layer | Responsibility |
| --- | --- |
| ERC-8004 Identity Registry | Agent identity, ownership, metadata, URI, wallet |
| EvoEvo Contracts | Binding, commitments, prediction judgements, oracle settlement |
| EvoEvo Agent Kit | Offchain client flow for external agents |

## Contracts

- `EvoBindingRegistry`: binds an onchain agent identity into EvoEvo.
- `EvoEvolutionRegistry`: records reasoning and memory commitments.
- `EvoUserActionRouter`: wallet-facing router for user actions.
- `EvoPredictionRegistry`: records prediction metadata, judgement events, and
  result summaries.
- `EvoCommitteeOracle`: committee selection and settlement workflow.

## Identity Model

EvoEvo separates product identity from onchain identity.

Product identity:

```text
platform_agent_id
```

External onchain identity:

```text
chain_id
identity_registry_address
identity_agent_id
```

The external identity key is:

```text
(chain_id, identity_registry_address, identity_agent_id)
```

Do not treat a bare token id as globally unique across chains or registries.

## Quick Start

Install dependencies:

```bash
make deps
```

Build:

```bash
make build
```

Run tests:

```bash
make test
```

Export ABIs:

```bash
make abi-export
```

## Deployment

The main deployment script is:

```text
script/DeployFullStackPublicIdentity.s.sol
```

It expects an existing onchain identity registry address:

```text
EXTERNAL_IDENTITY_REGISTRY_ADDRESS
```

The deployment uses UUPS proxies. Downstream applications should consume proxy
addresses, not implementation addresses.

## License

MIT
