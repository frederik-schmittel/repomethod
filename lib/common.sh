#!/usr/bin/env bash
# lib/common.sh — logging, command checks, temp-dir lifecycle.
set -euo pipefail

# Without this, a die()/exit inside a function called via command
# substitution (e.g. `x="$(some_func)"`) that is itself running inside
# another command-substitution subshell does NOT abort the outer chain —
# bash's default errexit behavior silently swallows the failure past one
# level of $(...) nesting, letting the script continue as if nothing failed.
# Every entry point (install.sh/update.sh/uninstall.sh/release.sh) sources
# this file first and calls sourced lib functions through exactly that
# pattern (e.g. install.sh's `manifest="$(stage_core_skills ...)"`, which
# itself calls `mode="$(stage_skill_link ...)"`), so this is a real,
# systemic gap, not specific to one call site. Requires Bash 4.4+; on an
# older Bash the option name itself doesn't exist, so guard the `shopt`
# call rather than letting an unsupported-option failure trip `set -e`
# during sourcing on the Bash 4.0-4.3 case README still claims to support.
shopt -s inherit_errexit 2>/dev/null || true

REPOMETHOD_TMP_DIRS=()
REPOMETHOD_TMP_TRACKING_FILE=""

log_info() { printf '[info] %s\n' "$1" >&2; }
log_warn() { printf '[warn] %s\n' "$1" >&2; }
log_error() { printf '[error] %s\n' "$1" >&2; }

die() {
    log_error "$1"
    exit 1
}

# Fail fast on an unsupported Bash. lib/ and the blueprint scripts use
# bash 4+ features (inherit_errexit, mapfile); on stock macOS bash 3.2 they
# break with cryptic errors. README states the 4.4+ requirement — this
# enforces it at every entry point that sources this file. Args override
# the detected version for testing.
require_bash_44() {
    local major="${1:-${BASH_VERSINFO[0]:-0}}" minor="${2:-${BASH_VERSINFO[1]:-0}}"
    if [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 4 ]; }; then
        return 0
    fi
    die "repomethod needs Bash 4.4 or newer (found ${major}.${minor}). On macOS: 'brew install bash', then run with that bash on PATH."
}

require_bash_44

# Prints "gnu" or "bsd" depending on which `stat` flag syntax works here.
# Call once per script run (not per file) and pass the result into stat_id.
detect_stat_style() {
    if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
        printf 'gnu\n'
    else
        printf 'bsd\n'
    fi
}

# Prints the "device:inode" identity of an existing path, or nothing if it
# doesn't exist. Two differently-spelled paths that resolve to the same
# on-disk entry always report the same identity — unlike string/prefix
# comparison, this can't be fooled by a symlink or a differently-cased
# lookup on a case-insensitive filesystem. See uninstall.sh's identity-based
# containment comment block for the fuller rationale (this is the same
# technique, factored out for reuse).
stat_id() {
    local style="$1" path="$2"
    if [ "$style" = "gnu" ]; then
        stat -c '%d:%i' "$path" 2>/dev/null
    else
        stat -f '%d:%i' "$path" 2>/dev/null
    fi
}

# Dies unless <path> resolves inside <target_id> (the target repository
# root's stat identity) without passing through <git_id> (the target's
# .git, always off-limits — pass "" to skip that check). <path> need not
# exist yet: the walk starts at <path> itself and ascends through ".." until
# it hits an existing ancestor, so a not-yet-created file is checked via its
# nearest real parent directory. Walking by identity rather than string
# matching means it can't be fooled by any ancestor component — however
# deep — being a symlink to somewhere outside the target; install.sh and
# update.sh call this immediately before every write, which is what makes a
# repo like `scripts -> /tmp/somewhere-else` a refused conflict instead of a
# silent write outside the repository.
require_path_contained() {
    local style="$1" target_id="$2" git_id="$3" path="$4"

    # A symlink at the exact write target would let cp silently follow it
    # and overwrite whatever it points to, wherever that is. Every caller of
    # this function writes plain managed files — repomethod never creates a
    # symlink at one of these paths (only stage_skill_link does, for
    # .agents|.claude/skills/<name>, a completely different namespace) — so
    # any symlink found here is never repomethod's own and is never safe to
    # write through, regardless of where it happens to point.
    if [ -L "$path" ]; then
        die "refusing to write through an existing symlink: ${path}"
    fi

    # Check the leaf itself first (covers a path that already exists and
    # directly IS .git, or already matches target_id) — the only step
    # allowed to target something that isn't a directory. stat_id failing
    # here (path doesn't exist yet — the common case for a file about to be
    # created) is an expected, handled signal, not a real error; without
    # `|| true`, inherit_errexit (see above) would abort this function's
    # caller on that non-zero status before it ever reaches the check below.
    local leaf_id
    leaf_id="$(stat_id "$style" "$path" || true)"
    if [ -n "$leaf_id" ]; then
        if [ -n "$git_id" ] && [ "$leaf_id" = "$git_id" ]; then
            die "refusing to write inside .git: ${path}"
        fi
        [ "$leaf_id" = "$target_id" ] && return 0
    fi

    # Ascend through ancestor directories only, via dirname to find the
    # first one that actually exists. stat can never resolve through a
    # not-yet-existing path component or through a regular file — appending
    # "/.." to either fails outright rather than "resolving up" the way it
    # does for a real directory — so this dirname pre-walk (purely "does
    # this exist", not a security check) finds a safe place to start the
    # identity-based ".." ascent below.
    local dir
    dir="$(dirname "$path")"
    while [ ! -e "$dir" ]; do
        dir="$(dirname "$dir")"
    done

    local cur_id prev_id="" steps=0
    while [ -n "$dir" ]; do
        # Hard backstop, not expected to ever trigger: every case above was
        # reasoned through, but this ascent already produced two genuine
        # infinite loops before landing on this shape, so it earns a bound
        # rather than trusting the reasoning a third time.
        steps=$((steps + 1))
        [ "$steps" -gt 200 ] && die "path containment check exceeded ${steps} steps, aborting: ${path}"

        # An ancestor symlink whose target lies INSIDE target_dir (e.g. an
        # ancestor symlinked straight at .git) defeats the identity ascent
        # below on its own: appending "/.." to a path that runs through a
        # symlink dereferences the symlink first and ascends from ITS
        # resolved location, never comparing the symlink's own identity
        # against anything — so the walk lands back at target_id without
        # ever touching git_id. This check only fires meaningfully on the
        # first visit to a given real ancestor (once "/.." has been
        # appended, "$dir" ends in ".." whose own directory entry is never
        # itself a symlink, so the test is a harmless no-op on later
        # iterations of the same ancestor). repomethod never creates a
        # directory symlink anywhere on a managed write path — including
        # .agents/.claude themselves, the parents
        # stage_skill_link writes its symlinks into — so any symlinked
        # ancestor found here is never repomethod's own and is never safe
        # to write through.
        if [ -L "$dir" ]; then
            die "refusing to write through an existing symlink: ${dir}"
        fi

        cur_id="$(stat_id "$style" "$dir" || true)"
        if [ -n "$cur_id" ]; then
            if [ -n "$git_id" ] && [ "$cur_id" = "$git_id" ]; then
                die "refusing to write inside .git: ${path}"
            fi
            [ "$cur_id" = "$target_id" ] && return 0
            [ "$cur_id" = "$prev_id" ] && break
            prev_id="$cur_id"
        fi
        dir="${dir}/.."
    done
    die "refusing to write outside the target repository: ${path}"
}

# Convenience wrapper around require_path_contained for call sites that only
# have a target_dir and a candidate path on hand (no pre-computed
# stat_style/target_id/git_id) — e.g. lib/skills.sh's stage_skill_link and
# manifest-path checks in install.sh/update.sh/uninstall.sh. Recomputes the
# stat identity on every call rather than threading it through every
# caller's signature; these call sites are not hot loops, so the extra
# stat(2) calls are not worth the API complexity of passing identity
# through everywhere.
require_repo_path_contained() {
    local target_dir="$1" path="$2"
    local style target_id git_id=""
    style="$(detect_stat_style "$target_dir")"
    target_id="$(stat_id "$style" "$target_dir")"
    [ -e "${target_dir}/.git" ] && git_id="$(stat_id "$style" "${target_dir}/.git")"
    require_path_contained "$style" "$target_id" "$git_id" "$path"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command not found: ${cmd}"
    fi
}

# Requires register_cleanup_trap to have been called first whenever this is
# invoked via command substitution (e.g. dir=$(make_temp_dir)): the tracking
# file it appends to is only created there, and subshells can't update
# REPOMETHOD_TMP_DIRS in the parent shell's environment.
make_temp_dir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/repomethod.XXXXXX")"
    REPOMETHOD_TMP_DIRS+=("$dir")
    if [ -z "$REPOMETHOD_TMP_TRACKING_FILE" ]; then
        log_warn "tracking file not initialized — call register_cleanup_trap before make_temp_dir"
    elif ! echo "$dir" >> "$REPOMETHOD_TMP_TRACKING_FILE" 2>/dev/null; then
        log_warn "failed to write to tracking file: ${REPOMETHOD_TMP_TRACKING_FILE}"
    fi
    printf '%s\n' "$dir"
}

cleanup_temp_dirs() {
    local dir
    # Clean up from tracking file (for directories created in subshells via command substitution)
    if [ -f "$REPOMETHOD_TMP_TRACKING_FILE" ]; then
        while IFS= read -r dir; do
            if [ -n "$dir" ] && [ -d "$dir" ]; then
                rm -rf -- "$dir" || true
            fi
        done < "$REPOMETHOD_TMP_TRACKING_FILE"
        rm -f "$REPOMETHOD_TMP_TRACKING_FILE"
    fi
    # Clean up from array (for directories created in main shell)
    for dir in "${REPOMETHOD_TMP_DIRS[@]:-}"; do
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            rm -rf -- "$dir" || true
        fi
    done
}

# Helper for register_cleanup_trap: receives the prior EXIT trap's command
# (already correctly unescaped by bash's own `eval` argument parsing — see
# below) and stashes it for _repomethod_run_exit_traps to invoke later.
_repomethod_capture_prior_exit_trap() {
    _REPOMETHOD_PRIOR_EXIT_TRAP="$1"
}

# The actual EXIT trap installed by register_cleanup_trap. Runs our own
# cleanup first, then any trap that was already registered before we chained
# onto it (e.g. bats-core's own internal EXIT trap).
_repomethod_run_exit_traps() {
    cleanup_temp_dirs
    if [ -n "${_REPOMETHOD_PRIOR_EXIT_TRAP:-}" ]; then
        eval "$_REPOMETHOD_PRIOR_EXIT_TRAP"
    fi
}

# Call this before any make_temp_dir call that uses command substitution
# (e.g. dir=$(make_temp_dir)) — it creates the tracking file that lets
# subshell-created temp dirs be found and cleaned up on exit. Idempotent:
# calling it more than once in a process reuses the existing tracking file
# instead of orphaning it.
register_cleanup_trap() {
    if [ -z "$REPOMETHOD_TMP_TRACKING_FILE" ]; then
        REPOMETHOD_TMP_TRACKING_FILE="$(mktemp "${TMPDIR:-/tmp}/.repomethod-tracking.XXXXXX")"
    fi
    # Chain onto any pre-existing EXIT trap (e.g. bats-core's own internal
    # EXIT trap, which it relies on to detect/report per-test completion)
    # instead of clobbering it. Guard against re-chaining onto ourselves if
    # this function is called more than once in the same process.
    local existing
    existing="$(trap -p EXIT)"

    # Already registered by us in this process — don't re-chain onto ourselves.
    case "$existing" in
        *_repomethod_run_exit_traps*) return 0 ;;
    esac

    if [ -n "$existing" ]; then
        # `trap -p EXIT` prints output designed to be eval'd back verbatim
        # (e.g. trap -- '<command>' EXIT), with single-quote escaping that
        # is only meaningful when re-parsed by the shell. Replacing the
        # literal `trap -- ` prefix with a call to our capture function and
        # then eval'ing the result lets bash's own argument parsing recover
        # the original command exactly — no manual quote-stripping, so it
        # can't be corrupted by quotes, semicolons, or anything else the
        # prior trap's command contains.
        eval "${existing/trap -- /_repomethod_capture_prior_exit_trap }"
    fi

    trap _repomethod_run_exit_traps EXIT
}
