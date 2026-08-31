---
name: ship-pr
description: Use after a task's `.repomethod/scripts/agent-gate.sh` run has succeeded, right before opening the pull request: verifies acceptance/evidence gates actually have supporting artifacts, refreshes the project map if structure or commands changed, and opens the PR using gh (gh-axi preferred, gh as fallback) with the repo's pull_request_template.md. Never runs the actual PR-creation command without first showing the exact title and body to the human and getting explicit confirmation; do not use this skill to open a PR non-interactively.
---

# ship-pr

## When to use
- `.repomethod/scripts/agent-gate.sh --spec <spec>` has just succeeded for a task and you're ready to open its PR.

## When NOT to use
- Before `.repomethod/scripts/agent-gate.sh --spec <spec>` has passed: there is nothing to ship yet.
- To open a PR non-interactively without human confirmation: this skill's own instructions forbid that (see below); use it only in a session where you can show the human the draft first.

## What it does
1. Run `scripts/preflight.sh <repo-root> <base-ref>`: a read-only check that a real task spec exists (not just `specs/TEMPLATE.md`) and that `.repomethod/scripts/verify-acceptance.sh`/`.repomethod/scripts/verify-evidence.sh` are present. Prints `NOT READY: <reason>` and stops if either is missing. For a `quick-mvp` PR (no spec change), run `scripts/preflight.sh <repo-root> <base-ref> --quick` instead: it drops the spec requirement and checks a non-empty `.repomethod/evidence/report.md` plus an untouched protected zone.
2. If the repo's structure, Makefile targets, or detected stack changed as part of this task, invoke the sibling `repo-onboarding` skill's `generate-project-map.sh` to refresh `.repomethod/project-map.md` before opening the PR (so the next fresh agent reads an up-to-date map).
3. Draft the PR title and body using the repo's `.github/pull_request_template.md`, including which acceptance criteria were confirmed and where the evidence lives.
4. **Show the human the exact drafted title and body and wait for explicit confirmation before running `gh pr create`** (or the `gh-axi` equivalent, preferred per this project's AXI tool priority, falling back to plain `gh`). Opening a PR is visible to others and not trivially reversible; never skip this confirmation step, even if every gate passed.

## Allowed tools
`gh` / `gh-axi` (PR creation, only after human confirmation per step 4), this skill's own `scripts/preflight.sh`, the sibling `repo-onboarding` skill's script. Never force-pushes, never merges, never closes issues.
