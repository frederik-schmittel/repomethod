# Portable Delivery Workflows

The installed repository exposes three delivery modes. Claude Code, Codex, a
local session, and a cloud session use the same shell commands, JSON state, and
shared skills.

## Quick MVP

Use Quick MVP for one small reversible feature with one clear test:

```bash
.repomethod/scripts/feature-workflow.sh quick-mvp
```

Record Goal, Scope, and Test in three bullets or fewer. Implement in the current
context, run the targeted test, and allow at most one correction. Quick MVP
creates no persistent state, so it has no pinned base and determines its diff
base at every gate with `resolve_base` (`@{upstream}` / `origin/HEAD` / `main`).

## Classic

Classic is the short Loop Engineering path:

```bash
.repomethod/scripts/feature-workflow.sh classic init \
  --feature example \
  --verify-command ".repomethod/scripts/agent-gate.sh --spec <spec>" \
  --max-retries 1
```

It creates this bounded workflow:

```text
Implementation -> Verification command -> Completion
                       failure -> Fix-N -> Verification-N
```

Start and complete implementation work with durable output and evidence:

```bash
STATE=.repomethod/workflows/example.json

.repomethod/scripts/workflow-graph.sh start --state "$STATE" --node implementation
.repomethod/scripts/workflow-graph.sh complete --state "$STATE" --node implementation \
  --output .repomethod/evidence/implementation.md \
  --evidence .repomethod/evidence/implementation-test.txt
```

Run verification through the runner. A generic `complete` cannot mark a
Verification node as passed.

```bash
.repomethod/scripts/workflow-graph.sh verify --state "$STATE" --node verification \
  --evidence .repomethod/evidence/verification.txt
```

The command exit status controls the transition. Status 0 unlocks Completion.
A nonzero status creates Fix-N and Verification-N until the retry limit is
exhausted.

## Graph

Graph Engineering adds evidence-based discovery and approval before execution:

```text
discovering:       Research -> Plan
                                  |
awaiting_approval: proposed execution DAG -> developer approval
                                                   |
active:      Implementation DAG -> Verification loop -> Plan conformance -> Completion
```

Initialize a single Research node:

```bash
.repomethod/scripts/feature-workflow.sh graph init \
  --feature example \
  --research single \
  --max-parallel 2 \
  --sequential-fallback allow \
  --verify-command ".repomethod/scripts/agent-gate.sh --spec <spec>"
```

Use `--research parallel` to create independent architecture, test, and risk
research nodes joined by Plan. `dispatch` respects `--max-parallel` in both
discovery and execution.

The initial state is `discovering`, so Research runs before any approval:

```bash
.repomethod/scripts/workflow-graph.sh dispatch --state "$STATE"
.repomethod/scripts/workflow-graph.sh start --state "$STATE" --node research
.repomethod/scripts/workflow-graph.sh complete --state "$STATE" --node research \
  --output .repomethod/evidence/research.md \
  --evidence .repomethod/evidence/research-checks.txt

.repomethod/scripts/workflow-graph.sh start --state "$STATE" --node plan
.repomethod/scripts/workflow-graph.sh complete --state "$STATE" --node plan \
  --output .repomethod/evidence/plan.md \
  --evidence .repomethod/evidence/plan-checks.txt
```

Completing Plan changes the state to `awaiting_approval`. Only this phase allows
execution-graph edits:

```bash
.repomethod/scripts/workflow-graph.sh add-task --state "$STATE" \
  --id api --goal "Implement API"
.repomethod/scripts/workflow-graph.sh add-task --state "$STATE" \
  --id ui --goal "Implement UI"
.repomethod/scripts/workflow-graph.sh set-retries --state "$STATE" --max-retries 1
.repomethod/scripts/workflow-graph.sh preview --state "$STATE"
```

`add-node`, `edit-node`, `remove-node`, and `add-task` support custom DAGs and
human gates. The runner rejects missing dependencies, cycles, and graphs that
do not connect Plan, Implementation, Verification, and Completion.

Show one final preview. Preserve the developer's exact approval text and exact
displayed revision:

```bash
.repomethod/scripts/workflow-graph.sh approve-and-dispatch --state "$STATE" \
  --revision 3 \
  --approval-text "Passt, leg los."
```

Approval freezes the graph and changes the state to `active`. A stale revision
fails. `--state` may be omitted only when exactly one workflow is waiting for
approval.

Execute returned nodes with `start` and `complete`. Run Verification nodes with
`verify`. Independent nodes can run concurrently up to `config.max_parallel`.
When a host cannot create parallel workers, follow
`config.sequential_fallback`; `block` means stop instead of serializing.

In Graph mode a passing Verification does not unlock Completion directly. It
unlocks a required `plan-conformance` node that reviews the full feature diff
against the approved plan with a fixed rubric, in a fresh reviewer context.
Record its verdict with `conform`; a blocked verdict opens a bounded
`conformance-fix-N -> conformance-verification-N -> plan-conformance-N` retry
chain. See [PLAN_CONFORMANCE.md](PLAN_CONFORMANCE.md). Classic and Quick MVP
have no such boundary.

## Descopes

Every Classic or Graph workflow initializes two feature-scoped files beside its
state:

```text
.repomethod/workflows/<feature>.descopes.jsonl
.repomethod/workflows/<feature>.descopes.checkpoint.json
```

The JSONL file is an append-only event log. A created descope carries a stable
`descope.<anchor>` ID, its stable `obl.<anchor>` plan reference, description,
rationale, owner, and initial `unreviewed` status. Review decisions append a new
event; earlier events are never rewritten:

```bash
.repomethod/scripts/descope-ledger.sh add --state "$STATE" \
  --id descope.api --plan-ref obl.api \
  --description "omit API packet" --rationale "deferred by reviewer" --owner "team"

.repomethod/scripts/descope-ledger.sh review --state "$STATE" \
  --id descope.api --status accepted \
  --rationale "approved for this delivery" --owner "reviewer"
```

Each event is hash-chained. The deterministic checkpoint records the expected
event count and tail hash, so edited events and ledger truncation fail closed.
`descope-ledger.sh state --state "$STATE"` is the canonical machine-readable
current-state derivation used by handoff and delivery. `unreviewed` and
`rejected` IDs appear in `blocking_ids` and prevent `DELIVERY: done`; accepted
descopes remain in the derived state and handoff for provenance.

## State and portability

State lives under `.repomethod/workflows/`. Outputs and command logs live
under `.repomethod/evidence/`. These paths are recognized as workflow
metadata by `verify-scope`; unrelated files under `.repomethod/` still
need explicit Scope.

`init` resolves the fork point once and stores it in the state as
`config.base_ref` (a 40-character commit SHA). Every later scope decision reads
that SHA instead of re-resolving; pass `--base <ref>` to `init` only to override
the automatic choice.

If the feature spec declares `## Source Intent` (see
[INTENT_LINEAGE.md](INTENT_LINEAGE.md)), `init` validates that binding before it
writes state and stores the exact canonical object as `intent_lineage`. Every
stateful subcommand then reverifies it through `intent-lineage.sh check --state`
and fails closed on a stale, substituted, or spec-mismatched binding. `status`,
`preview`, and the handoff sidecar surface `intent=<path>` for a bound workflow;
a legacy workflow has no `intent_lineage` key and is unchanged.

Each dispatch entry contains the node goal, role, dependencies, completed
dependency artifacts, and whether fresh verification context is required. A
new session resumes with:

```bash
.repomethod/scripts/workflow-graph.sh status --state "$STATE"
.repomethod/scripts/workflow-graph.sh dispatch --state "$STATE"
```

The runner contains no provider API, queue, daemon, graph database, or worker
registry. Agent hosts execute nodes; the repository stores the common contract.

## Stops

Use `block` for missing authority, inputs, or evidence. Human-gated nodes use
`approve` or `reject`. Stop on protected paths, unresolved security or
architecture choices, stale approval, or exhausted verification retries.
