---
name: security-review
description: Use before adding any new external script, tool, or dependency to this project: a short manual checklist for judging its risk (network access, credential access, sudo, destructive commands, account plausibility) before adopting it. Do not use this for reviewing your own uncommitted code changes for vulnerabilities; that is a separate, more general task (see Superpowers' security-review skill for that instead).
---

# security-review (new-dependency checklist)

## When to use
- You are about to add a new external script, CLI tool, GitHub Action, or library to this project and want to think through its risk before adopting it.

## When NOT to use
- Reviewing the diff on your own current branch for vulnerabilities in code you just wrote; that is Superpowers' generic `security-review` skill's job, this one is scoped specifically to vetting a *new external* dependency and does not duplicate that skill.

## What it does
This is a judgment checklist, not an automated scanner: a keyword-matching scan over source text cannot reliably tell "safe" from "unsafe" (any obfuscation as simple as storing a command name in a variable defeats it), so this skill asks you to actually read the code instead of trusting a heuristic pass/fail.

1. Get the candidate's source at an exact pinned commit (never a moving branch ref).
2. Read it (or at minimum its install script / entry point) and answer:
   - Does it need network access, and to where?
   - Does it read credentials, `.env` files, or SSH keys?
   - Does it run `sudo` or write outside the project directory?
   - Does it run destructive git commands (`push --force`, `reset --hard`) against something other than its own throwaway test fixtures?
3. Check the source's account/org plausibility: age, star/fork ratio for that age, whether it's a brand-new org with an implausible ratio, a pattern worth distrusting on sight.
4. Write a short summary of what you found and your judgment call; don't adopt something you have real doubts about without flagging them first.

## Allowed tools
`git`/`gh` (read-only clone/fetch, never push), standard shell/read tools for inspecting the candidate. Never writes outside a temporary scratch location used to inspect it.
