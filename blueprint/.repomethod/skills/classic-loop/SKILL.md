---
name: classic-loop
description: Use for direct feature delivery that needs an implementation and a bounded command-backed verification loop without a research graph.
---

# Classic Loop

Create the task spec, then initialize the loop:

```bash
.repomethod/scripts/feature-workflow.sh classic init \
  --feature <slug> \
  --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/<slug>.md"
```

Consume the returned Implementation node. Record work with `start` and
`complete`, including durable output and evidence paths. Run Verification with:

```bash
.repomethod/scripts/workflow-graph.sh verify \
  --state <file> \
  --node verification \
  --evidence .repomethod/evidence/<feature>-verification.txt
```

The runner decides pass or failure from the configured command's exit status.
A failure creates a bounded Fix-N and Verification-N pair. Complete the fix and
run `verify` again. Complete the workflow only after verification passes.

Before ending any turn while the workflow is still active, record a handoff
and commit the plan artifacts — they are the handoff a fresh agent reads:

```bash
.repomethod/scripts/workflow-graph.sh handoff --state <file> --node <id> \
  --next "<next concrete step>" [--changed <csv>] \
  [--blocker "<what is missing>"] [--claim complete|needs_human]

git add specs/<feature>.md .repomethod/workflows .repomethod/evidence
git commit -m "wf(<feature>): <node> — <what landed>"
```

Close out with `.repomethod/scripts/deliver.sh --spec <spec> --state <file>`.
It runs the stateful gate and `supervisor.sh check` for you and prints one
`DELIVERY:` line; only `DELIVERY: done — <reason>` (exit 0) means delivered,
not the agent declaring it.

`DELIVERY: done` needs a fresh handoff (written after the last state change),
committed plan artifacts (spec, `.repomethod/workflows/`,
`.repomethod/evidence/`), and a green stateful gate — which now also runs
`verify-report` and `verify-invariants`. If the spec declares a
`## Test Count Command`, keep the report's `Tests: <n>` line current.

Stop for protected paths, missing inputs, unresolved security or architecture
decisions, human gates, blockers, or an exhausted retry limit.
