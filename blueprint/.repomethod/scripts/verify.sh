#!/usr/bin/env bash
# verify.sh [--warn-frontend-uncovered] [repo-dir] — runs the repository's own verification command from
# .repomethod/verify-command and trusts only its exit status. RepoMethod
# performs no stack detection, dependency installation, or package-manager
# guessing: the target repository defines what "verified" means, this
# script only makes that command mandatory in the completion gate.
# Every non-comment, non-blank line of the file runs, in order; all must
# exit 0. The first non-zero exit fails this script with that status.
set -euo pipefail

warn_frontend_uncovered=false
if [ "${1:-}" = "--warn-frontend-uncovered" ]; then
    warn_frontend_uncovered=true
    shift
fi
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [[ "$1" == --* ]]; }; then
    echo "[verify] usage: verify.sh [--warn-frontend-uncovered] [repo-dir]" >&2
    exit 1
fi

dir="${1:-.}"
command_file="${dir}/.repomethod/verify-command"

# One-shot, best-effort coverage hint. Any failure while collecting or
# inspecting the heuristic inputs is treated as "no warning" and never
# changes verification's exit status.
_warn_frontend_uncovered() {
    local repo_dir="$1"
    local verify_file="${repo_dir}/.repomethod/verify-command"
    local active_lines changed grep_status

    [ -f "$verify_file" ] || return 0
    if ! changed="$({
        git -C "$repo_dir" diff --name-only &&
        git -C "$repo_dir" diff --cached --name-only &&
        git -C "$repo_dir" ls-files --others --exclude-standard
    } 2>/dev/null | sort -u)"; then
        return 0
    fi

    grep_status=0
    grep -Eq '\.(ts|tsx|js|jsx)$' <<< "$changed" || grep_status=$?
    [ "$grep_status" -eq 0 ] || return 0

    grep_status=0
    active_lines="$(grep -Ev '^[[:space:]]*(#|$)' "$verify_file" 2>/dev/null)" || grep_status=$?
    case "$grep_status" in
        0) ;;
        1) active_lines="" ;;
        *) return 0 ;;
    esac

    grep_status=0
    grep -Eq 'pnpm|npm|npx|vitest|jest|tsc|eslint' <<< "$active_lines" || grep_status=$?
    case "$grep_status" in
        0) return 0 ;;
        1) ;;
        *) return 0 ;;
    esac

    echo "WARN: change touches frontend files but verify-command runs no JS check" >&2
    return 0
}

if [ "$warn_frontend_uncovered" = true ]; then
    _warn_frontend_uncovered "$dir" || true
fi

# Best-effort hints only: scan the target for the usual test entry points and
# name what's actually there, so the adopter doesn't have to try every suite.
# Rough parsing on purpose — this is a suggestion list, not a contract.
list_candidates() {
    if [ -f "${dir}/Makefile" ]; then
        local targets
        targets="$(grep -Eo '^[a-zA-Z0-9][a-zA-Z0-9_.-]*:' "${dir}/Makefile" \
            | sed 's/:$//' | grep -Ev '^\.' | sort -u | head -n 12 | paste -sd ' ' -)"
        [ -n "$targets" ] && echo "  Makefile targets: ${targets} (e.g. \"make ${targets%% *}\")" >&2
    fi
    if [ -f "${dir}/pyproject.toml" ] && grep -q '\[tool\.pytest' "${dir}/pyproject.toml"; then
        echo "  pyproject.toml configures pytest — try \"pytest\"" >&2
    fi
    if [ -f "${dir}/package.json" ]; then
        local scripts
        scripts="$(sed -n '/"scripts"[[:space:]]*:[[:space:]]*{/,/}/p' "${dir}/package.json" \
            | grep -Eo '"[^"]+"[[:space:]]*:' | sed -E 's/[[:space:]]*:$//; s/"//g' \
            | grep -Ev '^scripts$' | head -n 12 | paste -sd ' ' -)"
        [ -n "$scripts" ] && echo "  package.json scripts: ${scripts} (e.g. \"npm test\")" >&2
    fi
}

fail_unconfigured() {
    echo "[verify] no verification command configured — set one non-comment line in ${command_file}" >&2
    list_candidates
    exit 1
}

[ -f "$command_file" ] || fail_unconfigured

# grep exits 1 (no match) when the file is comments/blanks only — a
# legitimate, expected outcome here, not a real error — so the pipeline is
# explicitly neutralized with `|| true` under `set -o pipefail`; without
# it, that 1 would abort this script via `set -e` before ever reaching the
# friendly fail_unconfigured() message below.
command_lines="$(grep -Ev '^[[:space:]]*(#|$)' "$command_file" || true)"
[ -n "$command_lines" ] || fail_unconfigured

# Run every non-comment / non-blank line in order; the first non-zero exit
# fails the script with that status, all-zero succeeds.
while IFS= read -r line; do
    echo "[verify] ${line}" >&2
    (cd "$dir" && eval "$line") </dev/null || exit $?
done < <(grep -Ev '^[[:space:]]*(#|$)' "$command_file")
