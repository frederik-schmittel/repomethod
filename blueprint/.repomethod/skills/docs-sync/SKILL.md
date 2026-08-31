---
name: docs-sync
description: Use after renaming a file, removing a script, or changing a Makefile target that README.md, AGENTS.md, or CLAUDE.md might reference: checks that every path-like inline-code reference in those three files still points to something that exists. Do not use this to write new documentation prose from scratch; it only checks existing references for staleness, it does not author content.
---

# docs-sync

## When to use
- After a rename, move, or removal of any file that `README.md`, `AGENTS.md`, or `CLAUDE.md` might reference by path.

## When NOT to use
- Writing new documentation sections: this skill checks existing cross-references for staleness, it does not draft prose.

## What it does
Runs `scripts/check-doc-references.sh <repo-root>`, which:
1. Extracts every inline-code span (`` `like/this` ``) containing a `/` from `README.md`, `AGENTS.md`, `CLAUDE.md` (whichever exist at the repo root).
2. Checks each one resolves to a real file or directory relative to the repo root.
3. Prints `STALE: <doc-file>: <reference>` for each broken one, exits 1 if any were found, else prints `OK: N references checked` and exits 0.

## Allowed tools
Read-only shell utilities (`grep`, `sed`, `find`) and this skill's own script. Never writes anything; it only reports.
