#!/usr/bin/env bash
# verify-provenance.sh --spec <spec.md> [--state <workflow-state>] [--repo <dir>]
# Verifies deterministic obl.<anchor> references from Acceptance Mapping tables
# across a feature spec and its declared work packets. Approved descopes are
# consumed only through descope-ledger.sh state.
set -euo pipefail

spec=""
state=""
repo="."

fail() {
    echo "PROVENANCE-ERROR: $*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) require_value "$@"; spec="$2"; shift 2 ;;
        --state) require_value "$@"; state="$2"; shift 2 ;;
        --repo) require_value "$@"; repo="$2"; shift 2 ;;
        *) fail "unknown flag: $1" ;;
    esac
done

[ -n "$spec" ] || fail "--spec is required"
[ -d "$repo" ] || fail "repo not found: $repo"
repo_root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || fail "$repo is not inside a Git repository"
repo_root="$(cd "$repo_root" && pwd -P)"
[ -f "$spec" ] || fail "spec not found: $spec"
[ ! -L "$spec" ] || fail "spec must not be a symlink: $spec"
spec_abs="$(cd "$(dirname "$spec")" && pwd -P)/$(basename "$spec")"
case "$spec_abs" in "$repo_root"/*) ;; *) fail "spec must be inside the repository: $spec" ;; esac

feature="$(basename "$spec_abs" .md)"
[[ "$feature" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "feature spec basename must be a lowercase slug: $feature"
artifact="$repo_root/.repomethod/workflows/${feature}.plan-obligations.json"

# Work-packet membership is declared by the feature spec itself. The existing
# packet convention fixes each packet at specs/packets/<id>.md.
# shellcheck disable=SC2016 # backticks below are literal work-packet bullet syntax, not a command substitution
mapfile -t packet_ids < <(
    awk '
        /^## Work Packets[[:space:]]*$/ {flag=1; next}
        /^## / {if (flag) exit}
        flag {print}
    ' "$spec_abs" \
    | sed -nE 's/^- `([a-z0-9][a-z0-9._-]*)`:[[:space:]].*/\1/p'
)

sources=("$spec_abs")
declare -A seen_packet=()
for packet_id in "${packet_ids[@]}"; do
    [ -z "${seen_packet[$packet_id]+x}" ] || continue
    seen_packet[$packet_id]=1
    packet="$repo_root/specs/packets/${packet_id}.md"
    if [ -e "$packet" ]; then
        [ -f "$packet" ] || fail "work packet is not a regular file: specs/packets/${packet_id}.md"
        [ ! -L "$packet" ] || fail "work packet must not be a symlink: specs/packets/${packet_id}.md"
        sources+=("$packet")
    fi
done

refs_tmp="$(mktemp "${TMPDIR:-/tmp}/repomethod-provenance.refs.XXXXXX")"
trap 'rm -f -- "$refs_tmp"' EXIT

# Emits one Plan Ref cell per data row. The column is discovered by its exact
# header, so appending it to the existing table does not disturb the historical
# Test/Evidence column used by verify-acceptance.sh.
plan_ref_cells() {
    local file="$1"
    awk '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        /^## (Acceptance Mapping|Akzeptanz-Mapping)[[:space:]]*$/ {
            in_section=1; header_seen=0; ref_col=0; next
        }
        /^## / { in_section=0; next }
        !in_section || $0 !~ /^\|/ { next }
        {
            line=$0
            sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
            n=split(line, col, "|")
            if (!header_seen) {
                for (i=1; i<=n; i++) if (trim(col[i]) == "Plan Ref") ref_col=i
                header_seen=1
                next
            }
            sep=1
            for (i=1; i<=n; i++) {
                c=trim(col[i])
                if (c !~ /^:?-+:?$/) { sep=0; break }
            }
            if (sep) next
            if (ref_col > 0 && ref_col <= n) print trim(col[ref_col])
        }
    ' "$file"
}

for source in "${sources[@]}"; do
    rel="${source#"$repo_root"/}"
    while IFS= read -r cell || [ -n "$cell" ]; do
        [ -n "$cell" ] || continue
        case "$cell" in '-'|'—') continue ;; esac
        # A non-empty Plan Ref cell is data, not prose. It must be one or more
        # exact backticked obligation IDs separated by commas.
        rest="$cell"
        while :; do
            token="${rest%%,*}"
            if [ "$rest" = "$token" ]; then
                rest=""
            else
                rest="${rest#*,}"
                [[ "$rest" =~ [^[:space:]] ]] \
                    || fail "malformed Plan Ref '$cell' in $rel (empty obligation reference)"
            fi
            token="$(printf '%s' "$token" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            [[ "$token" =~ ^\`(obl\.[a-z0-9][a-z0-9._-]*)\`$ ]] \
                || fail "malformed Plan Ref '$token' in $rel (expected obl.<stable-anchor> in backticks)"
            printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$rel" >> "$refs_tmp"
            [ -n "$rest" ] || break
        done
    done < <(plan_ref_cells "$source")
done

if [ ! -f "$artifact" ]; then
    if [ -s "$refs_tmp" ]; then
        first_ref="$(head -1 "$refs_tmp" | cut -f1)"
        fail "unknown obligation reference $first_ref (plan obligations artifact is missing)"
    fi
    if grep -qE '^## Plan Obligations[[:space:]]*$' "$spec_abs"; then
        # plan-obligations.sh is the authority for deciding whether the section
        # currently contains obligations; a missing artifact after opt-in is a
        # hard precondition failure for provenance too.
        if awk '/^## Plan Obligations[[:space:]]*$/{flag=1;next} /^## /{if(flag)exit} flag' "$spec_abs" \
            | grep -qE '^- `'; then
            fail "plan obligations artifact is missing: .repomethod/workflows/${feature}.plan-obligations.json"
        fi
    fi
    echo "NOT_APPLICABLE: no plan obligations or Plan Ref mappings"
    exit 0
fi
[ ! -L "$artifact" ] || fail "plan obligations artifact must not be a symlink"

jq -e --arg feature "$feature" '
    .schema_version == 1
    and .feature == $feature
    and (.mode == "classic" or .mode == "graph")
    and .review.status == "approved"
    and (.obligations | type == "array")
    and all(.obligations[];
        (.id | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$"))
        and .review_status == "approved")
' "$artifact" >/dev/null 2>&1 || fail "invalid or unapproved plan obligations artifact"

mode="$(jq -r '.mode' "$artifact")"
declare -A known=()
declare -A treated=()
while IFS= read -r id; do known[$id]=1; done < <(jq -r '.obligations[].id' "$artifact")

while IFS=$'\t' read -r ref source; do
    [ -n "$ref" ] || continue
    [ -n "${known[$ref]+x}" ] || fail "unknown obligation reference $ref in $source"
    treated[$ref]=1
done < "$refs_tmp"

# Stateful workflows normalize their gate command to include --state. A manual
# gate may omit it; in that case consume the conventional state if it exists.
if [ -z "$state" ] && [ -f "$repo_root/.repomethod/workflows/${feature}.json" ]; then
    state="$repo_root/.repomethod/workflows/${feature}.json"
fi
if [ -n "$state" ]; then
    case "$state" in /*) ;; *) [ -f "$state" ] || state="$repo_root/$state" ;; esac
    [ -f "$state" ] || fail "workflow state not found: $state"
    state_feature="$(jq -r '.feature? // empty' "$state" 2>/dev/null)" \
        || fail "cannot read workflow state: $state"
    # Legacy/minimal gate fixtures may carry only .mode for plan-obligation
    # binding. They predate the canonical descope state and cannot have a
    # feature-scoped ledger. Real Classic/Graph workflow states always name
    # their feature; only those are eligible for canonical descope consumption.
    if [ -n "$state_feature" ]; then
        [ "$state_feature" = "$feature" ] || fail "workflow state feature does not match $feature"
        canonical_state="$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/descope-ledger.sh" state --state "$state")" \
            || fail "cannot read canonical descope state"
        while IFS= read -r ref; do
            [[ "$ref" =~ ^obl\.[a-z0-9][a-z0-9._-]*$ ]] \
                || fail "malformed obligation reference '$ref' in canonical descope state"
            [ -n "${known[$ref]+x}" ] || fail "unknown obligation reference $ref in canonical descope state"
            treated[$ref]=1
        done < <(jq -r '.descopes[] | select(.status == "accepted") | .plan_ref' <<< "$canonical_state")
    fi
fi

orphans=()
while IFS= read -r id; do
    [ -n "${treated[$id]+x}" ] || orphans+=("$id")
done < <(jq -r '.obligations[].id' "$artifact" | LC_ALL=C sort)

if [ "${#orphans[@]}" -eq 0 ]; then
    echo "OK: plan provenance covers all $(jq '.obligations | length' "$artifact") obligations"
    exit 0
fi

if [ "$mode" = "classic" ]; then
    for id in "${orphans[@]}"; do echo "PROVENANCE-WARN: orphan plan obligation $id"; done
    echo "OK: plan provenance has ${#orphans[@]} orphan obligation(s) in Classic (warning only)"
    exit 0
fi

for id in "${orphans[@]}"; do echo "PROVENANCE-ORPHAN: $id" >&2; done
echo "PROVENANCE-ERROR: Graph blocks ${#orphans[@]} orphan plan obligation(s)" >&2
exit 1
