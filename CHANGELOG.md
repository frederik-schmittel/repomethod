# Changelog

## How to read this file

From the second release on, every entry classifies its changes so an existing
installation knows what `repomethod update` will do:

- **compatible** — additive or behaviour-preserving; update just refreshes files.
- **behavior-change** — a managed file behaves differently after the update;
  review if you depend on the old behaviour.
- **needs-migration** — an installed repo cannot move forward safely without a
  script in `migrations/`; update runs it automatically and aborts if it fails.

`update` records any managed file you have edited as a local fork (`source:
local` in the manifest) and never overwrites it again. When an entry touches a
script you have forked, re-apply the change to your fork by hand.

## [0.0.2]

Four opt-in specification sections and the Graph plan-conformance boundary.

### compatible

- `## Must Not Exist` spec section with `verify-forbidden.sh`: reject forbidden
  content inside a spec's Scope. Specs without the section are unaffected. (#11)
- `## Plan Obligations` spec section with `plan-obligations.sh`: extract, review,
  and gate stable `obl.<anchor>` obligations. Opt-in; a spec that adds the
  section must approve its first extraction before the full gate passes. (#13)
- Descope ledger: `classic`/`graph init` creates a feature-scoped append-only
  ledger, and delivery is blocked while a descope is unreviewed or rejected.
  Pre-ledger workflow states are tolerated. (#18)
- `## Contract Shapes` spec section with `verify-contracts.sh`: compare declared
  JSON contract shapes against a fixed Python model adapter. Opt-in. (#19)
- `[invariant_required]` plan-obligation metadata and `verify-provenance.sh`
  `## Acceptance Mapping` aggregation. (#20)
- `## Source Intent` spec section with `intent-lineage.sh`: optional
  deterministic intent-to-delivery lineage, bound into workflow state at `init`,
  reverified on every stateful gate, and surfaced in `status` and the handoff.
  Opt-in. (#23)

### behavior-change

- Graph delivery now has a required `plan-conformance` review node between
  Verification and Completion. Newly initialized graphs build it in
  automatically; a graph approved before this release must add the node before
  it can be re-approved or delivered. Classic and Quick MVP are unchanged. (#22)
- Graph: an orphan plan obligation with no `## Acceptance Mapping` Plan Ref now
  blocks the full gate; Classic only warns. Affects only graph specs that use
  `## Plan Obligations`. (#20)

## [0.0.1]

First public release of RepoMethod.
