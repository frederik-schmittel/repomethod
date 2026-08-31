---
name: quick-mvp
description: Use for one small reversible feature with one clear behavior and one targeted test when a persistent workflow is unnecessary.
---

# Quick MVP

Record Goal, Scope, and Test in at most three bullets. Implement the smallest
testable slice in the current context, then run the named targeted test.

If the test fails, make one focused correction and rerun the same test. Stop if
the second run fails or the work reaches protected paths, new dependencies,
security, architecture, or a wider scope.

Quick MVP creates no workflow state, research phase, execution graph, packet, or
worker, and needs no `specs/` file. It produces a tested prototype.

Close out with `.repomethod/scripts/deliver.sh --quick`. It runs the quick
gate — the repository's `verify-command`, a protected-zone check, and a
non-empty `.repomethod/evidence/report.md` note of what was built and how it
was verified — then prints one `DELIVERY:` line; only `DELIVERY: done`
(exit 0) means closed out. No spec document, no scope/acceptance/evidence-vs-spec
aggregate. A pull request opened from this path changes no spec; `ship-pr`
accepts it with `preflight.sh <root> <base> --quick`.

If the work reaches a protected path, a wider scope, new dependencies,
security, or architecture, stop and switch to `classic` or `graph` with a real
spec.
