# Work Packet: <packet-id>

## Objective

<One independently testable implementation result.>

## Dependencies

- <Completed packet IDs or `none`.>

## Context Pack

- `<approved plan/spec path>`
- `<relevant project-map section or exact interface file>`
- `<existing tests and in-scope source files>`

Do not preload unrelated repository history, complete logs, or files outside
this list. Retrieve additional context only when the packet requires it and the
Scope permits it.

## Scope

- `<exact file or narrow glob>`

## Inputs

- `<frozen interface, state, or artifact consumed>`

## Outputs

- `<exact interface, behavior, test, or artifact produced>`

## Tests

- `<exact narrow RED command and expected failure>`
- `<exact GREEN command and expected pass>`

## Execution Budget

- Context: fresh
- Model class: implementation
- Maximum tokens: <budget that fits this packet's worker context with margin>

Set this to fit the worker's model and context with headroom. Reduce it for
routine work; never raise it once the packet is dispatched. This budget does
not constrain the comprehensive planning pass that produced the approved plan.

## Descopes

If this packet intentionally omits an approved `obl.<anchor>` plan obligation,
record it in the workflow's feature-scoped descope ledger before handoff:

```bash
.repomethod/scripts/descope-ledger.sh add --state <state> \
  --id descope.<anchor> --plan-ref obl.<anchor> \
  --description "<what is omitted>" --rationale "<why>" --owner "<owner>"
```

Review decisions are append-only. Record the review with
`descope-ledger.sh review --status accepted|rejected`; never edit or delete an
earlier ledger event. `unreviewed` and `rejected` descopes block delivery.
Accepted descopes stay visible in handoff provenance.

## Stop Conditions

- An unresolved product, architecture, security, or authority decision appears.
- A required change falls outside Scope or needs an unauthorized dependency.
- A frozen input/interface conflicts with the repository.
- Completion would exceed the declared token ceiling.
- A declared integration invariant for this spec is red.

## Handoff

If the packet stops or finishes, write a compact durable handoff containing:

- completed changes and commit SHA, if any
- tests run with exact outcomes
- remaining work and current failing test
- deviations or conflicts with the approved plan
- open descope IDs and accepted descope provenance from the canonical descope state
- only the files/interfaces the next fresh worker must read
