#!/usr/bin/env bash
# intent-lineage.sh <pin|resolve|check> --repo <dir>
#   pin --intent intents/<feature>.md
#   resolve --spec specs/<feature>.md
#   check [--spec specs/<feature>.md] [--state <workflow-state>]
#
# Canonical authority for optional intent lineage. It owns the only intent
# path/content identity representation plus all parsing and validation of that
# identity. `resolve` is the read-only workflow-init interface: it returns the
# canonical binding or literal null. Stateful checks consume the stored binding
# first and never recompute identity in a caller.
set -euo pipefail

command="${1:-}"
[ -n "$command" ] || {
    echo "usage: intent-lineage.sh <pin|resolve|check> --repo <dir> [--intent intents/<feature>.md] [--spec specs/<feature>.md] [--state <workflow-state>]" >&2
    exit 1
}
shift

repo="."
intent=""
spec=""
state=""

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
        --state) require_value "$@"; state="$2"; shift 2 ;;
        *) fail "unknown flag: $1" ;;
    esac
done

case "$command" in
    pin)
        [ -n "$intent" ] || fail "--intent is required for pin"
        [ -z "$spec" ] || fail "pin does not accept --spec"
        [ -z "$state" ] || fail "pin does not accept --state"
        ;;
    resolve)
        [ -n "$spec" ] || fail "--spec is required for resolve"
        [ -z "$intent" ] || fail "resolve does not accept --intent"
        [ -z "$state" ] || fail "resolve does not accept --state"
        ;;
    check)
        [ -n "$spec" ] || [ -n "$state" ] || fail "check requires --spec or --state"
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

validate_feature() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || fail "feature must be a lowercase slug: $1"
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

# Validate a canonical binding object against the conventional path, expected
# feature, and exact current intent bytes. The caller passes compact sorted JSON
# so textual canonicality is owned here as well as hashing/path semantics.
validate_binding() {
    local binding="$1" expected_feature="$2" path expected_sha actual_sha canonical
    jq -e '
        type == "object"
        and keys == ["path","schema_version","sha256"]
        and .schema_version == 1
        and (.path | type == "string")
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' <<< "$binding" >/dev/null 2>&1 \
        || fail "Source Intent binding has an invalid shape"

    path="$(jq -r '.path' <<< "$binding")"
    validate_intent_path "$path" "$expected_feature"
    validate_intent_shape "$repo_root/$path"
    expected_sha="$(jq -r '.sha256' <<< "$binding")"
    actual_sha="$(sha256_file "$repo_root/$path")"
    [ "$actual_sha" = "$expected_sha" ] \
        || fail "stale source intent identity for $path (run intent-lineage.sh pin after reviewing the intent change)"
    canonical="$(canonical_binding "$path" "$expected_sha")"
    [ "$binding" = "$canonical" ] \
        || fail "Source Intent binding is not canonical JSON (use intent-lineage.sh pin)"
    printf '%s\n' "$canonical"
}

# Print either canonical binding JSON or literal `null`. Backward compatibility
# is decided here so every consumer sees one interpretation of ## Source Intent.
read_spec_binding() {
    local supplied="$1" spec_rel spec_abs section_count section_tmp binding parsed feature heading heading_canonical
    spec_rel="$(repo_relative_regular_file "$supplied" "spec")"
    spec_abs="$repo_root/$spec_rel"

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
    [ "$section_count" -eq 1 ] || { printf 'null\n'; return 0; }

    section_tmp="$(mktemp "${TMPDIR:-/tmp}/repomethod-intent-lineage.section.XXXXXX")"
    if ! awk '
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
    ' > "$section_tmp"; then
        rm -f -- "$section_tmp"
        fail "unterminated HTML comment in ## Source Intent"
    fi

    mapfile -t binding_lines < <(grep -vE '^[[:space:]]*$' "$section_tmp" || true)
    rm -f -- "$section_tmp"
    if [ "${#binding_lines[@]}" -eq 0 ]; then
        printf 'null\n'
        return 0
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

    feature="$(basename "$spec_rel")"
    feature="${feature%.md}"
    validate_feature "$feature"
    [ "$(dirname "$spec_rel")" = "specs" ] \
        || fail "source intent requires a top-level feature spec under specs/: $spec_rel"
    validate_binding "$binding" "$feature"
}

# Populate STATE_ABS, STATE_FEATURE, STATE_BINDING. A workflow state may use a
# caller-selected path outside the repository (an existing supported workflow
# shape), so state location is validated as a regular non-symlink file but is
# not forced under repo_root. A stored intent binding, however, is meaningful
# only with a valid feature slug and is validated before the spec is consulted.
read_state_binding() {
    local supplied="$1" candidate raw
    case "$supplied" in
        /*) candidate="$supplied" ;;
        *) candidate="$repo_root/$supplied" ;;
    esac
    [ -f "$candidate" ] || fail "workflow state not found: $supplied"
    [ ! -L "$candidate" ] || fail "workflow state must not be a symlink: $supplied"
    STATE_ABS="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
    jq -e 'type == "object"' "$STATE_ABS" >/dev/null 2>&1 \
        || fail "workflow state has an invalid lineage context: $supplied"

    STATE_FEATURE="$(jq -r '.feature? // empty' "$STATE_ABS" 2>/dev/null)" \
        || fail "workflow state has an invalid lineage context: $supplied"
    if [ -n "$STATE_FEATURE" ]; then
        validate_feature "$STATE_FEATURE"
    fi

    if ! jq -e 'has("intent_lineage")' "$STATE_ABS" >/dev/null; then
        STATE_BINDING='null'
        return 0
    fi
    [ -n "$STATE_FEATURE" ] \
        || fail "workflow state with intent lineage must contain a valid feature"
    raw="$(jq -ceS '.intent_lineage' "$STATE_ABS" 2>/dev/null)" \
        || fail "workflow state intent binding is malformed"
    [ "$raw" != "null" ] \
        || fail "workflow state intent binding must not be null"
    [ "$(jq -r 'type' <<< "$raw")" = "object" ] \
        || fail "workflow state intent binding has an invalid shape"
    STATE_BINDING="$(validate_binding "$raw" "$STATE_FEATURE")"
}

if [ "$command" = "pin" ]; then
    intent_rel="$(repo_relative_regular_file "$intent" "intent")"
    validate_intent_path "$intent_rel"
    validate_intent_shape "$repo_root/$intent_rel"
    canonical_binding "$intent_rel" "$(sha256_file "$repo_root/$intent_rel")"
    exit 0
fi

if [ "$command" = "resolve" ]; then
    read_spec_binding "$spec"
    exit 0
fi

# check: state-aware verification consumes the durable state binding first. If
# no --spec is supplied, recover the conventional feature spec from state so a
# fresh checkout can verify lineage from repository artifacts alone.
if [ -n "$state" ]; then
    read_state_binding "$state"
    if [ -z "$spec" ]; then
        if [ -z "$STATE_FEATURE" ]; then
            [ "$STATE_BINDING" = "null" ] || fail "workflow state intent lineage has no feature context"
            echo "NOT_APPLICABLE: legacy workflow state has no source intent"
            exit 0
        fi
        candidate="$repo_root/specs/${STATE_FEATURE}.md"
        if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
            spec="$candidate"
        elif [ "$STATE_BINDING" != "null" ]; then
            fail "workflow state is bound to source intent but specs/${STATE_FEATURE}.md is missing"
        else
            echo "NOT_APPLICABLE: workflow and spec declare no source intent"
            exit 0
        fi
    fi

    spec_binding="$(read_spec_binding "$spec")"
    spec_feature="$(basename "$(repo_relative_regular_file "$spec" "spec")")"
    spec_feature="${spec_feature%.md}"
    if [ -n "$STATE_FEATURE" ]; then
        [ "$STATE_FEATURE" = "$spec_feature" ] \
            || fail "workflow state feature $STATE_FEATURE does not match source-intent spec feature $spec_feature"
    fi

    if [ "$STATE_BINDING" = "null" ]; then
        [ "$spec_binding" = "null" ] \
            || fail "workflow state is missing the pinned source intent binding declared by the spec"
        echo "NOT_APPLICABLE: workflow and spec declare no source intent"
        exit 0
    fi
    [ "$spec_binding" != "null" ] \
        || fail "workflow state is bound to source intent but the spec no longer declares it"
    [ "$STATE_BINDING" = "$spec_binding" ] \
        || fail "workflow state source intent binding does not match the current spec"
    printf '%s\n' "$STATE_BINDING"
    exit 0
fi

spec_binding="$(read_spec_binding "$spec")"
if [ "$spec_binding" = "null" ]; then
    echo "NOT_APPLICABLE: spec declares no source intent"
else
    printf '%s\n' "$spec_binding"
fi
