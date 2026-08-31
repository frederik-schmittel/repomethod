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
Verification-N. Completion requires a passing verification command.

The JSON state is the handoff between local sessions, cloud sessions, Claude,
and Codex. Pass artifact paths through the graph instead of copied chat history.
Provider-specific worker creation stays outside the runner. That only works if
the artifacts are committed: after research, after plan approval, and after
every node, `git add specs/<feature>.md specs/packets .repomethod/workflows
.repomethod/evidence && git commit`. An untracked spec, state, packet, or
research file is invisible to a fresh clone or cloud agent.

Before ending a turn while the graph is active, record a machine-readable
handoff with `.repomethod/scripts/workflow-graph.sh handoff --state <file>
--node <id> --next "<step>" [--changed <csv>] [--blocker "<text>"] [--claim
complete|needs_human]`. Close out with
`.repomethod/scripts/deliver.sh --spec <spec> --state <file>`; it runs the
stateful gate and `supervisor.sh check`, and only `DELIVERY: done — <reason>`
(exit 0) confirms delivery. That result now also requires a fresh handoff,
committed plan artifacts, and green integration invariants
(`## Integration Invariants` in the spec).

Stop for an ambiguous approval, stale revision, protected path, missing
evidence, unresolved security or architecture decision, human gate, blocker,
or exhausted retry limit.
