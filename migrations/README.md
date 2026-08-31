# Update migrations

`update.sh` runs the scripts in this directory whose version is greater than
the installed manifest's `version` and less than or equal to this checkout's
`VERSION`, in ascending version order, before it refreshes any managed file.

## Convention

- One file per version that needs a migration: `<version>.sh` (an optional
  `-slug` suffix is allowed, e.g. `0.2.0-workflow-schema.sh`). The leading
  dotted number before the first `-` is the version the migration belongs to.
- Invoked as `bash <file> <target-repo-root>`. Exit non-zero to abort the
  update (nothing downstream runs, the manifest is untouched).
- Must be idempotent: a re-run over an already-migrated repo is a no-op.
- Keep it to `.repomethod/**` state — never touch host files.

Most releases need no migration; a purely additive or backward-compatible
change is documented in `CHANGELOG.md` and ships no file here.
