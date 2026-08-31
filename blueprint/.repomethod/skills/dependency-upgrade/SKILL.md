---
name: dependency-upgrade
description: Use when bumping an already-adopted external dependency (a pinned script, tool, or library in this project) to a newer commit or release: re-verifies the new version's checksum and license live before accepting the bump, flagging any regression (license change, new suspicious behavior). Do not use for adopting a brand-new dependency for the first time; that's the security-review skill's job, this one only governs re-verifying an existing pin.
---

# dependency-upgrade

## When to use
- A newer commit/release exists for a dependency you already pinned (by commit SHA and checksum) somewhere in this project, and you're deciding whether to bump it.

## When NOT to use
- Adopting a dependency for the first time: use `security-review` for that; this skill assumes there is already an existing, previously-verified pin to compare against.

## What it does
1. Note the dependency's current pinned commit SHA, checksum, and license (wherever this project records them).
2. Fetch the new commit's source, compute its checksum live (`sha256sum`/`shasum`; never trust a checksum from a changelog or release page without recomputing it yourself).
3. Diff the new commit against the old pin: did the license change? did anything new and clearly suspicious show up (new network calls, new credential access, new destructive commands)? Use the sibling `security-review` skill's checklist if you want a structured way to look.
4. If nothing regressed: update the pin (new commit SHA, new checksum, new date).
5. If something regressed: stop and report the exact diff; do not silently bump a dependency whose risk profile got worse.

## Allowed tools
`git`/`gh` (read-only fetch), `curl`, `sha256sum`/`shasum`, `jq`. No push, no write outside this project's own dependency records.
