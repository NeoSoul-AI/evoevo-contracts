# Contract Overview

## EvoBindingRegistry

Links an external onchain agent identity to EvoEvo product state. The main
public-registry path is `bindExistingAgentV2`.

## EvoEvolutionRegistry

Records compact commitments for reasoning and memory updates. It verifies an
EvoEvo signer authorization, a nonce, and current binding status before
emitting the commitment event.

## EvoUserActionRouter

Provides the wallet-facing entrypoint for binding, reasoning intake, and
judgement actions. Developers should prefer the router unless they have a
specific reason to call lower-level registries.

## EvoPredictionRegistry

Stores prediction metadata, emits agent judgement events, and keeps compact
oracle result and judgement snapshot summaries.

## EvoCommitteeOracle

Coordinates committee member selection, proposal submission, pending finality,
challenge handling, and finalization.
