#!/usr/bin/env bash
# verify-report.sh --spec <spec.md> --report <report.md>
# Two guards so a green gate cannot sit next to a stale acceptance report:
#   1. the report names the spec it belongs to (the spec's basename appears
#      in the report) — a report copied from an earlier phase or a different
#      spec is rejected.
#   2. if the spec declares a "## Test Count Command" section (or the original
#      German "## Testzahl-Befehl" — both spellings are accepted) with one
#      non-comment line, that line is run with `bash -c` from the current
#      directory; its trimmed stdout must be an integer N, and the report
#      must contain a line "Tests: N". Opt-in: a spec without the section
#      skips this check.
# Trusts only exit status — it never parses the verify command's own output.
set -euo pipefail

spec=""
report=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        --report) report="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$spec" ] || [ -z "$report" ]; then
    echo "usage: verify-report.sh --spec <spec.md> --report <report.md>" >&2
    exit 1
fi
[ -f "$spec" ] || { echo "spec not found: ${spec}" >&2; exit 1; }
[ -f "$report" ] || { echo "report not found: ${report}" >&2; exit 1; }

spec_name="$(basename "$spec")"
if ! grep -qF -- "$spec_name" "$report"; then
    echo "STALE-REPORT: ${report} does not name its spec (${spec_name})" >&2
    exit 1
fi

# shellcheck disable=SC2016 # the sed script strips literal backticks, not a command substitution
count_cmd="$(
    awk '/^## (Test Count Command|Testzahl-Befehl)/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -Ev '^[[:space:]]*(#|$|```)' \
    | sed -E 's/^- //; s/^`//; s/`[[:space:]]*$//' \
    | head -n 1 || true
)"

if [ -n "$count_cmd" ]; then
    if ! n="$(bash -c "$count_cmd" 2>/dev/null | tr -d '[:space:]')"; then
        echo "TEST-COUNT: command failed: ${count_cmd}" >&2
        exit 1
    fi
    case "$n" in
        ''|*[!0-9]*)
            echo "TEST-COUNT: '${count_cmd}' did not produce an integer (got '${n}')" >&2
            exit 1
            ;;
    esac
    if ! grep -qE "^Tests: ${n}([^0-9]|$)" "$report"; then
        echo "TEST-COUNT: ${report} is missing 'Tests: ${n}' (current count from Test Count Command)" >&2
        exit 1
    fi
    echo "OK: report names ${spec_name}; Tests: ${n} confirmed"
    exit 0
fi

echo "OK: report names ${spec_name}"
exit 0
