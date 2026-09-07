#!/usr/bin/env bash
# verify-spec-lint.sh --spec <spec.md>
#
# Fails closed when a persisted Classic/Graph feature spec has no meaningful
# Scope or Acceptance Criteria. This is deliberately structural: it checks
# declared constraints, not whether their natural-language wording is good.
set -euo pipefail

spec=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$spec" ]; then
    echo "usage: verify-spec-lint.sh --spec <spec.md>" >&2
    exit 1
fi
[ -f "$spec" ] || { echo "REJECTED: spec not found: ${spec}" >&2; exit 1; }

section_count() {
    grep -cE "^## ${1}[[:space:]]*$" "$spec" || true
}

section_lines() {
    awk -v heading="$1" '
        {
            line=$0
            sub(/\r$/, "", line)
        }
        line ~ "^## " heading "[[:space:]]*$" { in_section=1; next }
        line ~ /^## / { in_section=0 }
        in_section { print line }
    ' "$spec"
}

meaningful_scope=false
in_comment=false
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
        ''|'<!--'*'-->') continue ;;
        '<!--'*) in_comment=true; continue ;;
    esac

    # A Scope normally uses Markdown list entries. Treat a bare placeholder and
    # a list-wrapped placeholder alike, while allowing any other declared path.
    candidate="$trimmed"
    case "$candidate" in '- '*) candidate="${candidate#'- '}" ;; esac
    candidate="${candidate#\`}"; candidate="${candidate%\`}"
    lower="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in ''|'-'|tbd|todo|'???') continue ;; esac
    meaningful_scope=true
    break
done < <(section_lines "Scope")

scope_count="$(section_count "Scope")"
if [ "$scope_count" -ne 1 ] || [ "$meaningful_scope" != true ]; then
    echo "REJECTED: Scope must exist exactly once and contain a non-placeholder declaration" >&2
    exit 1
fi

acceptance_section_lines() {
    awk '
        {
            line=$0
            sub(/\r$/, "", line)
        }
        line ~ /^## (Acceptance Criteria|Akzeptanzkriterien)[[:space:]]*$/ { in_section=1; next }
        line ~ /^## / { in_section=0 }
        in_section { print line }
    ' "$spec"
}

has_acceptance_item=false
in_comment=false
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    trimmed="$line"
    while [[ "$trimmed" == [[:space:]]* ]]; do trimmed="${trimmed#?}"; done

    if [ "$in_comment" = true ]; then
        case "$trimmed" in *'-->'*) in_comment=false ;; esac
        continue
    fi
    case "$trimmed" in
        ''|'<!--'*'-->') continue ;;
        '<!--'*) in_comment=true; continue ;;
    esac

    case "$trimmed" in
        '- '*) has_acceptance_item=true ;;
        '* '*) has_acceptance_item=true ;;
        [0-9]*'. '*) has_acceptance_item=true ;;
    esac
    [ "$has_acceptance_item" = true ] && break
done < <(acceptance_section_lines)

acceptance_count="$(($(section_count "Acceptance Criteria") + $(section_count "Akzeptanzkriterien")))"
if [ "$acceptance_count" -ne 1 ] || [ "$has_acceptance_item" != true ]; then
    echo "REJECTED: Acceptance Criteria must exist exactly once and contain a checklist or list item" >&2
    exit 1
fi

echo "OK: spec structure has meaningful Scope and Acceptance Criteria"
