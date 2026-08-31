#!/usr/bin/env bash
# verify-invariants.sh --spec <spec.md>
# Runs the integration invariants a spec declares under
# "## Integration Invariants" (or the original German
# "## Integrationsinvarianten" — both spellings are accepted): every
# "- `<command>`" bullet in that section is executed with `bash -c` from
# the current directory (the repo root, as
# the gate runs it), top to bottom. Each must exit 0. The first bullet(s)
# usually produce a smoke artifact; the rest assert over it. No section, or
# a section with no bullets, is a pass — this check is opt-in.
set -euo pipefail

spec=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done
[ -n "$spec" ] || { echo "usage: verify-invariants.sh --spec <spec.md>" >&2; exit 1; }
[ -f "$spec" ] || { echo "spec not found: ${spec}" >&2; exit 1; }

# shellcheck disable=SC2016 # the sed script matches literal backtick bullets, not a command substitution
mapfile -t invariants < <(
    awk '/^## (Integration Invariants|Integrationsinvarianten)/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | sed -nE 's/^- `(.+)`[[:space:]]*$/\1/p'
)

if [ "${#invariants[@]}" -eq 0 ]; then
    echo "OK: no integration invariants declared"
    exit 0
fi

# Invariants must be read-only or write only into git-ignored paths (a
# `.tmp.` artifact under .repomethod/evidence/, $TMPDIR, ...). One that
# dirties a tracked path makes every later `supervisor.sh check` re-dirty the
# tree and stalls the workflow in `continue` forever. `git status` omits
# ignored files, so a snapshot before/after catches exactly the bad case.
before="$(git status --porcelain 2>/dev/null | LC_ALL=C sort || true)"

count=0
for inv in "${invariants[@]}"; do
    count=$((count + 1))
    if ! bash -c "$inv"; then
        echo "INVARIANT-FAILED: [${count}] ${inv}" >&2
        exit 1
    fi
done

if [ -n "$before" ] || git rev-parse --git-dir >/dev/null 2>&1; then
    after="$(git status --porcelain 2>/dev/null | LC_ALL=C sort || true)"
    newly="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    if [ -n "$newly" ]; then
        echo "INVARIANT-DIRTIED-TRACKED-PATH: an invariant wrote to version-controlled files." >&2
        echo "Invariants must be read-only or write only to git-ignored paths" >&2
        echo "(e.g. .repomethod/evidence/<name>.tmp.<ext>, \$TMPDIR):" >&2
        printf '%s\n' "$newly" >&2
        exit 1
    fi
fi

echo "OK: ${#invariants[@]}/${#invariants[@]} integration invariants passed"
exit 0
