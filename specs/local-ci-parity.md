# Task: Make local CI match GitHub Actions

## Context

RepoMethod currently has separate local verification instructions and GitHub
Actions command implementations. This allowed avoidable failures such as Git
executable-mode mistakes, ShellCheck findings, shard-manifest drift, and full
Bats regressions to be discovered only after a branch was pushed.

Issue #12 defines one repository-owned CI contract that must be executable
locally before push and reused by GitHub Actions without weakening the existing
Ubuntu/macOS matrix.

## Objective

Make one local command reproduce the complete non-platform-specific CI contract
and make GitHub Actions delegate to the same repository-owned runner scripts.

## Definition of Ready

- Issue #12 fixes the expected commands, pinned tool versions, and non-goals.
- Existing Bats sharding remains authoritative and deterministic.
- Existing Ubuntu/macOS coverage must remain unchanged.
- No new runtime or development dependency is required.
- Git hooks remain optional and out of scope.

## Architecture and Authority Boundaries

Repository-owned scripts under `scripts/` are authoritative for CI behavior.
GitHub Actions owns platform setup and matrix execution only, then delegates to
those scripts. `package.json` exposes the contributor-facing commands.
`.repomethod/verify-command` dogfoods the complete local CI contract for
RepoMethod's own development.

## Dependencies and Interfaces

- Bats is pinned to 1.13.0.
- ShellCheck is pinned to 0.11.0.
- `scripts/run-bats-lane.sh` and `.github/ci/bats-shards.tsv` remain the existing
  test-selection interfaces.
- `npm run check` is the fast local feedback command.
- `npm run ci:local` is the complete pre-push verification command.

## Scope

- `scripts/ci-quality.sh`
- `scripts/ci-tests.sh`
- `scripts/ci-local.sh`
- `package.json`
- `.github/workflows/ci.yml`
- `.github/ci/bats-shards.tsv`
- `.repomethod/verify-command`
- `blueprint/.repomethod/AGENTS.md`
- `CONTRIBUTING.md`
- `tests/ci_local.bats`
- `tests/release_script.bats`

## Out of Scope

- mandatory Git hooks
- reduced test coverage
- removal of macOS CI
- external hosted CI services
- unrelated workflow or product behavior

## Acceptance Criteria

1. `npm run ci:local` runs the complete non-platform-specific CI contract.
2. GitHub Actions delegates quality and Bats execution to repository-owned scripts.
3. A required executable entry point recorded as `100644` fails locally.
4. Missing or mismatched Bats/ShellCheck versions fail explicitly.
5. The complete Bats regression suite runs through the canonical local command.
6. Ubuntu and macOS CI coverage remains intact.
7. The shard manifest still covers every Bats file exactly once.
8. Any constituent local CI failure propagates a non-zero exit.
9. Contributor and agent instructions require complete local pre-push verification rather than targeted tests alone.
10. RepoMethod's own `.repomethod/verify-command` uses the complete local CI contract.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet |
| --- | --- | --- |
| 1 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 2 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 3 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 4 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 5 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 6 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 7 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 8 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 9 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |
| 10 | `.repomethod/evidence/local-ci-parity.txt` | `ci-contract` |

## Work Packets

- `ci-contract`: shared runners, workflow delegation, regression tests, and documentation.

## Verify Command

```
.repomethod/scripts/agent-gate.sh --spec specs/local-ci-parity.md
```

## Expected Evidence

- `.repomethod/evidence/local-ci-parity.txt`

## Escalation Conditions

- existing platform coverage must be removed or weakened
- a new dependency is required
- a CI command cannot be shared between local and hosted execution
- the existing shard contract must be replaced rather than reused
