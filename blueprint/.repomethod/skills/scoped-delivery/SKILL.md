---
name: scoped-delivery
description: Use when an approved cross-layer implementation plan must be executed cost-efficiently through fresh, bounded worker agents; preflights architecture and acceptance coverage, creates self-contained work packets, holds every implementation/test/review/correction dispatch to the token budget that packet declares, and requires durable handoffs instead of inherited chat history.
---

# Scoped Delivery

## Core principle

Plan comprehensively once, then execute through small, fresh contexts. Every
dispatched implementation, test, review, or correction packet declares the
token ceiling that fits its worker; RepoMethod does not pick that number. The
ceiling does not constrain the lead planning pass.

## When to use

- An approved plan crosses several modules, repositories, or technical layers.
- A task risks repeated repository exploration or a long-running worker context.
- A cheaper implementation model should execute work after interfaces and tests
  have been frozen by a stronger planner.

## When NOT to use

- The product behavior or architecture is still being decided. Finish planning.
- A local change is already one small, independently testable task.
- The request is only for research, explanation, or plan review.

## Preflight

Before dispatching any worker, verify the plan template's complete Preflight
Gate. Refuse implementation if an authority boundary, cross-packet interface,
protected path, dependency, RBAC/integrity rule, or acceptance mapping remains
ambiguous.

Create one packet from `.repomethod/templates/spec-packet.md` for each independently
testable responsibility. Run:

```bash
.repomethod/skills/scoped-delivery/scripts/validate-packet.sh specs/packets/<id>.md
```

## Dispatch contract

Give the fresh worker exactly:

1. Its packet file.
2. The named plan/spec and Context Pack inputs.
3. The current commit and completed dependency outputs.
4. The exact narrow test command.

The worker retrieves other content on demand. It does not receive the planning
chat, unrelated task history, complete logs, or the whole repository as copied
prompt context.

Use a smaller implementation model only when the packet has frozen interfaces,
tests, and no unresolved high-risk decision. Use a stronger model for auth,
tenant isolation, migrations, cryptographic/integrity logic, regulatory
decisions, architecture changes, and independent closeout review.

## Execution loop

1. Validate the packet.
2. Start a fresh worker context.
3. Require RED, minimal GREEN, narrow verification, and a focused commit.
4. Read the durable Handoff and verify the diff/test evidence independently.
5. Mark the dependency output available; dispatch newly unblocked packets.
6. Run the repository's full task gate only after the vertical slice integrates.

Independent packets may run in parallel only when their file ownership and
produced interfaces do not overlap.

## Hard stop

A worker must stop and write its Handoff when scope, frozen interfaces, or the
declared token budget cannot contain the work. Never raise a packet above its
declared ceiling once dispatched, reuse a polluted worker session, or hide
unfinished work behind a summary-only completion claim. Split the remaining
responsibility and start a fresh worker.

A packet does not close on green unit tests alone when the spec declares
`## Integration Invariants`; those run in the aggregate gate, not per
packet.

## Common mistakes

| Mistake | Correction |
| --- | --- |
| Treating the declared ceiling as a target | Keep routine packets materially smaller. |
| Shrinking the planning pass | Planning is exempt; packet execution is bounded. |
| Splitting only by frontend/backend | Split by independently testable responsibility and frozen interfaces. |
| Passing the complete chat to a worker | Pass durable artifacts and exact context paths. |
| Letting a worker decide architecture | Stop and return the decision to planning/preflight. |
| Continuing after the packet grows | Handoff, split, and start a fresh context. |
