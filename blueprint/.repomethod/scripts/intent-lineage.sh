#!/usr/bin/env bash
# intent-lineage.sh <pin|check> --repo <dir> [--intent intents/<feature>.md | --spec specs/<feature>.md]
#
# Canonical authority for optional intent lineage. `pin` emits the one JSON
# representation a feature spec may store under ## Source Intent. `check`
# validates that representation against the conventional intent path and the
# exact current intent bytes. Workflow-state binding is intentionally outside
# this Stage-1 contract.
set -euo pipefail

command="${1:-}"
[ -n "$command" ] || {
    echo "usage: intent-lineage.sh <pin|check> --repo <dir> [--intent intents/<feature>.md | --spec specs/<feature>.md]" >&2
    exit 1
}
shift

repo="."
intent=""
spec=""

fail() {
    echo "INTENT-LINEAGE-ERROR: $*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) require_value "$@"; repo="$2"; shift 2 ;;
        --intent) require_value "$@"; intent="$2"; shift 2 ;;
        --spec) require_value "$@"; spec="$2"; shift 2 ;;
        *) fail "unknown flag: $1" ;;
    esac
done

case "$command" in
    pin)
        [ -n "$intent" ] || fail "--intent is required for pin"
        [ -z "$spec" ] || fail "pin does not accept --spec"
        ;;
    check)
        [ -n "$spec" ] || fail "--spec is required for check"
        [ -z "$intent" ] || fail "check does not accept --intent"
        ;;
    *) fail "unknown command: $command" ;;
esac

[ -d "$repo" ] || fail "repo not found: $repo"
repo_root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "$repo is not inside a Git repository"
repo_root="$(cd "$repo_root" && pwd -P)"

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        fail "sha256sum or shasum is required"
    fi
}

repo_relative_regular_file() {
    local supplied="$1" label="$2" candidate abs
    case "$supplied" in
        /*) candidate="$supplied" ;;
        *) candidate="$repo_root/$supplied" ;;
    esac
    [ -f "$candidate" ] || fail "$label not found: $supplied"
    [ ! -L "$candidate" ] || fail "$label must not be a symlink: $supplied"
    abs="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
    case "$abs" in
        "$repo_root"/*) printf '%s\n' "${abs#"$repo_root"/}" ;;
        *) fail "$label must be inside the repository: $supplied" ;;
    esac
}

validate_intent_path() {
    local path="$1" expected_feature="${2:-}" feature
    [[ "$path" =~ ^intents/([a-z0-9][a-z0-9._-]*)\.md$ ]] \
        || fail "intent path must match intents/<feature>.md: $path"
    feature="${BASH_REMATCH[1]}"
    if [ -n "$expected_feature" ] && [ "$feature" != "$expected_feature" ]; then
        fail "source intent path substitution: expected intents/${expected_feature}.md, got $path"
    fi
    [ ! -L "$repo_root/intents" ] || fail "intents directory must not be a symlink"
    [ ! -L "$repo_root/$path" ] || fail "intent must not be a symlink: $path"
    [ -f "$repo_root/$path" ] || fail "intent not found: $path"
}

validate_intent_shape() {
    local path="$1" title_count count heading
    title_count="$(grep -cE '^# Intent: .*[^[:space:]][[:space:]]*$' "$path" || true)"
    [ "$title_count" -eq 1 ] || fail "intent must contain exactly one '# Intent: <purpose>' title"
    for heading in \
        '## Problem' \
        '## Desired Outcome' \
        '## Affected Users / Systems' \
        '## Constraints' \
        '## Non-Goals' \
        '## Open Questions' \
        '## Provenance / Source'; do
        count="$(grep -cFx -- "$heading" "$path" || true)"
        [ "$count" -eq 1 ] || fail "intent must contain exactly one '$heading' heading"
    done
}

canonical_binding() {
    local path="$1" digest="$2"
    jq -cnS --arg path "$path" --arg sha256 "$digest" \
        '{schema_version:1,path:$path,sha256:$sha256}'
}

if [ "$command" = "pin" ]; then
    intent_rel="$(repo_relative_regular_file "$intent" "intent")"
    validate_intent_path "$intent_rel"
    validate_intent_shape "$repo_root/$intent_rel"
    canonical_binding "$intent_rel" "$(sha256_file "$repo_root/$intent_rel")"
    exit 0
fi

spec_rel="$(repo_relative_regular_file "$spec" "spec")"
spec_abs="$repo_root/$spec_rel"

# Fail closed only for headings that are clearly attempts to declare Source
# Intent. Unrelated headings remain backwards compatible.
while IFS= read -r heading; do
    heading_canonical="$heading"
    while [[ "$heading_canonical" == *[[:space:]] ]]; do
        heading_canonical="${heading_canonical%?}"
    done
    [ "$heading_canonical" = "## Source Intent" ] \
        || fail "malformed Source Intent heading: $heading (expected exactly: ## Source Intent)"
done < <(
    grep -iE \
        -e '^#{1,6}[[:space:]]+source[[:space:]]+intent[[:space:]:]*$' \
        -e '^#{1,6}[[:space:]]+source[[:space:]]+intent[[:space:]]+\([^)]*\)[[:space:]]*$' \
        "$spec_abs" || true
)

section_count="$(grep -cE '^## Source Intent[[:space:]]*$' "$spec_abs" || true)"
[ "$section_count" -le 1 ] \
    || fail "malformed ## Source Intent section (expected at most one heading)"

[ "$section_count" -eq 1 ] || {
    echo "NOT_APPLICABLE: spec declares no source intent"
    exit 0
}

section_tmp="$(mktemp "${TMPDIR:-/tmp}/repomethod-intent-lineage.section.XXXXXX")"
trap 'rm -f -- "$section_tmp"' EXIT

# Extract the section and remove HTML comments. The shipped template keeps its
# opt-in instructions inside a comment, so an untouched Source Intent section
# is deliberately N/A rather than a malformed binding.
awk '
    /^## Source Intent[[:space:]]*$/ {in_section=1; next}
    /^## / {if (in_section) exit}
    in_section {print}
' "$spec_abs" | awk '
    BEGIN {in_comment=0}
    {
        line=$0
        out=""
        while (1) {
            if (in_comment) {
                if (match(line, /-->/)) {
                    line=substr(line, RSTART+RLENGTH)
                    in_comment=0
                    continue
                }
                line=""
                break
            }
            if (match(line, /<!--/)) {
                out=out substr(line, 1, RSTART-1)
                line=substr(line, RSTART+RLENGTH)
                in_comment=1
                continue
            }
            out=out line
            break
        }
        print out
    }
    END { if (in_comment) exit 7 }
' > "$section_tmp" || fail "unterminated HTML comment in ## Source Intent"

mapfile -t binding_lines < <(grep -vE '^[[:space:]]*$' "$section_tmp" || true)
if [ "${#binding_lines[@]}" -eq 0 ]; then
    echo "NOT_APPLICABLE: spec declares no source intent"
    exit 0
fi

[ "${#binding_lines[@]}" -eq 3 ] \
    || fail "Source Intent must contain exactly one fenced canonical JSON binding"
[ "${binding_lines[0]}" = '```json' ] \
    || fail "Source Intent binding must start with exactly: \`\`\`json"
[ "${binding_lines[2]}" = '```' ] \
    || fail "Source Intent binding must end with exactly: \`\`\`"
binding="${binding_lines[1]}"

parsed="$(printf '%s\n' "$binding" | jq -ceS '.' 2>/dev/null)" \
    || fail "Source Intent binding is not valid JSON"
[ "$parsed" = "$binding" ] \
    || fail "Source Intent binding is not canonical JSON (use intent-lineage.sh pin)"

jq -e '
    type == "object"
    and keys == ["path","schema_version","sha256"]
    and .schema_version == 1
    and (.path | type == "string")
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' <<< "$binding" >/dev/null 2>&1 \
    || fail "Source Intent binding has an invalid shape"

feature="$(basename "$spec_rel")"
feature="${feature%.md}"
[[ "$feature" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || fail "source intent requires a lowercase feature spec basename: $feature"
[ "$(dirname "$spec_rel")" = "specs" ] \
    || fail "source intent requires a top-level feature spec under specs/: $spec_rel"

intent_rel="$(jq -r '.path' <<< "$binding")"
validate_intent_path "$intent_rel" "$feature"
validate_intent_shape "$repo_root/$intent_rel"
expected_sha="$(jq -r '.sha256' <<< "$binding")"
actual_sha="$(sha256_file "$repo_root/$intent_rel")"
[ "$actual_sha" = "$expected_sha" ] \
    || fail "stale source intent identity for $intent_rel (run intent-lineage.sh pin after reviewing the intent change)"

printf '%s\n' "$binding"
