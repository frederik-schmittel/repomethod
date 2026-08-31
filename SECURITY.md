# Security Policy

RepoMethod is pre-1.0 alpha software. It ships shell scripts that a project
runs against its own repository; it makes no network calls of its own and
stores no secrets.

## Supported versions

Only the latest `0.0.x` release receives fixes. There is no backport branch.

## Reporting a vulnerability

Email **frederik.schmittel@gmail.com** with:

- affected script or code path,
- what an attacker can do (e.g. write outside the target repo, execute an
  attacker-controlled string),
- a minimal reproduction.

Please do not open a public issue for anything exploitable. Expect an
acknowledgement within a few days. As an unpaid alpha project there is no
fixed remediation SLA, but path-containment and command-injection reports
are treated as priority.

## Scope

In scope: `install.sh`, `update.sh`, `uninstall.sh`, `lib/`, and the
blueprint scripts under `blueprint/.repomethod/scripts/`.

Out of scope: the `verify-command` a consuming project configures, and any
skill or CI step that project adds on top.

## Known limitations

`update` and `uninstall` re-check that the target path is still inside the
repository immediately before the operations that write or delete: the
manifest write, the managed-file and backup copies, the pointer-block
removal, and its temp-file creation. This narrows the window between that
check and the operation from an external-process fork wide to a shell builtin
wide (the manifest write now has only a `printf` redirect after its check).
It does not close it.
A residual `stat`-to-path-access window remains even on those instrumented
operations, and other pathname-based operations in the same scripts are not
re-checked and stay racy — each re-resolves its path from `/` when it runs.

Exploiting the residual race requires an attacker who already holds write
access to the repository that `update` or `uninstall` is about to modify, and
who wins the builtins-wide race to swap an already-checked ancestor directory
for a symlink. The escalation it buys is narrow: from "can write inside the
repo" to "can redirect one write outside it, or into `.git`".

Closing the race needs fd-relative, no-follow syscalls (`openat`, `unlinkat`,
`renameat` with `O_NOFOLLOW` / `dir_fd`) that Bash does not expose. The full
fix is deliberately deferred for `0.0.1` (maintainer decision, 2026-08-29).
