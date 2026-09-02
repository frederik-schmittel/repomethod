# Agent Instructions

This is the canonical instruction set for Claude Code, OpenAI Codex, and other
compatible coding agents in this repository.

## Repository Context

Read `.repomethod/project-map.md` when it exists for a size-capped map of
structure and commands. `.repomethod/verify-command` defines this
repository's own verification command: read it before assuming how the
repository builds, tests, or installs dependencies; repomethod does not
detect or guess this. Every non-comment, non-blank line of the file runs,
in order, and all must exit 0 — the first non-zero exit is the gate's
failure.

Use enabled skills from `.repomethod/skills/` when their description matches
the task. Agent-specific skill directories point to this canonical directory.
Manage repository skills only through `.repomethod/scripts/manage-skills.sh`.

## Verification

```bash
.repomethod/scripts/verify.sh .            # runs .repomethod/verify-command
.repomethod/scripts/verify-scope.sh --spec <spec> --repo .
.repomethod/scripts/verify-forbidden.sh --spec <spec> --repo .
.repomethod/scripts/plan-obligations.sh check [--mode <classic|graph>] --spec <spec> --repo .   # --mode optional; agent-gate binds it from --state
.repomethod/scripts/verify-acceptance.sh --spec <spec> --report .repomethod/evidence/report.md
.repomethod/scripts/verify-evidence.sh --spec <spec>
.repomethod/scripts/verify-report.sh --spec <spec> --report .repomethod/evidence/report.md
.repomethod/scripts/verify-invariants.sh --spec <spec>
.repomethod/scripts/agent-gate.sh --spec <spec>   # required aggregate gate (classic/graph)
.repomethod/scripts/agent-gate.sh --quick          # quick gate building block: verify + protected zones + evidence note
.repomethod/scripts/supervisor.sh check --state <file>   # deterministic verdict: done | continue | blocked | needs_human | evidence-ignored
```

Close out through `.repomethod/scripts/deliver.sh --quick` for Quick MVP or
`.repomethod/scripts/deliver.sh --spec <spec> --state <file>` for Classic and Graph.

The diff base is auto-resolved from `@{upstream}` / `origin/HEAD` / `main`;
pass `--base <ref>` to override. A `classic`/`graph` `init` resolves that fork
point once and stores it as `config.base_ref` in the workflow state; a
state-aware gate (`agent-gate.sh --spec <spec> --state <file>`, and the
supervisor) then reuses that pinned SHA instead of re-resolving. An explicit
`--base` still wins and keeps its staleness diagnostics.

`agent-gate.sh --spec` also runs `verify-forbidden` (the optional
`## Must Not Exist` section is enforced inside the declared Scope),
`plan-obligations.sh check` (declared plan obligations require a current,
approved extraction before acceptance/evidence gates run), `verify-report`
(the acceptance report must name its spec, and if the spec declares a
`## Test Count Command` its `Tests: <n>` line must match that command's current
output), and `verify-invariants` (every `## Integration Invariants` bullet, run
from the repo root, must exit 0). When `--state` is supplied, the full gate
derives `classic` or `graph` from that workflow state and rejects an obligations
artifact recorded for the other mode. A spec with budget, retry, or
report-aggregation logic must declare integration invariants — green unit tests
do not satisfy it on their own.

There is exactly one `verify-command`: the pass/fail signal the gate depends
on. A spec may also declare a `## Test Count Command` and
`## Integration Invariants`, which the gate runs as further repository-owned
commands. If the full suite needs a network, model, or external system, it is
the repository's responsibility to make that command runnable in CI.

The pull-request flow uses one changed top-level spec under `specs/` and
`.repomethod/evidence/report.md` as its acceptance report. A `quick-mvp`
pull request changes no spec and closes out with
`.repomethod/scripts/deliver.sh --quick` instead.

## Delivery Modes

Choose one mode and use its shared skill:

```bash
.repomethod/scripts/feature-workflow.sh quick-mvp
.repomethod/scripts/feature-workflow.sh classic init --feature <slug> --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/<slug>.md"
.repomethod/scripts/feature-workflow.sh graph init --feature <slug> --research single --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/<slug>.md"
```

Substitute `<slug>`; an angle bracket left in the `--verify-command` value is
refused at `init`.

- `quick-mvp` uses the `quick-mvp` skill for a small reversible feature, one
  targeted test, and at most one correction. It creates no workflow state and
  needs no `specs/` file; plan obligations are explicitly not applicable and
  it closes out with `.repomethod/scripts/deliver.sh --quick`.
- `classic` uses `classic-loop`: Implementation, a real configured verification
  command, bounded Fix and Re-verification, then Completion. If its feature
  spec declares `## Plan Obligations`, those obligations must be extracted and
  approved before the aggregate gate can pass.
- `graph` uses `graph-delivery`: Research, Plan, reviewed plan obligations,
  developer approval of the proposed execution graph, Implementation, and the
  same verification loop. Set Research to `single` or `parallel`; add
  implementation nodes only after Plan and before approval.

Persist Classic and Graph state under `.repomethod/workflows/` and evidence
under `.repomethod/evidence/`. The state and repository artifacts must be
sufficient for another local or cloud agent to resume without chat history —
so commit them as you go: `specs/<feature>.md`, `specs/packets/` (graph),
`.repomethod/workflows/<feature>.json`,
`.repomethod/workflows/<feature>.plan-obligations.json` when obligations are
declared, `.repomethod/workflows/<feature>.handoff.json`, and
`.repomethod/evidence/`. `supervisor.sh check` will not return `done` while any
of the spec, the workflow state/handoff, or the evidence is uncommitted.

`complete` records work nodes. Verification nodes always use `verify`; the
configured command exit status is authoritative. Pull-request creation and
merge remain human controlled.

`workflow-graph.sh reverify --state <file> --node <verification-id> --evidence
<file>` re-runs a passed verification node's command and rewrites its evidence
under a committable name — no state transition, no new nodes.

### Plan Obligation Lifecycle

Author normative planning requirements in the top-level feature spec under
`## Plan Obligations`; do not infer them from free-form planning prose. Each
line has exactly this shape:

```md
- `stable-anchor` [shape|behaviour|prohibition|process] Original normative text.
```

The anchor is the identity and produces `obl.<stable-anchor>`. Keep the anchor
when wording changes so downstream provenance remains stable. Generate or
refresh the feature-scoped artifact with:

```bash
.repomethod/scripts/plan-obligations.sh extract --mode <classic|graph> \
  --spec specs/<feature>.md --repo .
```

The artifact lives at
`.repomethod/workflows/<feature>.plan-obligations.json`. Its `revision_diff`
records added, removed, and changed obligations. Reordering unchanged anchors
does not create a new revision. Any content or type change creates a new
pending revision; removing the final obligation also creates a pending
revision so the removal is reviewed rather than silently becoming N/A.

Review the displayed extraction and approve that exact revision:

```bash
.repomethod/scripts/plan-obligations.sh approve --mode <classic|graph> \
  --spec specs/<feature>.md --repo . --revision <n> \
  --approval-text "<exact reviewer approval>"
```

The aggregate `agent-gate.sh --spec` runs `plan-obligations.sh check`
automatically before acceptance/evidence verification. Use the standalone
`check` command only when you want to inspect that contract earlier. Missing,
malformed, stale, tampered, or unreviewed artifacts fail closed. When
`agent-gate.sh` receives `--state`, it binds the check to the workflow state's
mode. Specs with no active obligations and no prior obligations artifact return
`NOT_APPLICABLE` before obligations-specific `specs/<feature>.md` path/slug
rules are enforced; Quick MVP is explicitly N/A. Never treat a missing artifact
as Quick MVP merely because it is absent.

For existing Classic/Graph work, adding the first active Plan Obligation is an
opt-in migration point: run `extract`, review the displayed revision, and run
`approve` before expecting the full gate to pass. Specs without active
obligations retain their previous gate behavior.

### Supervisor Loop

An active `classic` or `graph` workflow is not delivered because an agent
stopped talking. It is delivered when `.repomethod/scripts/deliver.sh --spec <spec> --state <file>`
prints `DELIVERY: done` (exit 0). That command runs the stateful gate and
`supervisor.sh check` for you; `done` means gate green, workflow `completed`,
the completion node succeeded, scope clean, a fresh handoff reports no open
blocker, the plan artifacts are committed, and every integration invariant
is green. Any other result prints `DELIVERY: incomplete` (more work) or
`DELIVERY: blocked` (blocked, needs a human, or ignored evidence).

Before you end a turn on an active workflow, write a handoff so the supervisor
and the next agent know where you stopped:

```bash
.repomethod/scripts/workflow-graph.sh handoff --state <file> --node <id> \
  --next "<next concrete step>" [--changed <csv>] \
  [--blocker "<what is missing>"] [--claim complete|needs_human]
```

`supervisor.sh run --state <file> --agent-command "<cmd>"` chains check →
dispatch → agent for callers that can spawn one non-interactively; without
`--agent-command` it performs a single check.

## Task and Scope Rules

Start `classic` and `graph` delivery work from `.repomethod/templates/spec.md`.
The spec must let an agent with no prior chat context perform the task from the
repository alone. `quick-mvp` needs no spec.

Paths matching `.repomethod/protected-zones.txt` require an exact path in
the active spec Scope. Stop before changing an undeclared protected path.
`quick-mvp` has no spec and therefore may not touch a protected path at all —
switch to `classic` or `graph` with a spec if it must.

An optional `## Must Not Exist` section adds deterministic negative
requirements. A backticked declaration is a fixed string by default; use
the explicit `regex:` prefix only when POSIX extended regular-expression
matching is intended. `verify-forbidden.sh` searches tracked and non-ignored
untracked regular files whose repository-relative paths match `Scope`, including
pre-existing code. It scans contents verbatim, so comments and docstrings count
as matches. Unknown file types are scanned rather than skipped, and scoped
symlinks or other non-regular Git entries fail closed.

`.repomethod/scope-ignore.txt` (one glob per line, `#` and blank lines skipped)
drops matching paths from the scope check; protected zones still win.

Use `scoped-delivery` and `.repomethod/templates/spec-packet.md` when implementation needs
multiple bounded packets. A packet gets fresh context, named inputs, its exact
scope and tests, and a token budget it declares to fit its worker. A worker
records a handoff instead of widening scope or exceeding that budget.

Stop and report the concrete blocker when work needs:

- a file outside the allowed Scope;
- an unauthorized dependency;
- a security or architecture decision absent from the spec;
- contradictory acceptance criteria;
- missing secrets, systems, or evidence;
- a stale or ambiguous Graph approval.

## Local and Cloud Boundaries

- Cloud tasks must be reproducible from a clean remote checkout.
- Do not depend on uncommitted files, laptop-only services, personal tokens, or
  local Docker state.
- Use GitHub Actions Secrets in CI and an approved managed secret store in
  deployed environments. Keep credentials out of repository files and prompts.
- Authentication, credentials, tenant isolation, RBAC, audit integrity, and
  evidence-package changes need explicit human review and merge.

## Change Discipline

- Analyze existing architecture before editing.
- Make the smallest change that satisfies the spec and existing interfaces.
- Do not add dependencies without an explicit task mandate.
- Reproduce bugs through the closest practical user path before fixing them.
- Add or update tests for behavior changes.
- Never commit secrets or edit generated files by hand.
- Run the repository-defined complete local CI or pre-push gate before pushing when one is configured; targeted tests alone do not establish push-readiness.
- Run `.repomethod/scripts/deliver.sh --spec <spec> --state <file>` (or `--quick` for quick-mvp) before declaring delivery complete; only `DELIVERY: done` counts.
- On an active `classic`/`graph` workflow, write a `workflow-graph.sh handoff` before ending the turn — current node, changed files, next step, and any blocker or completion claim.
- Record changed files, verification evidence, deviations, and remaining risks.
- Use `task/<short-description>` branches and Conventional Commits.
- Never merge automatically or add an agent as commit co-author.
