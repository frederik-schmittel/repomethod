#!/usr/bin/env bash
# plan-obligations.sh <extract|approve|check> --mode <quick-mvp|classic|graph>
#   [--spec <spec.md>] [--repo <dir>]
#   [--revision <n>] [--approval-text <text>]
#
# Extracts explicitly declared plan obligations from a feature spec into a
# feature-scoped JSON artifact. Stable IDs come from explicit anchors, never
# from statement content. An extraction revision must be reviewed before any
# downstream gate may consume it.
set -euo pipefail

command="${1:-}"
[ -n "$command" ] || {
    echo "usage: plan-obligations.sh <extract|approve|check> --mode <quick-mvp|classic|graph> [--spec <spec.md>] [--repo <dir>] [--revision <n>] [--approval-text <text>]" >&2
    exit 1
}
shift

mode=""
spec=""
repo="."
revision=""
approval_text=""

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "error: missing value for $1" >&2
        exit 1
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) require_value "$@"; mode="$2"; shift 2 ;;
        --spec) require_value "$@"; spec="$2"; shift 2 ;;
        --repo) require_value "$@"; repo="$2"; shift 2 ;;
        --revision) require_value "$@"; revision="$2"; shift 2 ;;
        --approval-text) require_value "$@"; approval_text="$2"; shift 2 ;;
        *) echo "error: unknown flag: $1" >&2; exit 1 ;;
    esac
done

case "$command" in extract|approve|check) ;; *) echo "error: unknown command: $command" >&2; exit 1 ;; esac
case "$mode" in quick-mvp|classic|graph) ;; *) echo "error: --mode must be quick-mvp, classic, or graph" >&2; exit 1 ;; esac
[ -d "$repo" ] || { echo "error: repo not found: $repo" >&2; exit 1; }
repo_root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "error: $repo is not inside a Git repository" >&2; exit 1; }
repo_root="$(cd "$repo_root" && pwd -P)"

if [ "$mode" = "quick-mvp" ]; then
    case "$command" in
        approve)
            echo "error: quick-mvp has no plan-obligation approval step" >&2
            exit 1
            ;;
        extract|check)
            echo "NOT_APPLICABLE: quick-mvp has no persistent plan obligations"
            exit 0
            ;;
    esac
fi

[ -n "$spec" ] || { echo "error: --spec is required for $mode $command" >&2; exit 1; }
[ -f "$spec" ] || { echo "error: spec not found: $spec" >&2; exit 1; }
[ ! -L "$spec" ] || { echo "error: spec must not be a symlink: $spec" >&2; exit 1; }
spec_abs="$(cd "$(dirname "$spec")" && pwd -P)/$(basename "$spec")"
case "$spec_abs" in
    "$repo_root"/*) plan_source="${spec_abs#"$repo_root"/}" ;;
    *) echo "error: spec must be inside the repository: $spec" >&2; exit 1 ;;
esac

[ "$(dirname "$plan_source")" = "specs" ] \
    || { echo "error: plan source must be a top-level feature spec under specs/: $plan_source" >&2; exit 1; }

feature="$(basename "$spec")"
feature="${feature%.md}"
[[ "$feature" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || { echo "error: spec basename must be a feature slug: $feature" >&2; exit 1; }

metadata_dir="${repo_root}/.repomethod"
workflow_dir="${metadata_dir}/workflows"
[ ! -L "$metadata_dir" ] || { echo "error: .repomethod must not be a symlink" >&2; exit 1; }
[ ! -L "$workflow_dir" ] || { echo "error: .repomethod/workflows must not be a symlink" >&2; exit 1; }
artifact="${workflow_dir}/${feature}.plan-obligations.json"
[ ! -L "$artifact" ] || { echo "error: plan obligations artifact must not be a symlink" >&2; exit 1; }

section_count="$(grep -cE '^## Plan Obligations[[:space:]]*$' "$spec_abs" || true)"
[ "$section_count" -le 1 ] || { echo "error: malformed ## Plan Obligations section (expected at most one heading)" >&2; exit 1; }

parsed="$(mktemp "${TMPDIR:-/tmp}/repomethod-plan-obligations.parsed.XXXXXX")"
old_core="$(mktemp "${TMPDIR:-/tmp}/repomethod-plan-obligations.old.XXXXXX")"
new_core="$(mktemp "${TMPDIR:-/tmp}/repomethod-plan-obligations.new.XXXXXX")"
trap 'rm -f -- "$parsed" "$old_core" "$new_core"' EXIT

parse_obligations() {
    : > "$parsed"
    [ "$section_count" -eq 1 ] || return 0

    local raw line trimmed in_comment=false anchor type text line_re
    local -A seen=()
    line_re='^- `([a-z0-9][a-z0-9._-]*)` \[(shape|behaviour|prohibition|process)\] (.+)$'

    while IFS= read -r raw || [ -n "$raw" ]; do
        line="${raw%$'\r'}"
        trimmed="$line"
        while [[ "$trimmed" == [[:space:]]* ]]; do trimmed="${trimmed#?}"; done
        while [[ "$trimmed" == *[[:space:]] ]]; do trimmed="${trimmed%?}"; done

        if [ "$in_comment" = true ]; then
            case "$trimmed" in *'-->'*) in_comment=false ;; esac
            continue
        fi
        case "$trimmed" in
            '') continue ;;
            '<!--'*'-->') continue ;;
            '<!--'*) in_comment=true; continue ;;
        esac

        if [[ ! "$trimmed" =~ $line_re ]]; then
            echo "error: malformed Plan Obligations declaration: $trimmed" >&2
            return 1
        fi
        anchor="${BASH_REMATCH[1]}"
        type="${BASH_REMATCH[2]}"
        text="${BASH_REMATCH[3]}"
        [ -n "$text" ] || { echo "error: empty Plan Obligations statement for $anchor" >&2; return 1; }
        if [ -n "${seen[$anchor]:-}" ]; then
            echo "error: duplicate Plan Obligations anchor/id collision: $anchor" >&2
            return 1
        fi
        seen[$anchor]=1
        jq -cn \
            --arg id "obl.${anchor}" \
            --arg anchor "$anchor" \
            --arg source_ref "${plan_source}#plan-obligations:${anchor}" \
            --arg type "$type" \
            --arg text "$text" \
            '{id:$id,anchor:$anchor,source_ref:$source_ref,type:$type,text:$text,review_status:"pending"}' \
            >> "$parsed"
    done < <(
        awk '
            /^## Plan Obligations[[:space:]]*$/ { flag=1; next }
            /^## / { if (flag) exit }
            flag { print }
        ' "$spec_abs"
    )

    if [ "$in_comment" = true ]; then
        echo "error: unterminated HTML comment in ## Plan Obligations" >&2
        return 1
    fi
}

validate_artifact() {
    local file="$1"
    jq -e '
        .schema_version == 1
        and (.feature | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
        and (.mode == "classic" or .mode == "graph")
        and (.plan_source | type == "string" and length > 0)
        and (.source_digest | type == "string" and test("^[0-9a-f]{40}$"))
        and (.revision | type == "number" and floor == . and . >= 1)
        and (.review | type == "object")
        and (.review.status == "pending" or .review.status == "approved")
        and (.review.revision == .revision)
        and (
            if .review.status == "pending" then
                (.review.approved_at == null and .review.approval_text == null)
            else
                (.review.approved_at | type == "string" and length > 0)
                and (.review.approval_text | type == "string" and length > 0)
            end
        )
        and (.obligations | type == "array")
        and (([.obligations[].id] | length) == ([.obligations[].id] | unique | length))
        and (([.obligations[].anchor] | length) == ([.obligations[].anchor] | unique | length))
        and all(.obligations[];
            (.id | type == "string" and startswith("obl."))
            and (.anchor | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
            and (.id == ("obl." + .anchor))
            and (.source_ref | type == "string" and length > 0)
            and (.type == "shape" or .type == "behaviour" or .type == "prohibition" or .type == "process")
            and (.text | type == "string" and length > 0)
            and (.review_status == "pending" or .review_status == "approved")
        )
        and (.revision_diff | type == "object")
        and (.revision_diff.added | type == "array")
        and (.revision_diff.removed | type == "array")
        and (.revision_diff.changed | type == "array")
    ' "$file" >/dev/null 2>&1
}

parse_obligations
jq -s '.' "$parsed" > "$new_core"
canonical="$(jq -r 'sort_by(.id)[] | [.anchor,.type,.text] | @tsv' "$new_core")"
source_digest="$(printf '%s' "$canonical" | git hash-object --stdin)"

artifact_matches_source() {
    local file="$1"
    validate_artifact "$file" || return 1
    [ "$(jq -r '.feature' "$file")" = "$feature" ] || return 1
    [ "$(jq -r '.mode' "$file")" = "$mode" ] || return 1
    [ "$(jq -r '.plan_source' "$file")" = "$plan_source" ] || return 1
    [ "$(jq -r '.source_digest' "$file")" = "$source_digest" ] || return 1
    jq '[.obligations[] | {id,anchor,source_ref,type,text}] | sort_by(.id)' "$file" > "$old_core"
    jq '[.[] | {id,anchor,source_ref,type,text}] | sort_by(.id)' "$new_core" > "${new_core}.compare"
    cmp -s "$old_core" "${new_core}.compare"
    local rc=$?
    rm -f -- "${new_core}.compare"
    return "$rc"
}

case "$command" in
    check)
        if [ ! -f "$artifact" ]; then
            if [ "$(jq 'length' "$new_core")" -eq 0 ]; then
                echo "NOT_APPLICABLE: spec declares no plan obligations"
                exit 0
            fi
            echo "error: current plan obligations artifact is missing: ${artifact#"$repo_root"/}" >&2
            exit 1
        fi
        validate_artifact "$artifact" || { echo "error: invalid plan obligations artifact: ${artifact#"$repo_root"/}" >&2; exit 1; }
        artifact_matches_source "$artifact" || { echo "error: plan obligations artifact is stale or does not match the current spec" >&2; exit 1; }
        [ "$(jq -r '.review.status' "$artifact")" = "approved" ] \
            || { echo "error: plan obligations revision $(jq -r '.revision' "$artifact") is not approved" >&2; exit 1; }
        if jq -e 'any(.obligations[]; .review_status != "approved")' "$artifact" >/dev/null; then
            echo "error: plan obligations artifact contains unreviewed obligations" >&2
            exit 1
        fi
        echo "OK: approved plan obligations revision $(jq -r '.revision' "$artifact")"
        ;;

    approve)
        [ -f "$artifact" ] || { echo "error: plan obligations artifact is missing: ${artifact#"$repo_root"/}" >&2; exit 1; }
        validate_artifact "$artifact" || { echo "error: invalid plan obligations artifact: ${artifact#"$repo_root"/}" >&2; exit 1; }
        artifact_matches_source "$artifact" || { echo "error: cannot approve stale plan obligations extraction" >&2; exit 1; }
        case "$revision" in ''|*[!0-9]*) echo "error: --revision must be a positive integer" >&2; exit 1 ;; esac
        [ "$revision" -gt 0 ] || { echo "error: --revision must be a positive integer" >&2; exit 1; }
        [ "$revision" = "$(jq -r '.revision' "$artifact")" ] \
            || { echo "error: displayed revision $revision is stale; current revision is $(jq -r '.revision' "$artifact")" >&2; exit 1; }
        [ -n "$approval_text" ] || { echo "error: --approval-text is required" >&2; exit 1; }
        approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        tmp="$(mktemp "${artifact}.tmp.XXXXXX")"
        jq --arg at "$approved_at" --arg text "$approval_text" '
            .review = {status:"approved",revision:.revision,approved_at:$at,approval_text:$text}
            | .obligations |= map(.review_status = "approved")
        ' "$artifact" > "$tmp"
        validate_artifact "$tmp" || { rm -f "$tmp"; echo "error: approval would create an invalid plan obligations artifact" >&2; exit 1; }
        mv "$tmp" "$artifact"
        echo "APPROVED: plan obligations revision $revision"
        ;;

    extract)
        if [ -f "$artifact" ]; then
            validate_artifact "$artifact" || { echo "error: invalid existing plan obligations artifact: ${artifact#"$repo_root"/}" >&2; exit 1; }
            [ "$(jq -r '.feature' "$artifact")" = "$feature" ] \
                || { echo "error: existing artifact feature does not match spec feature" >&2; exit 1; }
            [ "$(jq -r '.mode' "$artifact")" = "$mode" ] \
                || { echo "error: existing artifact mode does not match --mode" >&2; exit 1; }
            [ "$(jq -r '.plan_source' "$artifact")" = "$plan_source" ] \
                || { echo "error: existing artifact plan source does not match --spec" >&2; exit 1; }

            if artifact_matches_source "$artifact"; then
                echo "UNCHANGED: plan obligations revision $(jq -r '.revision' "$artifact") ($(jq -r '.review.status' "$artifact"))"
                exit 0
            fi

            old_revision="$(jq -r '.revision' "$artifact")"
            next_revision=$((old_revision + 1))
            old_obligations="$(mktemp "${TMPDIR:-/tmp}/repomethod-plan-obligations.old-obligations.XXXXXX")"
            jq '.obligations' "$artifact" > "$old_obligations"

            reviewed_new="$(mktemp "${TMPDIR:-/tmp}/repomethod-plan-obligations.reviewed.XXXXXX")"
            jq --slurpfile old "$old_obligations" '
                ($old[0] | map({key:.id,value:.}) | from_entries) as $old_by_id
                | map(.review_status = (
                    if ($old_by_id[.id] != null)
                       and ($old_by_id[.id].type == .type)
                       and ($old_by_id[.id].text == .text)
                    then $old_by_id[.id].review_status
                    else "pending"
                    end
                ))
            ' "$new_core" > "$reviewed_new"

            diff_json="$(jq -n --slurpfile old "$old_obligations" --slurpfile new "$reviewed_new" '
                ($old[0] | map({key:.id,value:.}) | from_entries) as $old_by_id
                | ($new[0] | map({key:.id,value:.}) | from_entries) as $new_by_id
                | {
                    added: [ $new[0][] | select($old_by_id[.id] == null) ],
                    removed: [ $old[0][] | select($new_by_id[.id] == null) ],
                    changed: [
                        $new[0][]
                        | select($old_by_id[.id] != null)
                        | select(($old_by_id[.id].type != .type) or ($old_by_id[.id].text != .text))
                        | {id:.id,before:{type:$old_by_id[.id].type,text:$old_by_id[.id].text},after:{type:.type,text:.text}}
                    ]
                }
            ')"

            mkdir -p "$(dirname "$artifact")"
            tmp="$(mktemp "${artifact}.tmp.XXXXXX")"
            jq -n \
                --arg feature "$feature" --arg mode "$mode" --arg source "$plan_source" \
                --arg digest "$source_digest" --argjson revision "$next_revision" \
                --slurpfile obligations "$reviewed_new" --argjson revision_diff "$diff_json" '
                {
                    schema_version:1,
                    feature:$feature,
                    mode:$mode,
                    plan_source:$source,
                    source_digest:$digest,
                    revision:$revision,
                    review:{status:"pending",revision:$revision,approved_at:null,approval_text:null},
                    obligations:$obligations[0],
                    revision_diff:$revision_diff
                }
            ' > "$tmp"
            rm -f -- "$old_obligations" "$reviewed_new"
            validate_artifact "$tmp" || { rm -f "$tmp"; echo "error: extraction produced an invalid plan obligations artifact" >&2; exit 1; }
            mv "$tmp" "$artifact"
            echo "EXTRACTED: revision $next_revision pending review"
            jq -c '.revision_diff' "$artifact"
            exit 0
        fi

        if [ "$(jq 'length' "$new_core")" -eq 0 ]; then
            echo "NOT_APPLICABLE: spec declares no plan obligations"
            exit 0
        fi

        mkdir -p "$(dirname "$artifact")"
        tmp="$(mktemp "${artifact}.tmp.XXXXXX")"
        diff_json="$(jq -n --slurpfile new "$new_core" '{added:$new[0],removed:[],changed:[]}')"
        jq -n \
            --arg feature "$feature" --arg mode "$mode" --arg source "$plan_source" \
            --arg digest "$source_digest" --slurpfile obligations "$new_core" \
            --argjson revision_diff "$diff_json" '
            {
                schema_version:1,
                feature:$feature,
                mode:$mode,
                plan_source:$source,
                source_digest:$digest,
                revision:1,
                review:{status:"pending",revision:1,approved_at:null,approval_text:null},
                obligations:$obligations[0],
                revision_diff:$revision_diff
            }
        ' > "$tmp"
        validate_artifact "$tmp" || { rm -f "$tmp"; echo "error: extraction produced an invalid plan obligations artifact" >&2; exit 1; }
        mv "$tmp" "$artifact"
        echo "EXTRACTED: revision 1 pending review"
        jq -c '.revision_diff' "$artifact"
        ;;
esac
