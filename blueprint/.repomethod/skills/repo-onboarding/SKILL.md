---
name: repo-onboarding
description: Use at the very start of a fresh agent session in a repo that has repomethod installed, before exploring the codebase, to read a size-capped map of structure, build/test/verify commands, and protected zones instead of blindly grepping the whole tree. Also use to regenerate that map right after a `.repomethod/scripts/agent-gate.sh` run that changed top-level structure, Makefile targets, or the detected stack; not for routine mid-task file reads.
---

# repo-onboarding

## When to use
- A freshly spawned agent with no prior context is starting work in this repo.
- `.repomethod/project-map.md` is missing, or you know structure/commands changed since it was last generated (e.g. right after `ship-pr` completes a task).

## When NOT to use
- Mid-task, once you've already read the map this session: don't regenerate it for every file you touch.
- As a substitute for actually reading a module's code before changing it: this skill only orients you at the start, it is not a replacement for understanding what you are about to modify.

## What it does
Step 1 — environment preflight. Run `.repomethod/scripts/preflight.sh` before
creating or reading the Project Map. It reports every configured environment
problem at once (bash/git/jq versions, a missing or empty
`.repomethod/verify-command`, unresolved verify-command runners) plus warnings
(detached HEAD, a foreign `VIRTUAL_ENV`, stray `node_modules` symlinks). On any
`HARD:` finding it exits non-zero and onboarding stops until that is fixed;
warnings do not block.

Step 2 — runs `scripts/generate-project-map.sh <repo-root>`, which:
1. Lists `Makefile` target names (not their recipes); read `.repomethod/verify-command` separately for the repository's own configured verification command; this skill does not detect or guess it.
2. Lists `.repomethod/protected-zones.txt` verbatim.
3. Lists the top two directory levels (names only, no file contents).
4. Writes the result to `.repomethod/project-map.md`, hard-capped at 400 lines (~2-3k tokens). If the natural output would exceed that, the directory-structure section is truncated first; commands and protected zones are never truncated, since a wrong or missing protected-zone list is far more costly than a shortened directory tree.

Read `.repomethod/project-map.md` in full before exploring further.

## Allowed tools
Read-only shell utilities (`find`, `grep`, `sed`, `date`) and this skill's own script. Writes only to `.repomethod/project-map.md` within the current repo, never elsewhere.
