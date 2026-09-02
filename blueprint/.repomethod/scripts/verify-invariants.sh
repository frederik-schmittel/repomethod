#!/usr/bin/env bash
# verify-invariants.sh --spec <spec.md>
# Runs integration invariants and enforces explicit invariant coverage for
# reviewed plan obligations whose invariant_required metadata is true.
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

repo_root="$(git -C "$(dirname "$spec")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || true)"
feature="$(basename "$spec" .md)"
artifact=""
[ -z "$repo_root" ] || artifact="$repo_root/.repomethod/workflows/${feature}.plan-obligations.json"

declare -A known=()
declare -A required=()
declare -A covered=()
if [ -n "$artifact" ] && [ -f "$artifact" ]; then
    [ ! -L "$artifact" ] || { echo "INVARIANT-ERROR: plan obligations artifact must not be a symlink" >&2; exit 1; }
    jq -e --arg feature "$feature" '
        .schema_version == 1
        and .feature == $feature
        and .review.status == "approved"
        and (.obligations | type == "array")
        and all(.obligations[];
            (.id | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$"))
            and .review_status == "approved"
            and ((has("invariant_required") | not) or (.invariant_required | type == "boolean")))
    ' "$artifact" >/dev/null 2>&1 || {
        echo "INVARIANT-ERROR: invalid or unapproved plan obligations artifact" >&2
        exit 1
    }
    while IFS=$'\t' read -r id required_flag; do
        known[$id]=1
        [ "$required_flag" = "true" ] && required[$id]=1
    done < <(jq -r '.obligations[] | [.id, (.invariant_required // false)] | @tsv' "$artifact")

    # Heuristic lint is advisory only. It deliberately cannot satisfy or fail
    # invariant coverage; reviewed invariant_required metadata is authoritative.
    while IFS=$'\t' read -r id text required_flag; do
        [ "$required_flag" = "true" ] && continue
        if printf '%s\n' "$text" | grep -Eiq '(^|[^[:alnum:]_])(error|errors|failure|failures|ordering|order|edge[ -]?case|edge[ -]?cases)([^[:alnum:]_]|$)'; then
            echo "INVARIANT-WARN: $id text suggests error/order/edge-case coverage; review invariant_required metadata"
        fi
    done < <(jq -r '.obligations[] | [.id, .text, (.invariant_required // false)] | @tsv' "$artifact")
fi

invariants=()
in_section=false
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    if [[ "$line" =~ ^##[[:space:]]+(Integration[[:space:]]Invariants|Integrationsinvarianten)[[:space:]]*$ ]]; then
        in_section=true
        continue
    fi
    if [[ "$line" =~ ^##[[:space:]] ]]; then
        in_section=false
        continue
    fi
    [ "$in_section" = true ] || continue
    [ -n "$line" ] || continue

    # shellcheck disable=SC2016 # regex intentionally matches literal backticks.
    if [[ "$line" =~ ^-[[:space:]]+\`(obl\.[a-z0-9][a-z0-9._-]*)\`:[[:space:]]+\`(.+)\`[[:space:]]*$ ]]; then
        ref="${BASH_REMATCH[1]}"
        cmd="${BASH_REMATCH[2]}"
        [ -n "${known[$ref]+x}" ] || {
            echo "INVARIANT-ERROR: unknown obligation reference $ref" >&2
            exit 1
        }
        invariants+=("$cmd")
        covered[$ref]=1
        continue
    fi
    # Anything that starts like an obligation binding must either match the
    # exact referenced form above or be an exact legacy command such as
    # `obl.foo`. This prevents malformed/uppercase references from falling
    # through to the greedy legacy-command parser and being executed.
    # shellcheck disable=SC2016
    if [[ "$line" =~ ^-[[:space:]]+\`obl\. ]]; then
        # shellcheck disable=SC2016
        if [[ ! "$line" =~ ^-[[:space:]]+\`obl\.[a-z0-9][a-z0-9._-]*\`[[:space:]]*$ ]]; then
            echo "INVARIANT-ERROR: malformed obligation-referenced invariant: $line" >&2
            exit 1
        fi
    fi
    # shellcheck disable=SC2016
    if [[ "$line" =~ ^-[[:space:]]+\`(.+)\`[[:space:]]*$ ]]; then
        invariants+=("${BASH_REMATCH[1]}")
        continue
    fi

    # Plain, unbackticked obligation-looking bindings are malformed. Other
    # prose in the section remains allowed for backward-compatible docs.
    if [[ "$line" =~ ^-[[:space:]]+obl\. ]]; then
        echo "INVARIANT-ERROR: malformed obligation-referenced invariant: $line" >&2
        exit 1
    fi
done < "$spec"

missing=()
for id in "${!required[@]}"; do
    [ -n "${covered[$id]+x}" ] || missing+=("$id")
done
if [ "${#missing[@]}" -gt 0 ]; then
    while IFS= read -r id; do echo "INVARIANT-MISSING: $id requires a matching integration invariant" >&2; done < <(printf '%s\n' "${missing[@]}" | LC_ALL=C sort)
    exit 1
fi

if [ "${#invariants[@]}" -eq 0 ]; then
    echo "OK: no integration invariants declared"
    exit 0
fi

# Invariants must be read-only or write only into git-ignored paths.
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
