# Implementation Plan: <feature-slug>

## Planning Boundary

Planning context is not subject to the implementation packets' token ceiling.
Use the context needed to produce a coherent end-to-end architecture and then
offload the result to this file. Every dispatched implementation, test, review,
or correction packet derived from this plan is capped at the token budget that
packet declares for its worker.

## Goal

<One verifiable end-to-end outcome.>

## Architecture

<Authority boundaries, data flow, state transitions, persistence, contracts,
background work, frontend boundary, and deployment impact.>

## Global Constraints

- <Constraint copied exactly from the approved specification.>

## Dependency Graph

| Packet | Depends on | Produces | Can run in parallel with |
| --- | --- | --- | --- |
| `<id>` | `<id or none>` | `<frozen interface/artifact>` | `<ids or none>` |

## Preflight Gate

- [ ] Product behavior and non-goals are unambiguous.
- [ ] Authority, state transitions, and cross-packet interfaces are frozen.
- [ ] Protected paths and dependencies are explicitly authorized.
- [ ] Tenant/scope/RBAC and integrity requirements are mapped where relevant.
- [ ] Every acceptance criterion maps to an executable test or evidence item.
- [ ] Normative plan obligations are declared in the feature spec and the current extraction revision is reviewed before downstream consumption.
- [ ] Every implementation packet uses `.repomethod/templates/spec-packet.md`, a fresh
      context, and a declared `Maximum tokens` budget that fits its worker.
- [ ] No implementation packet contains an unresolved architecture, security,
      or product decision.

Implementation must not start until every preflight item is checked.

## Work Packets

Create one self-contained packet file from `.repomethod/templates/spec-packet.md` per row.
Packet boundaries follow independently testable responsibilities, not arbitrary
file counts or technical layers.

| Packet file | Responsibility | Model class | Maximum tokens |
| --- | --- | --- | --- |
| `specs/packets/<id>.md` | `<result>` | `<implementation or high-risk>` | `<declared budget>` |

## Integration and Closeout

<Commands that prove the combined vertical change, independent review required,
and exact evidence paths.>
