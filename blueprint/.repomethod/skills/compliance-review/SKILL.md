---
name: compliance-review
description: Use before implementing a task spec whose declared Scope touches a protected zone (see .repomethod/protected-zones.txt: auth, billing, migrations, secrets, compliance/**) or that handles personal/user data: reviews the spec for missing compliance-relevant considerations (data handling, audit logging, access control, retention) before code is written. Do not use for generic requirements-writing unrelated to a protected zone or personal data; that's a broader task this skill does not cover end-to-end.
---

# compliance-review

## When to use
- A task spec (following `.repomethod/templates/spec.md`'s structure) declares a Scope that matches an entry in `.repomethod/protected-zones.txt`, or otherwise touches personal/user data, before any implementation starts.

## When NOT to use
- Generic requirements review with no protected-zone or personal-data angle: this skill is specifically about the compliance-relevant gaps that arise there, not a general spec-quality pass.

## What it does
1. Read the spec's `## Scope` section; check each entry against `.repomethod/protected-zones.txt`.
2. For any match (or any spec that otherwise mentions handling personal/user data), check the spec's `## Acceptance Criteria` and `## Expected Evidence` sections for gaps in:
   - **Data handling**: is it clear what data is read/written/logged, and is that necessary and minimal?
   - **Audit logging**: does a change to an audit-relevant area (auth, billing) include acceptance criteria that its actions remain auditable?
   - **Access control**: does the spec change who can do what, and if so, is that change itself an explicit acceptance criterion (not an incidental side effect)?
   - **Retention/deletion**: if data is stored, does the spec say anything about how long, or how it's removed?
3. For each gap found, add a note to the spec's `## Escalation Conditions` section (or flag it back to whoever wrote the spec) rather than silently proceeding with an incomplete spec.
4. This skill does not itself decide legal/regulatory compliance: it surfaces the specific gaps above for a human to resolve; it never approves a spec as "compliant."

## Allowed tools
Read-only: reading the spec file and `.repomethod/protected-zones.txt`. No script, no writes except appending an escalation note to the spec file being reviewed (with the human's awareness, never silently).
