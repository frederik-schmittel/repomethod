# Task: Add intent artifacts and end-to-end lineage

## Context

RepoMethod currently begins durable delivery at the technical feature spec. GitHub
issue #14 adds an optional upstream intent artifact so a later agent can recover
why the feature exists without requiring chat history. Stage 1 established the
canonical `intents/<feature>.md` artifact and deterministic Source Intent binding.
Stage 2 binds that exact canonical representation into existing Classic/Graph
workflow state and makes state-aware verification consume the stored binding.
Status/handoff/closeout surfacing remains reserved for Stage 3.

## Objective

Bind an opted-in Source Intent into the existing persistent workflow state so a
fresh checkout can deterministically recover and verify the original intent,
without changing Quick MVP or creating a second state/identity system.

## Definition of Ready

- `intents/<feature>.md` remains the only intent path convention.
- `intent-lineage.sh` remains the sole path/hash/parser authority for intent identity.
- Classic/Graph keep their existing workflow state; no sidecar state system is introduced.
- `workflow-graph.sh` and `supervisor.sh` are not split into engine/facade layers.
- Quick MVP remains stateless.
- Stage 3 owns status/handoff/closeout lineage surfacing and final documentation.

## Source Intent

```json
{"path":"intents/intent-lineage.md","schema_version":1,"sha256":"0d431764f80b46340a5d681be91720a2d41196f539ac92741950e30845519634"}
```

## Architecture and Authority Boundaries

`intent-lineage.sh` is the sole authority for intent binding generation,
parsing, validation, and state-aware lineage checks. `workflow-graph.sh` remains
the existing monolithic Classic/Graph state authority: during `init` it asks
`intent-lineage.sh resolve` for the already-validated canonical Source Intent
binding and writes that returned object into the normal state. It never hashes
or parses intent identity itself. No new state file, facade, or workflow engine
is introduced.

Later stateful verification forwards the workflow state to `intent-lineage.sh`.
The authority validates the stored state binding first, resolves the repository-
relative `intents/<feature>.md` path from that binding, verifies its exact content
identity, and only then checks that the current spec still carries the identical
binding. Callers never calculate or parse an independent intent identity.

## Dependencies and Interfaces

- Intent artifacts remain Markdown at `intents/<feature>.md`.
- Feature specs optionally declare `## Source Intent` with the Stage-1 canonical JSON binding.
- An intent-enabled Classic/Graph state gains one `intent_lineage` object containing that exact binding.
- Specs/workflows without live intent lineage retain their previous behavior and state shape.
- `agent-gate.sh --state` forwards the state to the canonical lineage checker.
- No provider API, model call, database, queue, external tracker, or new dependency is added.

## Plan Obligations

- `intent-template` [shape] The canonical intent template contains only problem, desired outcome, affected users/systems, constraints, non-goals, open questions, and provenance/source.
- `source-intent-binding` [shape] An opted-in feature spec stores one canonical JSON binding with schema version, exact `intents/<feature>.md` path, and a lowercase SHA-256 content identity.
- `canonical-lineage-authority` [process] One script owns creation and validation of intent lineage identity; downstream callers do not implement a second hash or parser.
- `intent-validation` [behaviour] Missing, malformed, substituted, symlinked, or content-stale intent references fail closed after opt-in.
- `workflow-intent-binding` [shape] Classic/Graph initialization stores the exact canonical Source Intent binding in the existing workflow state and creates no lineage sidecar state.
- `state-authoritative-resume` [behaviour] Stateful verification and fresh-session recovery validate the stored workflow binding first and reject any mismatch with the current spec instead of rediscovering intent identity from prose or path guesses.
- `state-intent-tamper` [behaviour] Malformed, removed, substituted, stale, or otherwise tampered stored intent bindings fail closed for an intent-enabled workflow.
- `legacy-spec-backcompat` [behaviour] A spec with no live Source Intent binding remains not applicable and retains prior behavior.
- `legacy-workflow-backcompat` [behaviour] Existing Classic/Graph workflows whose specs have no intent lineage remain valid without an intent binding in workflow state.
- `quick-unaffected` [prohibition] Quick MVP gains no intent artifact, spec, state, or lineage requirement.
- `stage-boundary` [prohibition] Stage 2 does not add status, handoff, delivery, closeout, or final documentation lineage surfaces reserved for Stage 3.

## Scope

- `blueprint/.repomethod/templates/intent.md`
- `blueprint/.repomethod/templates/spec.md`
- `blueprint/.repomethod/scripts/intent-lineage.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/scripts/supervisor.sh`
- `blueprint/.repomethod/AGENTS.md`
- `blueprint/.repomethod/docs/WORKFLOW_GRAPH.md`
- `README.md`
- `tests/blueprint_intent_lineage.bats`
- `tests/workflow_intent_lineage.bats`
- `.github/ci/bats-shards.tsv`
- `intents/intent-lineage.md`
- `specs/intent-lineage.md`

## Out of Scope

- Stage-3 status, handoff, delivery, closeout, and final documentation surfacing.
- Engine/facade splits of `workflow-graph.sh` or `supervisor.sh`.
- A second intent path, hash algorithm, parser, or lineage identity representation.
- Issue #5 plan-provenance changes and issue #6 plan-conformance changes.
- External trackers, model calls, databases, queues, or hosted state.

## Acceptance Criteria

1. Classic and Graph initialization with an opted-in Source Intent persist the exact canonical binding in the existing workflow state.
2. Stateful lineage verification consumes the stored binding and rejects a state/spec mismatch instead of recalculating identity in a caller.
3. A relocated fresh checkout can recover and validate `intents/<feature>.md` from repository state without relying on the recorded absolute checkout path or chat history.
4. Missing intent files, stale intent bytes, path substitution, malformed state bindings, changed state bindings, and removal of a required binding fail closed.
5. Specs and Classic/Graph workflows without intent lineage retain their current behavior and state shape.
6. Quick MVP remains stateless and never binds or requires intent lineage.
7. `workflow-graph.sh` and `supervisor.sh` remain unsplit; Stage 2 introduces no second workflow-state system.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.workflow-intent-binding`, `obl.canonical-lineage-authority` |
| 2 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.state-authoritative-resume`, `obl.canonical-lineage-authority` |
| 3 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.state-authoritative-resume` |
| 4 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.intent-validation`, `obl.state-intent-tamper` |
| 5 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.legacy-spec-backcompat`, `obl.legacy-workflow-backcompat` |
| 6 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.quick-unaffected` |
| 7 | `tests/workflow_intent_lineage.bats` | `workflow-binding` | `obl.stage-boundary` |

## Work Packets

- `foundation`: Stage-1 intent artifact, canonical binding, spec format, and full-gate foundation.
- `workflow-binding`: bind the canonical Stage-1 representation into existing Classic/Graph state and make stateful verification/resume consume it.

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/intent-lineage.md
```

## Integration Invariants

- `test -x blueprint/.repomethod/scripts/intent-lineage.sh`
- `bash -n blueprint/.repomethod/scripts/intent-lineage.sh blueprint/.repomethod/scripts/workflow-graph.sh blueprint/.repomethod/scripts/agent-gate.sh`
- `! test -e blueprint/.repomethod/scripts/workflow-graph-core.sh`
- `! test -e blueprint/.repomethod/scripts/supervisor-core.sh`

## Expected Evidence

- `.repomethod/evidence/intent-lineage-stage2.txt`

## Escalation Conditions

- Stage 2 would require a second workflow state or intent identity implementation.
- `workflow-graph.sh` or `supervisor.sh` would need an engine/facade split.
- Quick MVP would need a spec or durable intent artifact.
- Stage-3 status/handoff/closeout surface work becomes necessary to make Stage 2 verification correct.
