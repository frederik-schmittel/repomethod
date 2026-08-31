#!/usr/bin/env bash
# lib/blueprint.sh — stage the blueprint into a target repo with conflict
# detection, respecting --preserve / --backup / --force / strict.
set -euo pipefail

blueprint_source_dir() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    printf '%s\n' "${here}/blueprint"
}

# Filters out editor/OS/backup/temporary cruft that has no business being
# installed even if it ends up inside the blueprint source tree (e.g. an
# untracked .DS_Store dropped there by Finder, or a stray vim swap file).
# Matches on basename only, via a fixed pattern list — not on "is this a
# dotfile", since the blueprint legitimately ships plenty of intentional
# dotfiles/dot-directories (.github/, .repomethod/, and the
# .repomethod/gitignore.template that maps to .repomethod/.gitignore).
# Deliberately does not use `git ls-files`:
# the blueprint source must be listed identically whether it's a git
# checkout or an extracted release tarball with no .git directory at all.
blueprint_is_excluded_file() {
    local base
    base="$(basename "$1")"
    case "$base" in
        .DS_Store|Thumbs.db|*.swp|*.swo|*~|*.bak|*.orig) return 0 ;;
        *) return 1 ;;
    esac
}

# npm always excludes files named .gitignore from published tarballs. The
# packaged blueprint therefore stores that one file as
# .repomethod/gitignore.template and maps it back to .repomethod/.gitignore
# while staging. A source checkout that still has a literal
# .repomethod/.gitignore is supported as well, which keeps fixture and
# extracted directory behavior predictable.
blueprint_source_file() {
    local src_dir="$1"
    local rel_path="$2"
    if [ "$rel_path" = ".repomethod/.gitignore" ] && [ ! -f "${src_dir}/.repomethod/.gitignore" ]; then
        printf '%s\n' "${src_dir}/.repomethod/gitignore.template"
    else
        printf '%s\n' "${src_dir}/${rel_path}"
    fi
}

# AGENTS.md and CLAUDE.md are never staged as plain managed files: they are
# host-owned, and RepoMethod only inserts a marker-delimited pointer block
# into them via lib/pointer.sh. stage_blueprint skips these two in both its
# detection and write passes and handles them separately after the loop.
blueprint_is_pointer_file() {
    case "$1" in
        AGENTS.md|CLAUDE.md) return 0 ;;
        *) return 1 ;;
    esac
}

blueprint_list_files() {
    local src_dir="$1"
    local rel_path listing
    # Returns non-zero on an unreadable source OR a `find` that errors
    # mid-traversal (e.g. an unreadable subdirectory). `find` prints a
    # PARTIAL list and still exits non-zero in that case; the listing is
    # captured up front so that status is seen here instead of vanishing
    # into a process substitution the enclosing `while` can never observe.
    # Every caller still captures this function's own status rather than
    # streaming it (see update.sh and stage_blueprint).
    [ -d "$src_dir" ] || { log_error "blueprint source directory not found: ${src_dir}"; return 1; }
    listing="$(cd "$src_dir" && find . -type f)" \
        || { log_error "cannot enumerate the blueprint source (find failed): ${src_dir}"; return 1; }
    while IFS= read -r rel_path; do
        rel_path="${rel_path#./}"
        # A source with no files yields one empty line from `<<< ""`;
        # skipping it preserves the old "empty source -> empty output,
        # return 0" behaviour.
        [ -n "$rel_path" ] || continue
        blueprint_is_excluded_file "$rel_path" && continue
        if [ "$rel_path" = ".repomethod/gitignore.template" ]; then
            [ -f "${src_dir}/.repomethod/.gitignore" ] || printf '%s\n' ".repomethod/.gitignore"
        else
            printf '%s\n' "$rel_path"
        fi
    done <<< "$listing"
}

# The set of relative paths this package's own blueprint ships — the file
# list of blueprint_source_dir(), the tree INSIDE the running package, which
# the target repository cannot modify. This is the independent evidence the
# manifest is not: a "blueprint" entry naming a path outside this set was
# never installed by this version of RepoMethod, whatever the manifest says.
# Deliberately NOT parameterised with --source: the version-bound listing is
# exactly what makes it trustworthy. skill-link entries are NOT covered here
# (a manage-skills.sh-added skill is a legitimate local skill the package
# blueprint has never heard of) — manifest_entry_trusted checks those against
# their canonical .repomethod/skills/<name> directory and link target string
# instead. That is the honest limit of this mechanism, not an oversight.
blueprint_inventory() {
    blueprint_list_files "$(blueprint_source_dir)"
}

stage_blueprint() {
    local target_dir="$1"
    local mode="$2"
    local version="$3"
    local profiles_csv="$4"
    local prior_manifest_json="${5:-}"

    local src_dir
    src_dir="$(blueprint_source_dir)"

    local stat_style target_id git_id=""
    stat_style="$(detect_stat_style "$target_dir")"
    target_id="$(stat_id "$stat_style" "$target_dir")"
    [ -e "${target_dir}/.git" ] && git_id="$(stat_id "$stat_style" "${target_dir}/.git")"

    # Snapshot the file list up front so it can be walked twice: once to
    # detect conflicts (no disk writes) and once to actually stage files.
    local -a files=()
    local files_raw
    files_raw="$(blueprint_list_files "$src_dir")" \
        || die "cannot enumerate the blueprint source: ${src_dir}"
    [ -n "$files_raw" ] && mapfile -t files <<< "$files_raw"

    local src_file dst_file src_hash dst_hash

    # Pass 1: detection only. Nothing is written to disk here. In strict
    # mode this lets us abort on the first sign of a conflict without ever
    # leaving partially-staged files or a stale/missing manifest behind.
    #
    # require_path_contained is called before any read/hash of dst_file —
    # not after — because dst_file may be a symlink pointing outside
    # target_dir (e.g. AGENTS.md -> ../../outside/secret). Hashing or
    # diffing through it here would read and (in the strict-mode reporting
    # loop below) print the external target's content before the escape is
    # ever detected. require_path_contained dies on a symlink leaf on its
    # own, so this both blocks the read and reports the conflict.
    local -a conflicts=()
    for rel_path in "${files[@]}"; do
        blueprint_is_pointer_file "$rel_path" && continue
        src_file="$(blueprint_source_file "$src_dir" "$rel_path")"
        dst_file="${target_dir}/${rel_path}"

        # Checked unconditionally, even when dst_file doesn't exist yet:
        # require_path_contained ascends to the nearest existing ancestor
        # on its own, so this also catches a not-yet-existing leaf under a
        # symlinked ancestor directory (e.g. scripts -> /outside, with
        # scripts/foo.sh not itself present) — which the old "skip if
        # dst_file doesn't exist" ordering let slip past pass 1 entirely,
        # letting pass 2 write every file that sorts before the escaped
        # one before it ever got there.
        require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"

        if [ ! -e "$dst_file" ] && [ ! -L "$dst_file" ]; then
            continue
        fi

        src_hash="$(sha256_file "$src_file")"
        dst_hash="$(sha256_file "$dst_file")"

        if [ "$src_hash" != "$dst_hash" ]; then
            conflicts+=("$rel_path")
        fi
    done

    if [ "$mode" = "strict" ] && [ "${#conflicts[@]}" -gt 0 ]; then
        for rel_path in "${conflicts[@]}"; do
            log_error "conflict: ${rel_path} already exists with different content"
            diff -u "${target_dir}/${rel_path}" "$(blueprint_source_file "$src_dir" "$rel_path")" || true
        done
        die "aborting: re-run with --preserve, --backup, or --force"
    fi

    # Pass 2: only reached once strict mode is confirmed conflict-free (or
    # mode is preserve/backup/force). Safe to write to disk now.
    local manifest
    manifest="$(manifest_init "$version" "$profiles_csv")"

    # Fresh per-call, collision-proof even within the same second: a
    # date-based prefix for readability plus a mktemp-generated random
    # suffix so two calls in the same process (or the same wall-clock
    # second) never share a backup directory. -u only prints a name, it
    # does not create anything, so this works before the parent directory
    # exists. Uses only POSIX date/mktemp flags so it behaves the same on
    # BSD (macOS) and GNU (Linux/CI).
    local backup_run_dir=""
    if [ "$mode" = "backup" ]; then
        # Checked before the mkdir below: a .repomethod replaced by a
        # symlink pointing outside target_dir must never receive a created
        # backups/ directory. This runs before the per-file loop's own
        # require_path_contained calls even start, so it cannot rely on
        # those to catch it first.
        require_path_contained "$stat_style" "$target_id" "$git_id" "${target_dir}/.repomethod/backups"
        # BSD mktemp (macOS) insists the parent directory exist even with
        # -u, unlike GNU mktemp; create it first so this behaves the same
        # on both platforms.
        mkdir -p "${target_dir}/.repomethod/backups"
        backup_run_dir="$(mktemp -u "${target_dir}/.repomethod/backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    fi

    for rel_path in "${files[@]}"; do
        blueprint_is_pointer_file "$rel_path" && continue
        src_file="$(blueprint_source_file "$src_dir" "$rel_path")"
        dst_file="${target_dir}/${rel_path}"
        require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"

        if [ ! -e "$dst_file" ]; then
            # Re-checked immediately before each sink: blueprint_source_file
            # and (below) sha256_file fork between the top-of-loop check and
            # here, so a concurrent writer could swap an already-checked
            # ancestor for a symlink in that window. Narrows it to bash
            # builtins; does not close it.
            require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
            mkdir -p "$(dirname "$dst_file")"
            require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
            cp "$src_file" "$dst_file"
            src_hash="$(sha256_file "$src_file")"
            manifest="$(manifest_add_file "$manifest" "$rel_path" "$src_hash" "blueprint")"
            continue
        fi

        src_hash="$(sha256_file "$src_file")"
        dst_hash="$(sha256_file "$dst_file")"

        if [ "$src_hash" = "$dst_hash" ]; then
            manifest="$(manifest_add_file "$manifest" "$rel_path" "$src_hash" "blueprint")"
            continue
        fi

        case "$mode" in
            strict)
                # Defensive fallback only: pass 1 already aborted above if
                # any conflict existed, so this should be unreachable.
                log_error "conflict: ${rel_path} already exists with different content"
                diff -u "$dst_file" "$src_file" || true
                die "aborting: re-run with --preserve, --backup, or --force"
                ;;
            preserve)
                # Source "local", not "blueprint": this content was never
                # repomethod's, so update.sh/uninstall.sh must never refresh
                # or delete it just because its hash happens to still match
                # what's recorded here.
                log_warn "keeping local version of ${rel_path} (--preserve)"
                manifest="$(manifest_add_file "$manifest" "$rel_path" "$dst_hash" "local")"
                ;;
            backup)
                # sha256_file forked twice above; re-check both the backup
                # path and the managed target separately, each immediately
                # before its own sink.
                require_path_contained "$stat_style" "$target_id" "$git_id" "${backup_run_dir}/${rel_path}"
                mkdir -p "$(dirname "${backup_run_dir}/${rel_path}")"
                require_path_contained "$stat_style" "$target_id" "$git_id" "${backup_run_dir}/${rel_path}"
                cp "$dst_file" "${backup_run_dir}/${rel_path}"
                require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
                cp "$src_file" "$dst_file"
                manifest="$(manifest_add_file "$manifest" "$rel_path" "$src_hash" "blueprint")"
                ;;
            force)
                require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
                cp "$src_file" "$dst_file"
                manifest="$(manifest_add_file "$manifest" "$rel_path" "$src_hash" "blueprint")"
                ;;
            *)
                die "unknown stage_blueprint mode: ${mode}"
                ;;
        esac
    done

    # AGENTS.md / CLAUDE.md: host-owned files that only receive a marker-
    # delimited pointer block. Handled here, after every plain managed file,
    # so a pointer-block conflict never leaves other files half-written
    # (install.sh additionally runs preflight_pointer_block before this
    # whole function on a fresh install). The stub source files supply the
    # header used only when the target file has to be created from nothing.
    # The backticks in the block strings below are literal markdown, not
    # command substitution.
    #
    # `|| return 1` is load-bearing: pointer_stage's own die() runs inside
    # this command substitution, so its exit only ends the $(...) subshell.
    # Without an explicit check, a caller that has errexit disabled (bats
    # `run`, for one) would see the assignment fail silently and carry on.
    # shellcheck disable=SC2016
    manifest="$(pointer_stage "$target_dir" "AGENTS.md" \
        "$(cat "${src_dir}/AGENTS.md")" \
        'Follow the repository engineering contract in `.repomethod/AGENTS.md`.' \
        '<!-- repomethod:begin -->' '<!-- repomethod:end -->' \
        "$prior_manifest_json" "$manifest")" || return 1
    # shellcheck disable=SC2016
    manifest="$(pointer_stage "$target_dir" "CLAUDE.md" \
        "$(cat "${src_dir}/CLAUDE.md")" \
        'Claude Code follows the repository engineering contract in `.repomethod/AGENTS.md`.' \
        '<!-- repomethod:begin -->' '<!-- repomethod:end -->' \
        "$prior_manifest_json" "$manifest")" || return 1

    require_path_contained "$stat_style" "$target_id" "$git_id" "${target_dir}/.repomethod/manifest.json"
    manifest_write "$manifest" "${target_dir}/.repomethod/manifest.json"
}
