# Task: Add intent artifacts and end-to-end lineage

## Context

RepoMethod currently begins durable delivery at the technical feature spec. GitHub
issue #14 adds an optional upstream intent artifact so a later agent can recover
why the feature exists without requiring chat history. Stage 1 established the
canonical `intents/<feature>.md` artifact and deterministic Source Intent binding.
Stage 2 bound that exact canonical representation into existing Classic/Graph
workflow state and made state-aware verification consume the stored binding.
Stage 3 surfaces the bound lineage in `status`, `preview`, and the machine-readable
handoff, and documents the end-to-end contract.

## Objective

Provide one optional, deterministic, fail-closed intent-to-delivery lineage: an
opted-in Source Intent is pinned in the feature spec, bound into the existing
persistent workflow state, verified on every stateful gate, and visible through
status and handoff — without changing Quick MVP or creating a second
state/identity system.

## Definition of Ready

- `intents/<feature>.md` remains the only intent path convention.
- `intent-lineage.sh` remains the sole path/hash/parser authority for intent identity.
- Classic/Graph keep their existing workflow state; no sidecar state system is introduced.
- `workflow-graph.sh` and `supervisor.sh` are not split into engine/facade layers.
- Quick MVP remains stateless.
- Surfacing reuses the stored binding; it never re-derives intent identity.

## Source Intent

```json
{"path":"intents/intent-lineage.md","schema_version":1,"sha256":"0d431764f80b46340a5d681be91720a2d41196f539ac92741950e30845519634"}
```

## Architecture and Authority Boundaries

`intent-lineage.sh` is the sole authority for intent binding generation,
parsing, validation, and state-aware lineage checks. `workflow-graph.sh` remains
the existing monolithic Classic/Graph state authority: `feature-workflow.sh init`
asks `intent-lineage.sh resolve` for the already-validated canonical Source Intent
binding before it creates state, then writes that returned object into the normal
state. It never hashes or parses intent identity itself. No new state file,
facade, or workflow engine is introduced.

Every stateful `workflow-graph.sh` subcommand loads state through one path that
forwards the state to `intent-lineage.sh check --state`. The authority validates
the stored state binding first, resolves the repository-relative
`intents/<feature>.md` path from that binding, verifies its exact content
identity, and only then checks that the current spec still carries the identical
binding. `agent-gate.sh --state` forwards the same way. Callers never calculate
or parse an independent intent identity. `status`, `preview`, and `handoff` read
the already-validated `.intent_lineage` object straight out of state.

## Dependencies and Interfaces

- Intent artifacts remain Markdown at `intents/<feature>.md`.
- Feature specs optionally declare `## Source Intent` with the Stage-1 canonical JSON binding.
- An intent-enabled Classic/Graph state gains one `intent_lineage` object containing that exact binding.
- Specs/workflows without live intent lineage retain their previous behavior and state shape.
- `agent-gate.sh --state` and every stateful `workflow-graph.sh` subcommand forward the state to the canonical lineage checker.
- `status`/`preview` print `intent=<path>` and the handoff sidecar carries `intent_lineage` when a workflow is bound.
- No provider API, model call, database, queue, external tracker, or new dependency is added.

## Plan Obligations

- `intent-template` [shape] The canonical intent template contains only problem, desired outcome, affected users/systems, constraints, non-goals, open questions, and provenance/source.
- `source-intent-binding` [shape] An opted-in feature spec stores one canonical JSON binding with schema version, exact `intents/<feature>.md` path, and a lowercase SHA-256 content identity.
- `canonical-lineage-authority` [process] One script owns creation and validation of intent lineage identity; downstream callers do not implement a second hash or parser.
- `intent-validation` [behaviour] Missing, malformed, substituted, symlinked, or content-stale intent references fail closed after opt-in.
- `workflow-intent-binding` [shape] Classic/Graph initialization stores the exact canonical Source Intent binding in the existing workflow state and creates no lineage sidecar state.
- `init-order-clean` [behaviour] Initialization resolves and validates the Source Intent before workflow state is created, so a stale or malformed intent leaves no partial workflow state.
- `state-authoritative-resume` [behaviour] Stateful verification and fresh-session recovery validate the stored workflow binding first and reject any mismatch with the current spec instead of rediscovering intent identity from prose or path guesses.
- `state-intent-tamper` [behaviour] Malformed, removed, substituted, stale, or otherwise tampered stored intent bindings fail closed for every stateful `workflow-graph.sh` subcommand of an intent-enabled workflow.
- `lineage-surfaced` [shape] `status`, `preview`, and the handoff sidecar expose the bound intent path/binding for an intent-enabled workflow and stay unchanged for a legacy one.
- `legacy-spec-backcompat` [behaviour] A spec with no live Source Intent binding remains not applicable and retains prior behavior.
- `legacy-workflow-backcompat` [behaviour] Existing Classic/Graph workflows whose specs have no intent lineage remain valid without an intent binding in workflow state.
- `quick-unaffected` [prohibition] Quick MVP gains no intent artifact, spec, state, or lineage requirement.
- `no-engine-split` [prohibition] `workflow-graph.sh` and `supervisor.sh` are not split into engine/facade layers and no second workflow-state or intent-identity implementation is introduced.

## Scope

- `blueprint/.repomethod/templates/intent.md`
- `blueprint/.repomethod/templates/spec.md`
- `blueprint/.repomethod/scripts/intent-lineage.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/AGENTS.md`
- `blueprint/.repomethod/docs/WORKFLOW_GRAPH.md`
- `blueprint/.repomethod/docs/INTENT_LINEAGE.md`
- `blueprint/.repomethod/skills/graph-delivery/SKILL.md`
- `README.md`
- `tests/blueprint_intent_lineage.bats`
- `tests/workflow_intent_lineage.bats`
- `.github/ci/bats-shards.tsv`
- `intents/intent-lineage.md`
- `specs/intent-lineage.md`

## Out of Scope

- Engine/facade splits of `workflow-graph.sh` or `supervisor.sh`.
- A second intent path, hash algorithm, parser, or lineage identity representation.
- Issue #5 plan-provenance changes and issue #6 plan-conformance changes.
- External trackers, model calls, databases, queues, or hosted state.

## Acceptance Criteria

1. Classic and Graph initialization with an opted-in Source Intent persist the exact canonical binding in the existing workflow state.
2. Initialization resolves and validates the Source Intent before state is created; a stale or malformed intent aborts with no partial workflow state.
3. Every stateful `workflow-graph.sh` subcommand and `agent-gate.sh --state` consume the stored binding and reject a state/spec mismatch instead of recalculating identity in a caller.
4. A relocated fresh checkout can recover and validate `intents/<feature>.md` from repository state without relying on the recorded absolute checkout path or chat history.
5. Missing intent files, stale intent bytes, path substitution, malformed state bindings, changed state bindings, and removal of a required binding fail closed.
6. `status`, `preview`, and the handoff sidecar expose the bound intent for an intent-enabled workflow and are byte-unchanged for a legacy one.
7. Specs and Classic/Graph workflows without intent lineage retain their current behavior and state shape; Quick MVP remains stateless and never binds or requires intent lineage.
8. `workflow-graph.sh` and `supervisor.sh` remain unsplit; the feature introduces no second workflow-state system.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.workflow-intent-binding`, `obl.canonical-lineage-authority` |
| 2 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.init-order-clean` |
| 3 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.state-authoritative-resume`, `obl.state-intent-tamper`, `obl.canonical-lineage-authority` |
| 4 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.state-authoritative-resume` |
| 5 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.intent-validation`, `obl.state-intent-tamper` |
| 6 | `tests/workflow_intent_lineage.bats` | `surfacing` | `obl.lineage-surfaced` |
| 7 | `tests/blueprint_intent_lineage.bats`, `tests/workflow_intent_lineage.bats` | `foundation` | `obl.legacy-spec-backcompat`, `obl.legacy-workflow-backcompat`, `obl.quick-unaffected`, `obl.intent-template` |
| 8 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.no-engine-split`, `obl.source-intent-binding` |

## Work Packets

- `foundation`: Stage-1 intent artifact, canonical binding, spec format, and full-gate foundation.
- `workflow-binding`: bind the canonical representation into existing Classic/Graph state before init writes it, and make every stateful subcommand and resume consume it.
- `surfacing`: expose the bound lineage in `status`, `preview`, and the handoff sidecar, and document the end-to-end contract.

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/intent-lineage.md
```

## Integration Invariants

- `test -x blueprint/.repomethod/scripts/intent-lineage.sh`
- `bash -n blueprint/.repomethod/scripts/intent-lineage.sh blueprint/.repomethod/scripts/feature-workflow.sh blueprint/.repomethod/scripts/workflow-graph.sh blueprint/.repomethod/scripts/agent-gate.sh`
- `! test -e blueprint/.repomethod/scripts/workflow-graph-core.sh`
- `! test -e blueprint/.repomethod/scripts/supervisor-core.sh`

## Expected Evidence

- `.repomethod/evidence/intent-lineage-stage3.txt`

## Escalation Conditions

- The feature would require a second workflow state or intent identity implementation.
- `workflow-graph.sh` or `supervisor.sh` would need an engine/facade split.
- Quick MVP would need a spec or durable intent artifact.
