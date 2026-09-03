---
name: graph-delivery
description: Use for persistent research-first delivery where the developer approves an evidence-based execution graph before implementation.
---

# Graph Delivery

Initialize one configurable graph:

```bash
.repomethod/scripts/feature-workflow.sh graph init \
  --feature <slug> \
  --research single \
  --max-parallel 2 \
  --sequential-fallback allow \
  --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/<slug>.md"
```

Choose `--research parallel` when architecture, tests, and risks can be
investigated independently. The runner starts in `discovering`; Research is
runnable without approval. Record each Research node with `start` and
`complete`, then do the same for Plan.

Completing Plan changes the state to `awaiting_approval`. The proposed execution
graph can now be changed with `add-task`, `add-node`, `edit-node`,
`remove-node`, and `set-retries`. Show one final `preview` containing the state
path and revision. Approval must name that exact revision:

```bash
.repomethod/scripts/workflow-graph.sh approve-and-dispatch \
  --state <displayed-file> \
  --revision <displayed-revision> \
  --approval-text <exact-developer-text>
```

After approval, consume `dispatch`, run independent nodes concurrently up to
`config.max_parallel`, and persist outputs and evidence. When the host lacks
parallel workers, follow `config.sequential_fallback`; stop if it is `block`.

Run every Verification node with `verify`. The configured command's exit status
controls the result. Failure creates a bounded Fix-N followed by
Verification-N.

In Graph mode a passing Verification does **not** unlock Completion directly.
It unlocks the required `plan-conformance` node. Dispatch marks this node with
`fresh_context_required: true`; run it in a fresh reviewer context that has not
implemented the feature. Start the node to generate the authoritative review
bundle:

```bash
.repomethod/scripts/workflow-graph.sh start --state "$STATE" --node plan-conformance
```

The returned bundle pins the workflow `config.base_ref` and supplies the
approved plan snapshot, reviewed `obl.<anchor>` plan obligations, canonical
descope state, full feature diff, and
`.repomethod/templates/plan-conformance-rubric.md`. Review only those generated
authorities. Scaffold the verdict JSON with one row per approved obligation, fill
in each `status` + `rationale` and `overall`, then record it:

```bash
.repomethod/scripts/plan-conformance.sh template --state "$STATE" \
  --node plan-conformance > .repomethod/evidence/<feature>-review.json
# edit the file, then:
.repomethod/scripts/workflow-graph.sh conform --state "$STATE" \
  --node plan-conformance \
  --verdict .repomethod/evidence/<feature>-review.json
```

A passing verdict unlocks Completion only while its snapshot remains current.
Any working-tree change after the verdict — including reverting one — makes it
stale, so run conformance last and commit immediately, before touching anything
else. Any relevant diff, approved-plan, obligation, descope, or rubric change
makes that result stale. A blocked verdict creates a numbered
`conformance-fix-N -> conformance-verification-N -> plan-conformance-N` retry
chain. The retry conformance node also requires a fresh reviewer context.
Unreviewed or rejected descopes, untreated orphan obligations, or open verdict
blockers must not be waived in prose.

The JSON state is the handoff between local sessions, cloud sessions, Claude,
and Codex. Pass artifact paths through the graph instead of copied chat history.
Provider-specific worker creation stays outside the runner. That only works if
the artifacts are committed: after research, after plan approval, after every
node, and after plan conformance, `git add specs/<feature>.md specs/packets
.repomethod/workflows .repomethod/evidence && git commit`. An untracked spec,
state, packet, research file, conformance context, or verdict is invisible to a
fresh clone or cloud agent.

Before ending a turn while the graph is active, record a machine-readable
handoff with `.repomethod/scripts/workflow-graph.sh handoff --state <file>
--node <id> --next "<step>" [--changed <csv>] [--blocker "<text>"] [--claim
complete|needs_human]`. The handoff includes the current plan-conformance
status.

Close out only with `.repomethod/scripts/deliver.sh --spec <spec> --state <file>`.
It runs the stateful gate and `supervisor.sh check`, and only `DELIVERY: done — <reason>`
(exit 0) confirms delivery. For Graph workflows that also requires a current
passing plan-conformance snapshot.

Stop for an ambiguous approval, stale revision or conformance result, protected
path, missing evidence, unresolved security or architecture decision, human
gate, blocker, unreviewed/rejected descope, or exhausted retry limit.
