# Intent Lineage

Intent lineage is an optional, deterministic link from the stable upstream
*reason* a feature exists to its technical delivery. It is opt-in per feature and
changes nothing for a feature that does not declare it.

```text
intents/<feature>.md  --pin-->  specs/<feature>.md (## Source Intent)
                                        |
                                   init --resolve
                                        v
                        .repomethod/workflows/<feature>.json (.intent_lineage)
                                        |
                    every stateful gate --check--> fail closed on drift
```

Quick MVP has no spec and no intent requirement.

## The intent artifact

`intents/<feature>.md`, created from `.repomethod/templates/intent.md`, holds only
the upstream purpose: problem, desired outcome, affected users/systems,
constraints, non-goals, open questions, and provenance. Technical implementation
detail stays in the feature spec.

## The one binding

`intent-lineage.sh` is the sole authority for intent identity. It emits and
validates exactly one representation:

```json
{"schema_version":1,"path":"intents/<feature>.md","sha256":"<64 hex of the exact intent bytes>"}
```

Generate it and paste the single line into the spec's `## Source Intent` section
inside one fenced `json` block:

```bash
.repomethod/scripts/intent-lineage.sh pin --intent intents/<feature>.md --repo .
```

No other script recomputes or reparses this identity. An untouched comment-only
`## Source Intent` section (the shipped template) means the spec has not opted in.

## Binding into workflow state

`feature-workflow.sh classic|graph init` calls `intent-lineage.sh resolve` to
validate the spec binding *before* it creates workflow state, then stores the
returned object verbatim as `.intent_lineage`. A stale or malformed intent aborts
`init` with no partial state left behind.

Every stateful `workflow-graph.sh` subcommand and `agent-gate.sh --spec --state`
forward the state to `intent-lineage.sh check --state`. That check validates the
stored binding, verifies the current `intents/<feature>.md` bytes, and confirms
the spec still carries the identical binding — resolving the repository from the
state file's own location so a relocated fresh checkout verifies against its own
artifacts. Any drift (removed, substituted, stale, or spec-mismatched binding)
fails closed.

## Surfacing

- `workflow-graph.sh status` and `preview` print `intent=<path>` for a bound workflow.
- The handoff sidecar (`<feature>.handoff.json`) carries the `intent_lineage` object.
- A legacy workflow shows none of these and behaves exactly as before.

## Changing an intent

Editing `intents/<feature>.md` invalidates the pinned identity. Re-run
`intent-lineage.sh pin`, update the spec's `## Source Intent` block, and re-run
`init` for a workflow that has already stored the old binding.
