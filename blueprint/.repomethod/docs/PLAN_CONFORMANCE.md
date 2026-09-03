# Graph Plan Conformance

Graph delivery has a required review boundary between Verification and
Completion:

```text
Implementation -> Verification -> Plan Conformance -> Completion
                                      |
                                      +-- blocked -> conformance-fix-N
                                                     -> conformance-verification-N
                                                     -> plan-conformance-N
```

Classic and Quick MVP do not use this boundary.

## Why it exists

A green verification command proves the configured checks passed. It does not
prove that the complete feature diff still matches the developer-approved plan.
Plan Conformance performs that separate review against stable plan obligations
and the full diff before Graph delivery can complete.

## Review authorities

`workflow-graph.sh init` pins `config.base_ref`. Graph approval records an
`approved_plan` snapshot for the exact displayed graph revision. When a
`plan-conformance` node starts, `plan-conformance.sh prepare` creates a context
bundle containing or pointing to:

- the pinned base SHA and complete feature diff from that base,
- the approved graph-plan snapshot,
- the approved `.plan-obligations.json` artifact and stable `obl.<anchor>` IDs,
- the canonical current descope state from `descope-ledger.sh state`,
- the feature spec and downstream provenance validation,
- the fixed `templates/plan-conformance-rubric.md` rubric.

The snapshot digest binds all of these authorities. Runtime `.repomethod/`
artifacts are excluded from the source diff and hashed as separate review
authorities, so writing the context/verdict does not stale itself.

## Verdict contract

The reviewer records one table row per approved obligation with its exact type
(`shape`, `behaviour`, `prohibition`, or `process`) and one of `pass`, `fail`,
`accepted_descope`, or `orphan`. The verdict also carries a blocker list.
`accepted_descope` is valid only for the exact plan ref currently accepted by
the canonical descope ledger. Unknown, duplicate, missing, malformed, or
wrongly typed rows fail closed.

`overall: pass` requires an empty blocker list and only `pass` or
`accepted_descope` rows. Unreviewed/rejected descopes and untreated orphans
block the result.

The normalized verdict and its context/diff evidence are stored under
`.repomethod/evidence/` and referenced from the conformance node.

## Freshness and delivery

Before Completion, supervisor success, or delivery, RepoMethod recomputes the
snapshot from the pinned base and current authorities. Missing verdicts,
blockers, invalid authorities, or a digest mismatch are not deliverable. Source
changes, obligation revisions, descope reviews, approved-plan changes, and
rubric changes therefore require a new conformance review.

Dispatch exposes `fresh_context_required: true` for every plan-conformance node.
The Graph Delivery skill requires a fresh reviewer context and tells the
reviewer to consume the generated bundle instead of reusing implementation chat
history or guessing a new diff base.

## Supervisor progress

The supervisor's idle fingerprint additionally includes reviewed obligation
state, canonical descopes, approved-plan state, conformance node state, and
conformance verdict hashes. A legitimate obligation approval or conformance
attempt therefore resets idle progress. Supervisor-owned sidecars, dispatch
renders, and per-check gate logs remain excluded so the supervisor cannot create
its own artificial progress.
