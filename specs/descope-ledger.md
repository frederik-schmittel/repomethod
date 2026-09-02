# Task: Track descopes append-only and block delivery

## Context

Classic and Graph workflows can intentionally omit a plan obligation, but the
current repository has no durable, feature-scoped record of that decision.
Delivery therefore cannot distinguish a reviewed descope from an unreviewed or
rejected omission. GitHub issue #2 defines the feature boundary; later
plan-to-code verification and per-obligation evidence work remain separate.

## Objective

Record feature-scoped descopes as append-only events with detectable integrity,
derive one canonical current state, and block stateful delivery until every
descope is accepted.

## Definition of Ready

- Descope storage is feature-scoped under `.repomethod/workflows/`.
- Plan references use stable `obl.<anchor>` identifiers.
- Status changes append decision events instead of rewriting prior events.
- Delivery and handoff consume one canonical state derivation.
- Issue #5 and issue #6 behavior is excluded.

## Architecture and Authority Boundaries

`descope-ledger.sh` is the authority for descope persistence, validation, and
current-state derivation. The JSONL ledger is append-only; a deterministic
checkpoint records the expected event count and tail hash. `deliver.sh` and
`workflow-graph.sh handoff` consume the canonical JSON state and do not parse
the event log independently.

## Dependencies and Interfaces

- Workflow state supplies the stable feature slug.
- Plan obligations supply stable `obl.<anchor>` references.
- Handoff adds `descopes` and `open_descope_ids` from the canonical state.
- Stateful delivery blocks on current `unreviewed` or `rejected` descopes.

## Plan Obligations

- `feature-scoped-ledger` [shape] Descope events live in `.repomethod/workflows/<feature>.descopes.jsonl`; no global `.repomethod/descoped.md` is created.
- `stable-descope-identity` [shape] Each descope has a stable `descope.<anchor>` ID and a stable `obl.<anchor>` plan reference.
- `append-only-decisions` [prohibition] Existing descope events are never edited or removed by status transitions; each review appends a new decision event.
- `integrity-checkpoint` [behaviour] A deterministic integrity checkpoint makes event modification or truncation fail canonical-state validation.
- `canonical-current-state` [shape] One machine-readable command validates the ledger and derives current descopes for every consumer.
- `delivery-blocking` [behaviour] Stateful delivery is blocked while any current descope is `unreviewed` or `rejected`; accepted descopes do not block.
- `handoff-provenance` [behaviour] Handoff contains the blocking descope IDs and keeps accepted descopes visible for provenance.
- `future-issues-excluded` [prohibition] This feature does not implement issue #5 plan-to-code verification or issue #6 per-obligation evidence semantics.

## Scope

- `blueprint/.repomethod/scripts/descope-ledger.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/scripts/workflow-graph-core.sh`
- `blueprint/.repomethod/scripts/deliver.sh`
- `blueprint/.repomethod/docs/WORKFLOW_GRAPH.md`
- `blueprint/.repomethod/templates/spec-packet.md`
- `tests/blueprint_descope_ledger.bats`
- `.github/ci/bats-shards.tsv`
- `specs/descope-ledger.md`

## Out of Scope

- Plan-to-code coverage verification from issue #5.
- Per-obligation evidence aggregation from issue #6.
- A global `.repomethod/descoped.md` file.
- Changes to the plan-obligation artifact format.

## Acceptance Criteria

1. New Classic and Graph workflow states initialize a valid empty feature-scoped descope ledger and checkpoint.
2. A descope creation requires a stable ID, `obl.<anchor>` reference, description, rationale, and owner, with initial status `unreviewed`.
3. Review transitions append `accepted` or `rejected` events and leave all earlier event bytes intact.
4. Canonical-state validation detects modified events, truncated ledgers, malformed events, duplicate IDs, and missing required fields.
5. Canonical state derives multiple descopes deterministically and identifies the current blocking and accepted IDs.
6. Stateful delivery blocks on `unreviewed`, `rejected`, and invalid descope state, and can complete once all descopes are accepted.
7. Handoff exposes open descope IDs while accepted descopes remain in its provenance snapshot.
8. Workflow documentation and the work-packet template describe the descope lifecycle without introducing issue #5 or #6 behavior.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet |
| --- | --- | --- |
| 1-5 | `tests/blueprint_descope_ledger.bats` | ledger |
| 6 | `tests/blueprint_descope_ledger.bats` | delivery |
| 7 | `tests/blueprint_descope_ledger.bats` | handoff |
| 8 | `tests/blueprint_descope_ledger.bats` | docs |

## Work Packets

- `ledger`: implement and validate append-only persistence plus canonical state.
- `delivery`: route stateful delivery through canonical descope state.
- `handoff`: initialize ledgers and preserve descope provenance in handoffs.
- `docs`: document commands and packet expectations.

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/descope-ledger.md
```

## Expected Evidence

- `.repomethod/evidence/descope-ledger-tests.txt`
- `.repomethod/evidence/ci-local.txt`

## Escalation Conditions

- a change requires issue #5 or #6 semantics
- a new dependency is required
- the repository's existing shell portability contract cannot express the ledger safely
- delivery would need a second independent descope parser
