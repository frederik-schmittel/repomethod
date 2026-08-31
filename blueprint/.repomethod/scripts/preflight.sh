#!/usr/bin/env bash
# preflight.sh [--quiet] — diagnose the explicitly configured environment.
#
# Collects every finding first, then prints them in a fixed order. Writes no
# file and never runs the verify-command. HARD findings make the exit non-zero;
# WARN findings do not. --quiet drops all WARN findings before counting and
# printing. Must stay bash-3 safe up to the bash-version report (no mapfile, no
# associative arrays, no bash-4-only syntax before that check).
set -euo pipefail

QUIET=false
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--quiet" ]; }; then
    echo "usage: preflight.sh [--quiet]" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    QUIET=true
fi

findings=()

# 1. Bash version — hard below major 4. Bash-3-safe up to this point.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    findings+=("HARD: bash 4.0+ required (current: ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}) | FIX: run RepoMethod with bash 4.0 or newer")
    printf 'PREFLIGHT: %d problem(s)\n' "${#findings[@]}"
    printf '%s\n' "${findings[@]}"
    exit 1
fi

# Repo root: git top-level, else pwd -P. The fallback adds no finding.
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="$(pwd -P)"
root="$(cd "$root" && pwd -P)"

# 2. Git version — hard if missing, unparsable, or below 2.20.
if ! command -v git >/dev/null 2>&1; then
    findings+=("HARD: git 2.20+ required (current: missing) | FIX: install git 2.20 or newer")
else
    gv="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    if [ -z "$gv" ]; then
        findings+=("HARD: git 2.20+ required (current: missing) | FIX: install git 2.20 or newer")
    else
        gmaj="${gv%%.*}"
        gmin="${gv#*.}"
        gmin="${gmin%%.*}"
        if [ "$gmaj" -lt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -lt 20 ]; }; then
            findings+=("HARD: git 2.20+ required (current: ${gv}) | FIX: install git 2.20 or newer")
        fi
    fi
fi

# 3. jq — hard if not on PATH.
if ! command -v jq >/dev/null 2>&1; then
    findings+=("HARD: jq not found | FIX: install jq and put it on PATH")
fi

# 4. Verify configuration.
vc_file="${root}/.repomethod/verify-command"
active_lines=()
if [ ! -f "$vc_file" ]; then
    findings+=("HARD: .repomethod/verify-command missing | FIX: create it with one verification command per active line")
else
    while IFS= read -r vc_line; do
        active_lines+=("$vc_line")
    done < <(grep -E '^[[:space:]]*[^[:space:]#]' "$vc_file" || true)
    if [ "${#active_lines[@]}" -eq 0 ]; then
        findings+=("HARD: .repomethod/verify-command has no active command | FIX: add at least one non-comment command")
    fi
fi

# 5. Direct verify runners — first whitespace-delimited token of each active
#    line, leading whitespace stripped, deduped, in line order. No shell parsing,
#    no special-casing of env/assignments/operators.
if [ "${#active_lines[@]}" -gt 0 ]; then
    seen_tokens=" "
    for vc_line in "${active_lines[@]}"; do
        read -r token _ <<<"$vc_line" || true
        [ -n "${token:-}" ] || continue
        case "$seen_tokens" in
            *" ${token} "*) continue ;;
        esac
        seen_tokens="${seen_tokens}${token} "
        if ! command -v "$token" >/dev/null 2>&1; then
            findings+=("HARD: verify-command program '${token}' not found | FIX: install '${token}' or correct .repomethod/verify-command")
        fi
    done
fi

# 6. Detached HEAD — warn.
if command -v git >/dev/null 2>&1 && ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
    findings+=("WARN: HEAD is detached | FIX: check out the intended branch before starting a workflow")
fi

# 7. Foreign VIRTUAL_ENV — warn if set and not the project's .venv. Compare
#    physically normalized paths; a not-yet-existing project path compares
#    lexically as <repo-root>/.venv.
if [ -n "${VIRTUAL_ENV:-}" ]; then
    project_venv="${root}/.venv"
    if [ -d "$project_venv" ]; then
        project_venv="$(cd "$project_venv" 2>/dev/null && pwd -P || printf '%s' "$project_venv")"
    fi
    active_venv="$VIRTUAL_ENV"
    if [ -d "$active_venv" ]; then
        active_venv="$(cd "$active_venv" 2>/dev/null && pwd -P || printf '%s' "$active_venv")"
    fi
    if [ "$active_venv" != "$project_venv" ]; then
        findings+=("WARN: VIRTUAL_ENV is not ${root}/.venv | FIX: deactivate it or activate ${root}/.venv")
    fi
fi

# 8. node_modules symlinks under <repo-root>, pruning <repo-root>/.git — one warn
#    per relative path, lexicographically sorted.
while IFS= read -r nm_path; do
    [ -n "$nm_path" ] || continue
    findings+=("WARN: node_modules symlink at ${nm_path#"$root"/} | FIX: remove it or keep the path covered by .repomethod/scope-ignore.txt")
done < <(find "$root" -path "${root}/.git" -prune -o -type l -name node_modules -print 2>/dev/null | LC_ALL=C sort)

# --quiet drops WARN findings before counting and printing.
if [ "$QUIET" = true ] && [ "${#findings[@]}" -gt 0 ]; then
    kept=()
    for f in "${findings[@]}"; do
        case "$f" in
            WARN:*) ;;
            *) kept+=("$f") ;;
        esac
    done
    findings=()
    [ "${#kept[@]}" -eq 0 ] || findings=("${kept[@]}")
fi

hard=0
if [ "${#findings[@]}" -gt 0 ]; then
    for f in "${findings[@]}"; do
        case "$f" in
            HARD:*) hard=$((hard + 1)) ;;
        esac
    done
fi

if [ "$QUIET" = true ] && [ "$hard" -eq 0 ]; then
    exit 0
fi

printf 'PREFLIGHT: %d problem(s)\n' "${#findings[@]}"
if [ "${#findings[@]}" -gt 0 ]; then
    printf '%s\n' "${findings[@]}"
fi

if [ "$hard" -gt 0 ]; then
    exit 1
fi
exit 0
