#!/usr/bin/env bash
# verify-scope.sh --spec <spec.md> [--base <ref>] [--state <file>] [--repo <dir>]
# verify-scope.sh --quick --base <base-ref> [--repo <dir>]
#
# Base priority (full mode): explicit --base; else config.base_ref from --state;
# else the automatic resolve_base (@{upstream} / origin/HEAD / main).
#
# Full mode: checks that committed, staged, unstaged, and untracked files
# fall within the spec's declared Scope section and do not touch protected
# zones unless explicitly and exactly listed in Scope.
#
# Quick mode (no spec): the protected-zone boundary only — fail if any
# changed file matches .repomethod/protected-zones.txt. Used by the
# quick-mvp close-out, where there is no spec to authorize anything.
set -euo pipefail

spec=""
base=""
state_file=""
repo="."
quick=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) quick=true; shift ;;
        --spec) spec="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --state) state_file="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

explicit_base=false
[ -n "$base" ] && explicit_base=true

# --state carries a workflow's pinned config.base_ref; it is only meaningful for
# the full, spec-driven mode and must point at a readable JSON state file.
if [ "$quick" = true ] && [ -n "$state_file" ]; then
    echo "--state is only valid with --spec" >&2
    exit 1
fi
if [ -n "$state_file" ]; then
    { [ -f "$state_file" ] && jq -e . "$state_file" >/dev/null 2>&1; } \
        || { echo "state not found: $state_file" >&2; exit 1; }
fi

resolve_base() {
    local dir="${1:-.}" mb ref up cur
    up="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    # <remote>/<same-branch> is this branch's own pushed copy, not a fork
    # point — skip it and fall through to origin/HEAD, then main.
    if [ -n "$up" ] && [ "${up#*/}" != "$cur" ]; then
        if mb="$(git -C "$dir" merge-base HEAD "$up" 2>/dev/null)" && [ -n "$mb" ]; then
            printf '%s\n' "$mb"
            return 0
        fi
    fi
    if ref="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$ref" ]; then
        if mb="$(git -C "$dir" merge-base HEAD "$ref" 2>/dev/null)" && [ -n "$mb" ]; then
            printf '%s\n' "$mb"
            return 0
        fi
    fi
    if git -C "$dir" rev-parse --verify --quiet 'main^{commit}' >/dev/null 2>&1; then
        printf '%s\n' "main"
        return 0
    fi
    echo "error: cannot resolve a base ref — pass --base <ref>" >&2
    exit 1
}

# Base priority: explicit --base; else config.base_ref from --state; else the
# existing resolve_base. A non-empty state value that is not a 40-character
# lowercase SHA, or not a commit in --repo, fails hard and never falls back.
if [ "$explicit_base" = false ] && [ -n "$state_file" ]; then
    state_base="$(jq -r '.config.base_ref? // empty' "$state_file")"
    if [ -n "$state_base" ]; then
        case "$state_base" in
            *[!0-9a-f]*|'') echo "invalid config.base_ref in state: $state_base" >&2; exit 1 ;;
        esac
        { [ "${#state_base}" -eq 40 ] \
            && git -C "$repo" rev-parse --verify --quiet "${state_base}^{commit}" >/dev/null; } \
            || { echo "invalid config.base_ref in state: $state_base" >&2; exit 1; }
        base="$state_base"
    fi
fi
[ -n "$base" ] || base="$(resolve_base "$repo")"

require_base_ref() {
    git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
        || { echo "error: cannot resolve base ref '${base}' in ${repo} (fetch it, or pass --base <ref>)" >&2; exit 1; }
}

# A base that resolves but is not an ancestor of HEAD (an explicit wrong
# --base, or a `main` fallback on a branch that forks elsewhere) makes the
# `base...HEAD` diff report unrelated files. Emit the signal and still run
# the check — the diagnostic prints before any VIOLATION line.
warn_if_base_not_ancestor() {
    git -C "$repo" merge-base --is-ancestor "$base" HEAD 2>/dev/null \
        || echo "base ${base} is not an ancestor of HEAD — wrong --base?" >&2
    warn_if_base_stale
}

# The ancestor check above only catches a divergent base. A base that IS an
# ancestor but sits further back than the real fork point (a stale
# `origin/main`, an old tag) silently pulls already-merged commits into
# `base...HEAD` and inflates the change set into false VIOLATIONs. Compare the
# base against what resolve_base would pick and flag a mismatch — a no-op when
# the base was auto-resolved (it then equals resolve_base's own output).
warn_if_base_stale() {
    local auto auto_sha base_sha
    auto="$(resolve_base "$repo" 2>/dev/null)" || return 0
    [ -n "$auto" ] || return 0
    auto_sha="$(git -C "$repo" rev-parse --verify --quiet "${auto}^{commit}")" || return 0
    base_sha="$(git -C "$repo" rev-parse --verify --quiet "${base}^{commit}")" || return 0
    [ "$auto_sha" = "$base_sha" ] || echo \
        "base ${base} differs from the resolved fork point ${auto} (${auto_sha}) — scope diff may include already-merged commits; omit --base to use it" >&2
}

# git's rename detection is on by default and --name-only then reports only
# a rename's DESTINATION, so a file moved out of a protected zone vanishes
# from the change set. --no-renames makes every move appear as its delete
# plus its add, which is exactly the set of paths a scope and protected-zone
# gate has to see. (An unstaged move is already a delete + an untracked
# file, so it was never affected — the flag is a no-op there.)
changed_in_repo() {
    {
        git -C "$repo" diff --no-renames --name-only "${base}...HEAD" || exit 1
        git -C "$repo" diff --cached --no-renames --name-only || exit 1
        git -C "$repo" diff --no-renames --name-only || exit 1
        git -C "$repo" ls-files --others --exclude-standard || exit 1
    } | sort -u
}

if [ "$quick" = true ]; then
    if [ -z "$base" ]; then
        echo "usage: verify-scope.sh --quick --base <base-ref> [--repo <dir>]" >&2
        exit 1
    fi
    require_base_ref
    q_protected=()
    [ -f "${repo}/.repomethod/protected-zones.txt" ] \
        && mapfile -t q_protected < "${repo}/.repomethod/protected-zones.txt"
    q_violations=0
    [ "$explicit_base" = true ] && warn_if_base_not_ancestor
    q_changed_raw="$(changed_in_repo)" || { echo "error: could not enumerate changed files" >&2; exit 1; }
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        for pp in "${q_protected[@]}"; do
            [ -z "$pp" ] && continue
            # shellcheck disable=SC2254
            case "$f" in
                $pp)
                    echo "VIOLATION: ${f} (protected zone; a quick-mvp change may not touch it)"
                    q_violations=$((q_violations + 1))
                    break
                    ;;
            esac
        done
    done <<< "$q_changed_raw"
    [ "$q_violations" -gt 0 ] && exit 1
    echo "OK: no protected zones touched"
    exit 0
fi

if [ -z "$spec" ] || [ -z "$base" ]; then
    echo "usage: verify-scope.sh --spec <spec.md> --base <base-ref> [--repo <dir>]" >&2
    exit 1
fi
[ -f "$spec" ] || { echo "spec not found: ${spec}" >&2; exit 1; }
require_base_ref

# Extract backtick-quoted scope entries between "## Scope" and the next "##".
# shellcheck disable=SC2016
mapfile -t scope_patterns < <(
    awk '/^## Scope/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -E '^- ' \
    | sed -E 's/^- `([^`]+)`.*/\1/'
)

protected_file="${repo}/.repomethod/protected-zones.txt"
protected_patterns=()
if [ -f "$protected_file" ]; then
    mapfile -t protected_patterns < "$protected_file"
fi

# scope-ignore.txt lists paths the gate must not evaluate at all — a
# node_modules symlink in a linked worktree, say, which does not match the
# .gitignore `node_modules/` rule and so lands in `git ls-files --others`.
# A match is dropped from the change set before the scope check. It does NOT
# override protected-zones.txt: the protected check runs first and still
# reports a protected path that also matches a line here.
scope_ignore_file="${repo}/.repomethod/scope-ignore.txt"
scope_ignore_patterns=()
if [ -f "$scope_ignore_file" ]; then
    mapfile -t scope_ignore_patterns < "$scope_ignore_file"
fi

# If the spec file itself lives inside the repo, its own path is exempt from
# the "must be covered by a Scope glob" check (a task's spec document is not
# part of the scope it declares). It is NOT exempt from the protected-zone
# check below. Both --repo and --spec are normalized to absolute paths before
# comparing, since callers may pass either relative or absolute forms (e.g.
# --repo . --spec .repomethod/templates/spec.md), mirroring the absolute-path resolution
# already used in lib/target.sh's validate_target.
repo_abs="$(cd "$repo" && pwd)"
if [ -f "$spec" ]; then
    spec_abs="$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
else
    spec_abs=""
fi
spec_rel=""
case "$spec_abs" in
    "$repo_abs"/*) spec_rel="${spec_abs#"$repo_abs"/}" ;;
esac

matches_pattern() {
    local file="$1" pattern="$2"
    # shellcheck disable=SC2254
    case "$file" in
        $pattern) return 0 ;;
        *) return 1 ;;
    esac
}

is_scope_ignored() {
    local file="$1" p
    for p in "${scope_ignore_patterns[@]}"; do
        [ -z "$p" ] && continue
        case "$p" in \#*) continue ;; esac
        if matches_pattern "$file" "$p"; then
            return 0
        fi
    done
    return 1
}

is_exact_scope_line() {
    local file="$1" p
    for p in "${scope_patterns[@]}"; do
        [ "$p" = "$file" ] && return 0
    done
    return 1
}

is_managed_runtime_artifact() {
    case "$1" in
        .repomethod/workflows/*) return 0 ;;
        .repomethod/evidence/*) return 0 ;;
        .repomethod/project-map.md) return 0 ;;
        *) return 1 ;;
    esac
}

[ "$explicit_base" = true ] && warn_if_base_not_ancestor
changed_raw="$(changed_in_repo)" || { echo "error: could not enumerate changed files" >&2; exit 1; }
mapfile -t changed_files <<< "$changed_raw"

violations=0
checked=0
for f in "${changed_files[@]}"; do
    [ -z "$f" ] && continue

    is_spec_file=false
    [ -n "$spec_rel" ] && [ "$f" = "$spec_rel" ] && is_spec_file=true

    in_protected=false
    for pp in "${protected_patterns[@]}"; do
        [ -z "$pp" ] && continue
        if matches_pattern "$f" "$pp"; then
            in_protected=true
            break
        fi
    done

    if [ "$in_protected" = true ] && ! is_exact_scope_line "$f"; then
        echo "VIOLATION: ${f}"
        violations=$((violations + 1))
        continue
    fi

    # After the protected check so a protected path can never be ignored
    # away: a match here is dropped from scope evaluation entirely.
    if is_scope_ignored "$f"; then
        continue
    fi

    if [ "$is_spec_file" = true ]; then
        continue
    fi

    # These paths are produced by the installed workflow itself. They describe
    # state or evidence for the scoped change and are not implementation scope.
    if is_managed_runtime_artifact "$f"; then
        continue
    fi

    checked=$((checked + 1))

    in_scope=false
    for sp in "${scope_patterns[@]}"; do
        if matches_pattern "$f" "$sp"; then
            in_scope=true
            break
        fi
    done

    if [ "$in_scope" = false ]; then
        echo "VIOLATION: ${f}"
        violations=$((violations + 1))
    fi
done

if [ "$violations" -gt 0 ]; then
    exit 1
fi

echo "OK: ${checked} files in scope"
exit 0
