# Task: Verify plan provenance and invariant coverage

## Context

RepoMethod already extracts reviewed, stable `obl.<anchor>` plan obligations and records append-only descopes with a canonical current state. Acceptance Mapping currently has no deterministic obligation provenance, and integration invariants are executable commands without reviewed obligation coverage metadata. Issue #5 closes those two gaps without introducing another identity or descope interpretation layer.

## Objective

The full gate deterministically verifies acceptance-to-obligation provenance, applies mode-specific orphan policy with canonical accepted descopes, and requires explicit integration-invariant coverage for reviewed obligations marked `invariant_required`.

## Definition of Ready

- Stable `obl.<anchor>` IDs remain the only obligation identity.
- The approved plan-obligation artifact remains the reviewed metadata authority.
- Canonical descope state is consumed through `descope-ledger.sh state`.
- Existing invariant command bullets remain compatible.
- Keyword heuristics are advisory only.

## Architecture and Authority Boundaries

`plan-obligations.sh` owns obligation extraction, reviewed metadata, stable IDs, and revision changes. `verify-provenance.sh` reads the approved obligation artifact, Plan Ref cells in the feature spec and its declared work packets, and canonical accepted descopes. It never parses descope prose. `verify-invariants.sh` executes invariant commands and requires an explicit obligation-bound invariant only when the reviewed obligation metadata says `invariant_required: true`. `agent-gate.sh` composes these checks after the existing plan-obligation check.

## Dependencies and Interfaces

- Plan obligation IDs remain `obl.<anchor>`.
- `invariant_required` is optional declaration metadata and normalizes to false for legacy artifacts that omit the field.
- Acceptance Mapping Plan Ref cells use one or more backticked obligation IDs separated by commas; blank/`-` means no reference.
- Work packets belong to a feature through the existing `## Work Packets` declarations and canonical `specs/packets/<id>.md` paths.
- Referenced integration invariant form: ``- `obl.<anchor>`: `<command>` ``.

## Plan Obligations

- `plan-ref-authority` [behaviour] Acceptance provenance uses only stable `obl.<anchor>` IDs, and malformed or unknown obligation references fail closed.
- `aggregate-provenance` [behaviour] [invariant_required] Provenance aggregates references across the feature spec and its declared work packets, deduplicates references, and treats accepted canonical descopes as resolved obligations.
- `mode-orphans` [behaviour] Orphan obligations warn in Classic and block in Graph.
- `invariant-metadata` [shape] [invariant_required] `invariant_required` is reviewed metadata in the existing plan-obligation artifact, and changing it creates a changed obligation revision without changing the stable ID.
- `heuristic-advisory` [prohibition] Keyword or edge-case heuristics may warn but never satisfy or fail hard invariant coverage.
- `gate-order` [process] Provenance verification runs immediately after the approved plan-obligation check while the existing downstream gate order remains unchanged.

## Scope

- `blueprint/.repomethod/scripts/plan-obligations.sh`
- `blueprint/.repomethod/scripts/verify-provenance.sh`
- `blueprint/.repomethod/scripts/verify-invariants.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/templates/spec.md`
- `blueprint/.repomethod/templates/spec-packet.md`
- `tests/blueprint_verify_provenance.bats`
- `tests/blueprint_verify_invariants.bats`
- `.github/ci/bats-shards.tsv`
- `specs/plan-provenance.md`

## Out of Scope

- A second obligation-reference namespace
- Parsing descope descriptions or rationale text
- Turning keyword heuristics into correctness gates
- Reordering existing gates beyond inserting provenance after plan-obligation verification

## Acceptance Criteria

1. Acceptance Mapping can reference one or more valid stable obligation IDs, including references distributed across declared work packets and duplicates.
2. Unknown or malformed obligation references fail closed.
3. True orphan obligations warn in Classic and block in Graph; accepted canonical descopes are excluded from untreated orphans.
4. `invariant_required` is reviewed obligation metadata, preserves stable IDs, and forces a new reviewed revision when changed.
5. Every obligation with `invariant_required: true` requires an explicitly matching integration invariant; legacy invariant bullets remain executable.
6. Error/order/edge-case keyword heuristics warn only.
7. `agent-gate.sh` invokes provenance after plan-obligation verification without otherwise reordering the existing full gate.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | `references aggregate across declared work packets and duplicates count once` | implementation | `obl.plan-ref-authority`, `obl.aggregate-provenance` |
| 2 | `unknown and malformed Plan Ref values fail closed` | implementation | `obl.plan-ref-authority` |
| 3 | `accepted canonical descopes are treated as resolved orphan obligations` | implementation | `obl.aggregate-provenance`, `obl.mode-orphans` |
| 4 | `invariant_required metadata is reviewed without changing stable obligation IDs` | obligations | `obl.invariant-metadata` |
| 5 | `invariant_required obligation needs an explicitly matching integration invariant` | invariants | `obl.invariant-metadata` |
| 6 | `error ordering and edge-case keyword lint warns only` | invariants | `obl.heuristic-advisory` |
| 7 | `agent-gate.sh runs every gate in order and reports success` | gate | `obl.gate-order` |

## Work Packets

- `implementation`: deterministic provenance parsing, aggregation, orphan policy, and canonical descope consumption
- `obligations`: reviewed `invariant_required` metadata in the existing extraction/review contract
- `invariants`: explicit invariant-to-obligation matching plus advisory heuristic lint
- `gate`: template and aggregate-gate wiring with regression coverage

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/plan-provenance.md
```

## Test Count Command

## Integration Invariants

- `obl.aggregate-provenance`: `bash -n blueprint/.repomethod/scripts/verify-provenance.sh`
- `obl.invariant-metadata`: `bash -n blueprint/.repomethod/scripts/plan-obligations.sh && bash -n blueprint/.repomethod/scripts/verify-invariants.sh`

## Expected Evidence

- `.repomethod/evidence/plan-provenance-verification.txt`

## Escalation Conditions

- stable obligation IDs cannot remain the single provenance authority
- canonical descope state lacks the accepted plan reference required for orphan treatment
- invariant coverage would require executing or heuristically interpreting spec prose
- the gate insertion would require reordering unrelated checks
