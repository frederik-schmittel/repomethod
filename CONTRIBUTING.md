# Contributing to RepoMethod

Thank you for contributing to RepoMethod.

RepoMethod is built around deterministic, repository-owned engineering rules. Contributions should follow the same principle: keep changes bounded, make expected behavior explicit, verify with real commands, and leave enough context for another person or coding agent to understand the result.

## Ways to Contribute

Useful contributions include:

- bug fixes and regression tests;
- documentation improvements;
- improvements to existing workflows or developer experience;
- focused refactors required by an existing change;
- new features that have been discussed and agreed on.

Small fixes and documentation improvements can usually be submitted directly. Larger or behavioral changes should start with an issue.

## Before You Start

Check existing issues and pull requests before implementing a change.

Discuss an issue before implementing changes that introduce or significantly alter:

- public CLI behavior or interfaces;
- RepoMethod workflow semantics;
- installation, update, or uninstall behavior;
- repository or agent contracts;
- shared architecture;
- security-sensitive behavior;
- external dependencies;
- backwards-incompatible behavior;
- large cross-cutting refactors.

The goal is to agree on the problem, boundaries, and intended behavior before implementation effort is spent.

If implementation reveals that materially more scope is required, discuss that additional scope rather than silently expanding the pull request.

Security vulnerabilities must not be reported through a public issue. Follow [SECURITY.md](SECURITY.md).

## AI and Coding Agents

Coding agents are welcome contributors to RepoMethod.

Using an agent does not lower the standard required for a contribution. The person submitting the contribution remains responsible for understanding the problem and implementation, keeping the change within scope, reviewing the result, running the required verification, and responding to review feedback.

Agent-generated output must be inspected, tested, and understood before submission.

Agents should work from repository-visible context rather than hidden chat history or machine-specific assumptions. Contributions must remain understandable and reproducible from a clean checkout.

Agents must follow the repository's agent instructions when present and must not automatically merge pull requests, publish releases, or bypass repository verification.

## Development Setup

RepoMethod development requires:

- Node.js 18+ and npm;
- Git;
- `jq`;
- Bash 4.4+;
- `bats-core` **v1.13.0** for tests;
- `shellcheck` **v0.11.0** for shell validation.

CI pins the Bats and ShellCheck versions in [`.github/workflows/ci.yml`](.github/workflows/ci.yml). The repository-owned CI scripts verify those versions explicitly so local validation and GitHub Actions cannot silently drift apart.

After cloning the repository, verify that the required tools are available before making changes.

## Implementation Workflow

1. Select an existing issue or establish the intended change.
2. Create a focused branch from the current `main`.
3. Inspect the relevant implementation, tests, and existing behavior.
4. Reproduce bugs through the closest practical user path when possible.
5. Implement only what is required for the intended behavior.
6. Add or update tests for changed behavior.
7. Run targeted checks while developing, then run the complete local CI gate before push.
8. Inspect the final diff for accidental or unrelated changes.
9. Open a focused pull request with the required context and verification results.

Use branches named:

```text
task/<short-description>
```

Use Conventional Commits where applicable:

```text
feat: add ...
fix: prevent ...
test: cover ...
docs: clarify ...
refactor: simplify ...
ci: improve ...
chore: release ...
```

## Scope Discipline

Keep each contribution focused on one coherent change.

Do not include unrelated refactors, renames, formatting changes, dependency upgrades, cleanup, or behavioral changes.

If additional improvements are discovered, create a separate issue or follow-up pull request unless they are necessary for the current change.

Prefer existing interfaces and simple implementations over speculative abstractions.

Do not weaken tests, verification rules, or safety boundaries merely to make a contribution pass.

## Testing Expectations

Behavior changes require tests.

Bug fixes should include a regression test demonstrating the incorrect behavior whenever practical.

New behavior should cover the intended path and meaningful failure or boundary cases.

Tests should verify externally meaningful behavior rather than unnecessary implementation details.

Do not remove, skip, or weaken an existing test without explaining why its previous expectation is no longer valid.

RepoMethod supports macOS and Ubuntu. Changes involving shell behavior, Git, filesystems, installation, or lifecycle management should account for both environments.

## Verification

Targeted tests are useful during development, but a targeted test passing is not sufficient verification for push or submission.

For fast local feedback, run:

```bash
npm run check
```

Before pushing a task branch or opening a pull request, run the complete repository-owned local CI contract:

```bash
npm run ci:local
```

That command runs the same repository-owned quality and Bats runner scripts used by GitHub Actions, validates the shard manifest, and checks Git-recorded executable modes. Missing or mismatched pinned tools fail explicitly instead of being skipped.

The underlying checks remain available individually when diagnosing a failure:

```bash
npm test
node --check scripts/*.mjs
npm run pack:check
shellcheck lib/*.sh install.sh update.sh uninstall.sh scripts/*.sh \
  blueprint/.repomethod/scripts/*.sh \
  blueprint/.repomethod/skills/*/scripts/*.sh
```

GitHub Actions remains the final cross-platform verification gate on Ubuntu and macOS, but it should confirm the same repository-owned commands rather than be the first full regression run.

Do not change CI timeouts, shard assignments, test selection, or verification rules merely to hide a failure. CI changes should address a demonstrated CI problem.

## Pull Requests

Keep pull requests small enough to review as one coherent change.

A pull request should state:

- **What changed** — the observable implementation change;
- **Why** — the problem or requirement being addressed;
- **Issue** — the related issue when one exists or is required;
- **Tests** — tests added or updated;
- **Verification** — commands run and their result;
- **Risks or limitations** — relevant remaining constraints or tradeoffs.

Important behavior and constraints belong in the repository, not only in the pull request description.

A reviewer should be able to understand and validate the contribution without access to prior chat history.

## CI Policy

Required CI checks must pass before a pull request is ready to merge.

Investigate CI failures rather than repeatedly rerunning them until they happen to pass.

Platform-specific behavior, nondeterminism, timing problems, and infrastructure assumptions should be fixed or explicitly addressed.

A change that passes locally but fails a supported CI environment is not complete.

Merging remains a human-controlled action.

## Breaking Changes

Breaking changes require discussion before implementation.

This includes changes to public CLI behavior, installed repository structure, configuration or manifest semantics, workflow state, lifecycle behavior, agent contracts, or other behavior existing users may reasonably depend on.

Where practical, breaking changes should include a migration or compatibility strategy.

Do not introduce a breaking change incidentally as part of another contribution.

## Dependencies

RepoMethod intentionally keeps its dependency surface small.

Do not add runtime or development dependencies unless they provide clear value that cannot reasonably be achieved with the existing toolchain.

A contribution adding a dependency should explain why it is needed, where it is used, why existing tooling is insufficient, and any portability or maintenance implications.

## License

By contributing to RepoMethod, you agree that your contribution will be licensed under the project's MIT License.
