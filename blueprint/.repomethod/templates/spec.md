# Task: <short, unambiguous title>

## Context

<Everything an agent with no prior knowledge needs: why this change, which
existing systems are affected, relevant earlier decisions.>

## Objective

<A single, verifiable sentence.>

## Definition of Ready

- Product behaviour and non-goals are unambiguous.
- Affected architecture boundaries and authoritative components are named.
- Interfaces between work packets are fixed.
- Tenant, scope, permission, and data-integrity requirements are clarified.
- Acceptance criteria are mapped to tests or concrete evidence.
- Open architecture, security, or product decisions are resolved.

## Architecture and Authority Boundaries

<Which component decides and persists authoritatively? Which components may
only present or transport? Relevant states and transitions.>

## Dependencies and Interfaces

<Existing interfaces, upstream tasks, and the exact interfaces produced for
downstream work packets.>

## Plan Obligations

<!-- Optional for Classic. In Graph, declare every normative statement that
must survive planning as one explicit, stable anchor before execution approval.
Use exactly one of: shape, behaviour, prohibition, process. Add the optional
[invariant_required] metadata only when review determines that this obligation
must have a matching integration invariant.

- `response-shape` [shape] Response contains id, status, and result.
- `retry-order` [behaviour] [invariant_required] Failed work is retried before completion.
- `no-eval` [prohibition] Plan content is never executed through eval.
- `approval-first` [process] Implementation starts only after plan approval.

Anchors use lowercase letters, digits, dot, underscore, or hyphen and remain
stable when wording changes. RepoMethod derives IDs as `obl.<anchor>`.
`invariant_required` is part of the reviewed obligation metadata: adding or
removing it creates a changed obligation in the next extraction revision.
After changing this section, rerun `plan-obligations.sh extract` and obtain
approval for the displayed extraction revision before downstream checks consume
it. Quick MVP has no spec and therefore no plan obligations.
-->

## Contract Shapes

<!-- Optional. Declare exactly one fenced `json` object with `version: 1` and a
non-empty `contracts` array. Each contract uses a stable `obl.<anchor>` source
and a fixed adapter descriptor. Spec content is parsed as data and never
evaluated. Example:

```json
{
  "version": 1,
  "contracts": [
    {
      "type": "Job",
      "source": "obl.job-contract",
      "adapter": {"language": "python", "module": "app.models", "model": "Job"},
      "fields": ["id", "status"],
      "required": ["id", "status"],
      "enums": {"status": ["queued", "done"]}
    }
  ]
}
```

Adapters emit canonical JSON with exactly `version`, `type`, `fields`,
`required`, and `enums`. Arrays are compared as sets after normalization; the
verifier reports expected and actual values for every mismatch.
-->

## Scope

<Allowed files/directories as glob patterns, one per line, e.g.:>

- `src/feature-x/**`
- `tests/feature-x/**`

## Out of Scope

<Explicitly excluded areas.>

## Must Not Exist

<!-- Optional. Add one declaration per line, for example:
- `legacy_api(`
- regex: `legacy_[0-9]+\(`
Backticked declarations are fixed strings. The explicit `regex:` prefix opts
into POSIX extended regular expressions. Search is limited to paths declared
in Scope. Comments and docstrings count as file content; unknown file types
are scanned rather than silently skipped.
-->

## Acceptance Criteria

<An unambiguous, ideally machine-checkable list, e.g.:>

1. <Criterion 1>
2. <Criterion 2>

## Acceptance Mapping

A backtick cell in `Test/Evidence` is enforced by the gate: a path under
`.repomethod/evidence/` must exist and be non-empty, and any other token
(a test name) must appear literally in an evidence file. Free text or an
`<placeholder>` stays a checkbox-only check.

`Plan Ref` is provenance data. Leave it empty or use `-` when a criterion has
no plan-obligation provenance. Otherwise use one or more exact backticked
`obl.<anchor>` IDs separated by commas. Unknown or malformed IDs fail closed.
References in this feature spec and its declared work packets are aggregated by
`verify-provenance.sh`; duplicate references count once.

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | `<exact test or evidence path>` | `<packet-id>` | `obl.<anchor>` |

## Work Packets

<Decompose the implementation along independently testable responsibilities.
Each packet gets its own file from `.repomethod/templates/spec-packet.md`, a
fresh agent context, and at most the token budget the packet declares. The
comprehensive planning phase itself is exempt from this implementation limit.>

- `<packet-id>`: `<one independently testable outcome>`

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/<slug>.md
```

## Test Count Command

<Optional. Exactly one line: a command whose only output is the current test
count as an integer, e.g. `bats tests/*.bats | tail -1 | sed -E 's/.* ([0-9]+)
tests?,.*/\1/'`. If set, the acceptance report must contain a line
`Tests: <n>` with exactly this number.>

## Integration Invariants

<Optional. Legacy entries use `- `<command>`` and are executed as before.
When an approved plan obligation carries `invariant_required: true`, at least
one entry must bind that exact obligation ID using
`- `obl.<anchor>`: `<command>``. The explicit obligation metadata is the hard
coverage contract. Keyword matching for error/order/edge-case language may
warn only.

Invariants run top to bottom from the repo root and each command must end with
status 0. They must be read-only or write only to git-ignored paths — a
`.tmp.` infix under `.repomethod/evidence/` is ignored by the shipped
gitignore, and `$TMPDIR` also works.>

- `obl.retry-order`: `<cli> smoke ./tests/fixtures/repo`
- `<another integration assertion>`

## Expected Evidence

<e.g. test output, screenshot, API response, log excerpt, reproducible
command. Store files under `.repomethod/evidence/`, referenced by file name.>

- `.repomethod/evidence/<name>.txt`

## Escalation Conditions

- a change outside the allowed scope is required
- a new dependency is required but not approved
- a security decision is required
- multiple architecturally relevant solutions are possible
- acceptance criteria contradict each other
- required secrets or systems are missing
- a work packet needs more than its declared token budget or additional scope
