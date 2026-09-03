# Intent: Preserve upstream purpose across RepoMethod delivery

## Problem

RepoMethod persists technical delivery state, but the durable workflow currently starts at the feature spec. A fresh agent or reviewer can recover what to build without necessarily recovering the stable upstream reason the feature exists.

## Desired Outcome

An opted-in feature has a small repository-native intent artifact whose exact identity can be traced deterministically into the technical specification and later delivery lineage.

## Affected Users / Systems

Coding agents, maintainers, reviewers, and the RepoMethod Classic/Graph delivery workflow.

## Constraints

The lineage must be deterministic, provider-neutral, repository-native, backward compatible, and independent of hosted state or model calls.

## Non-Goals

Intent is not a second planning system and does not contain technical implementation detail. This issue does not absorb plan-provenance or plan-conformance work.

## Open Questions

None for Stage 1; workflow binding and end-to-end surfaces are deliberately deferred to their review stages.

## Provenance / Source

GitHub issue #14, `[task] Add intent artifacts and end-to-end lineage`.
