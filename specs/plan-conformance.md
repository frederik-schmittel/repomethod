# Task: Required Graph Plan Conformance

## Goal

Make Graph delivery prove that the complete feature diff still conforms to the approved plan before Completion or delivery can succeed.

## Scope

- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/scripts/plan-conformance.sh`
- `blueprint/.repomethod/scripts/supervisor.sh`
- `blueprint/.repomethod/scripts/deliver.sh`
- `blueprint/.repomethod/skills/graph-delivery/SKILL.md`
- `blueprint/.repomethod/docs/PLAN_CONFORMANCE.md`
- `blueprint/.repomethod/templates/plan-conformance-rubric.md`
- `.github/ci/bats-shards.tsv`
- `tests/plan_conformance.bats`
- related Graph, supervisor, handoff, and delivery regression tests

## Plan Obligations

- `required-node` [shape] [invariant_required] Graph execution contains a required plan-conformance boundary after Verification and before Completion.
- `pinned-review-context` [behaviour] [invariant_required] Plan conformance reviews the full feature diff from the workflow's pinned base together with the approved plan snapshot, approved plan obligations, canonical descopes, and fixed rubric.
- `verdict-contract` [shape] A conformance attempt persists a machine-readable obligation verdict table and blocker list bound to the reviewed snapshot, and `plan-conformance.sh template` emits a one-row-per-obligation skeleton for the reviewer to fill in.
- `completion-block` [prohibition] [invariant_required] Graph Completion and delivery must not succeed when plan conformance is missing, stale, blocked, or backed by invalid review authorities.
- `conformance-retry` [behaviour] A blocked conformance attempt creates a numbered fix, re-verification, and fresh plan-conformance retry chain within the bounded retry policy.
- `fresh-context` [process] A Graph plan-conformance dispatch requires fresh reviewer context and the Graph Delivery method instructs the reviewer to use only the generated context bundle and rubric.
- `supervisor-progress` [behaviour] Plan-obligation approval and plan-conformance verdict or retry changes count as supervisor progress while supervisor-owned per-check rewrites do not.
- `classic-quick-compat` [prohibition] Classic and Quick delivery behavior remains unchanged by the Graph-only conformance boundary.

## Acceptance Criteria

1. A Graph cannot complete without a current successful plan-conformance result.
2. The conformance context reviews the full feature diff from `config.base_ref`, not a re-guessed base.
3. Open blockers plus unreviewed or rejected descopes prevent a passing result; `plan-conformance.sh template` scaffolds a verdict with one blank row per approved obligation.
4. Relevant source, plan-obligation, descope, approved-plan, or rubric changes after a verdict make it stale.
5. A failed check creates traceable numbered retry nodes after re-verification.
6. Conformance dispatch requires fresh context and the handoff exposes conformance status.
7. Supervisor progress detects obligation approval and conformance state changes without counting supervisor logs/sidecars.
8. Classic and Quick behavior remains unchanged.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | `tests/plan_conformance.bats` completion boundary | main | `obl.required-node`, `obl.completion-block` |
| 2 | context snapshot/base assertions | main | `obl.pinned-review-context` |
| 3 | verdict/descope validation assertions | main | `obl.verdict-contract`, `obl.completion-block` |
| 4 | stale snapshot regression | main | `obl.pinned-review-context`, `obl.completion-block` |
| 5 | retry DAG regression | main | `obl.conformance-retry` |
| 6 | dispatch/handoff regression and Graph Delivery docs | main | `obl.fresh-context`, `obl.verdict-contract` |
| 7 | supervisor fingerprint regression | main | `obl.supervisor-progress` |
| 8 | existing Classic/Quick suites | main | `obl.classic-quick-compat` |

## Work Packets

- `main`: implement the Graph-only conformance boundary, deterministic review contract, delivery guards, and regressions.

## Integration Invariants

- `obl.required-node`: `bash -n blueprint/.repomethod/scripts/workflow-graph.sh && bash -n blueprint/.repomethod/scripts/plan-conformance.sh`
- `obl.pinned-review-context`: `bash -n blueprint/.repomethod/scripts/plan-conformance.sh`
- `obl.completion-block`: `bash -n blueprint/.repomethod/scripts/deliver.sh && bash -n blueprint/.repomethod/scripts/supervisor.sh`
