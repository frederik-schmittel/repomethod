#!/usr/bin/env bash
# verify-forbidden.sh --spec <spec.md> [--repo <dir>]
#
# Enforces an optional "## Must Not Exist" section. Backticked declarations
# are fixed strings by default; an explicit "regex:" prefix opts into POSIX
# extended regular expressions. Only tracked and non-ignored untracked files
# whose repository-relative path matches the spec's Scope are searched.
#
# File contents are scanned verbatim. Comments and docstrings therefore count
# as matches unless a future language-aware handler explicitly says otherwise;
# unknown file types are never silently skipped. Scoped symlinks and other
# non-regular Git entries fail closed instead of being followed or ignored.
set -euo pipefail

spec=""
repo="."

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$spec" ]; then
    echo "usage: verify-forbidden.sh --spec <spec.md> [--repo <dir>]" >&2
    exit 1
fi
[ -f "$spec" ] || { echo "spec not found: ${spec}" >&2; exit 1; }
[ -d "$repo" ] || { echo "repo not found: ${repo}" >&2; exit 1; }

git_top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "error: ${repo} is not inside a Git repository" >&2; exit 1; }
git_top="$(cd "$git_top" && pwd -P)"
repo_abs="$git_top"

section_count="$(grep -cE '^## Must Not Exist[[:space:]]*$' "$spec" || true)"
if [ "$section_count" -eq 0 ]; then
    exit 0
fi
if [ "$section_count" -ne 1 ]; then
    echo "error: malformed ## Must Not Exist section (expected exactly one heading)" >&2
    exit 1
fi

modes=()
patterns=()
in_comment=false
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    trimmed="$line"
    while [[ "$trimmed" == [[:space:]]* ]]; do trimmed="${trimmed#?}"; done
    while [[ "$trimmed" == *[[:space:]] ]]; do trimmed="${trimmed%?}"; done

    if [ "$in_comment" = true ]; then
        case "$trimmed" in
            *'-->'*) in_comment=false ;;
        esac
        continue
    fi

    case "$trimmed" in
        '') continue ;;
        '<!--'*'-->') continue ;;
        '<!--'*) in_comment=true; continue ;;
    esac

    mode=""
    pattern=""
    if [[ "$trimmed" == '- regex: `'*'`' ]]; then
        mode="regex"
        pattern="${trimmed#'- regex: `'}"
        pattern="${pattern%'`'}"
    elif [[ "$trimmed" == '- `'*'`' ]]; then
        mode="fixed"
        pattern="${trimmed#'- `'}"
        pattern="${pattern%'`'}"
    else
        echo "error: malformed Must Not Exist declaration: ${trimmed}" >&2
        exit 1
    fi

    if [ -z "$pattern" ] || [[ "$pattern" == *'`'* ]]; then
        echo "error: malformed Must Not Exist declaration: ${trimmed}" >&2
        exit 1
    fi

    if [ "$mode" = "regex" ]; then
        regex_rc=0
        LC_ALL=C grep -E -- "$pattern" /dev/null >/dev/null 2>&1 || regex_rc=$?
        if [ "$regex_rc" -gt 1 ]; then
            echo "error: invalid Must Not Exist regex: ${pattern}" >&2
            exit 1
        fi
    fi

    modes+=("$mode")
    patterns+=("$pattern")
done < <(
    awk '
        /^## Must Not Exist[[:space:]]*$/ { flag=1; next }
        /^## / { if (flag) exit }
        flag { print }
    ' "$spec"
)

if [ "$in_comment" = true ]; then
    echo "error: unterminated HTML comment in ## Must Not Exist" >&2
    exit 1
fi

if [ "${#patterns[@]}" -eq 0 ]; then
    exit 0
fi

# Keep Scope semantics byte-for-byte aligned with verify-scope.sh: backticked
# bullet entries between "## Scope" and the next level-two heading, interpreted
# as Bash case patterns against repository-relative paths.
# shellcheck disable=SC2016
mapfile -t scope_patterns < <(
    awk '/^## Scope/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -E '^- ' \
    | sed -E 's/^- `([^`]+)`.*/\1/'
)
if [ "${#scope_patterns[@]}" -eq 0 ]; then
    echo "error: ## Must Not Exist requires at least one valid ## Scope entry" >&2
    exit 1
fi

spec_abs="$(cd "$(dirname "$spec")" && pwd -P)/$(basename "$spec")"
spec_rel=""
case "$spec_abs" in
    "$repo_abs"/*) spec_rel="${spec_abs#"$repo_abs"/}" ;;
esac

matches_scope() {
    local file="$1" scope_pattern
    for scope_pattern in "${scope_patterns[@]}"; do
        # shellcheck disable=SC2254
        case "$file" in
            $scope_pattern) return 0 ;;
        esac
    done
    return 1
}

listing="$(mktemp "${TMPDIR:-/tmp}/repomethod-forbidden.XXXXXX")"
match_lines="$(mktemp "${TMPDIR:-/tmp}/repomethod-forbidden-lines.XXXXXX")"
trap 'rm -f -- "$listing" "$match_lines"' EXIT
# Always enumerate from the Git top-level so paths remain repository-relative
# even when callers pass a repository subdirectory via --repo.
if ! git -C "$repo_abs" ls-files -z --cached --others --exclude-standard > "$listing"; then
    echo "error: could not enumerate repository files" >&2
    exit 1
fi

checked=0
violations=0
while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    [ -n "$spec_rel" ] && [ "$file" = "$spec_rel" ] && continue
    matches_scope "$file" || continue

    full_path="${repo_abs}/${file}"
    # A tracked file deleted in the working tree already satisfies a negative
    # requirement. Everything that still exists must be safe to inspect.
    [ -e "$full_path" ] || [ -L "$full_path" ] || continue
    if [ -L "$full_path" ]; then
        echo "error: scoped path is a symlink and cannot be scanned safely: ${file}" >&2
        exit 1
    fi
    if [ ! -f "$full_path" ]; then
        echo "error: scoped path is not a regular file: ${file}" >&2
        exit 1
    fi

    checked=$((checked + 1))
    for i in "${!patterns[@]}"; do
        grep_rc=0
        if [ "${modes[$i]}" = "fixed" ]; then
            LC_ALL=C grep -a -nF -- "${patterns[$i]}" "$full_path" \
                | sed -E 's/:.*$//' > "$match_lines" || grep_rc=$?
        else
            LC_ALL=C grep -a -nE -- "${patterns[$i]}" "$full_path" \
                | sed -E 's/:.*$//' > "$match_lines" || grep_rc=$?
        fi

        case "$grep_rc" in
            0)
                while IFS= read -r line_no; do
                    [ -n "$line_no" ] || continue
                    echo "FORBIDDEN: ${file}:${line_no} (${modes[$i]}: ${patterns[$i]})"
                    violations=$((violations + 1))
                done < "$match_lines"
                ;;
            1) ;;
            *)
                echo "error: could not scan scoped file: ${file}" >&2
                exit 1
                ;;
        esac
    done
done < "$listing"

if [ "$violations" -gt 0 ]; then
    exit 1
fi

echo "OK: ${checked} scoped files contain no forbidden declarations"
exit 0
