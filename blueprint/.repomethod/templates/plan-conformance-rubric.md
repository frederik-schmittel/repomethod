# Plan Conformance Review Rubric

Rubric version: 1

Use this rubric only with the context bundle produced by
`workflow-graph.sh start --node <plan-conformance-node>` / `plan-conformance.sh prepare`.
The context is pinned to the workflow's approved graph revision and base SHA.
Review the supplied full feature diff; do not substitute a newly guessed base.

## Required review

For every approved `obl.<anchor>` row, record exactly one verdict-table row and
review the implementation against the obligation type:

- `shape`: required files, interfaces, schemas, fields, and structural contract exist in the reviewed diff.
- `behaviour`: runtime behavior and acceptance evidence match the approved obligation.
- `prohibition`: forbidden behavior or out-of-scope changes are absent.
- `process`: required workflow, ordering, review, persistence, or delivery process is satisfied.
- Descopes: `accepted_descope` is valid only when the canonical descope state marks that exact plan ref `accepted`. Unreviewed or rejected descopes are blockers.
- Orphans: every obligation must be mapped downstream or be an accepted descope. Any untreated orphan is a blocker; do not infer coverage from prose.

Review the whole supplied diff for plan drift, including additions that were not
required by the approved plan. A green test suite is evidence, not a substitute
for conformance review.

## Verdict JSON

Produce one JSON object:

```json
{
  "schema_version": 1,
  "overall": "pass",
  "table": [
    {
      "plan_ref": "obl.example",
      "type": "behaviour",
      "status": "pass",
      "rationale": "Concrete reason tied to the reviewed diff/evidence."
    }
  ],
  "blockers": []
}
```

`overall` is `pass` or `blocked`.

Each table `status` is one of `pass`, `fail`, `accepted_descope`, or `orphan`.
Each `type` must match the reviewed plan-obligation metadata. The table must
contain every approved obligation exactly once.

A blocker has this shape:

```json
{
  "id": "blocker.stable-id",
  "category": "behaviour",
  "plan_ref": "obl.example",
  "message": "What must change before conformance can pass."
}
```

`category` is `shape`, `behaviour`, `prohibition`, `process`, `descope`,
`orphan`, or `scope`; `plan_ref` may be `null` for whole-diff scope blockers.
A passing verdict requires an empty blocker list and only `pass` or
`accepted_descope` rows.
