#!/usr/bin/env bash
# uninstall.sh — remove blueprint-managed files whose content is unmodified.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${HERE}/lib/common.sh"
# shellcheck source=lib/blueprint.sh disable=SC1091
source "${HERE}/lib/blueprint.sh"
# shellcheck source=lib/target.sh disable=SC1091
source "${HERE}/lib/target.sh"
# shellcheck source=lib/manifest.sh disable=SC1091
source "${HERE}/lib/manifest.sh"
# shellcheck source=lib/pointer.sh disable=SC1091
source "${HERE}/lib/pointer.sh"

require_cmd jq

register_cleanup_trap

target=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) target="$2"; shift 2 ;;
        *) die "unknown flag: $1" ;;
    esac
done
[ -z "$target" ] && die "--target is required"

target_abs="$(validate_target "$target")"
manifest_path="${target_abs}/.repomethod/manifest.json"

# Checked before the manifest is even read: a .repomethod replaced by a
# symlink pointing outside target_abs must never be read from or (at the
# end of this script) deleted from. This is independent of the manifest
# ENTRY containment checks in the main loop below, which only ever cover
# each entry's own recorded path, not the manifest file itself.
require_repo_path_contained "$target_abs" "$manifest_path"

manifest="$(manifest_read "$manifest_path")"

# The .git / target-containment safety checks below compare device:inode
# identity rather than canonicalized path strings. lib/common.sh provides
# the two primitives: detect_stat_style picks the platform's stat syntax
# once per run (GNU accepts "-f" too but reads it as a filesystem report,
# so the syntax must be chosen before asking for identity), and stat_id
# reads a path's "device:inode" with that style.
stat_style="$(detect_stat_style "$target_abs")"

target_id="$(stat_id "$stat_style" "$target_abs")"
git_id=""
if [ -e "${target_abs}/.git" ]; then
    git_id="$(stat_id "$stat_style" "${target_abs}/.git")"
fi

mapfile -t rel_paths < <(jq -r '.files | keys[]' <<<"$manifest")

removed_dirs=()
untrusted_entries=0
# Seed the trusted blueprint inventory once (forks one `find`) so the
# per-entry manifest_entry_trusted call below can cross-check each
# "blueprint" key against the file list this package version actually ships.
manifest_trust_init
for rel_path in "${rel_paths[@]}"; do
    dst_file="${target_abs}/${rel_path}"
    recorded_hash="$(manifest_file_hash "$manifest" "$rel_path")"

    # A managed symlink may already be dangling because its canonical skill
    # directory was removed before uninstall. It still has link state on
    # disk, so do not treat it as an absent path here: if its canonical
    # .repomethod/skills/<name> dir is present the trust check below verifies
    # and it is removed; if that dir is gone the same check CONFLICTs it and
    # it is left on disk and reported (Task 10B).
    if [ ! -e "$dst_file" ] && [ ! -L "$dst_file" ]; then
        continue
    fi

    # The manifest is attacker-writable state, not a record of fact. Before
    # any hash/identity/removal work, require the entry to be structurally
    # trusted: a known source class and a plain relative key (and, for the
    # namespaced classes, the right namespace). An entry that fails is left
    # on disk and reported as a CONFLICT rather than acted on.
    if ! entry_reason="$(manifest_entry_trusted "$manifest" "$rel_path" "$target_abs" 2>&1)"; then
        log_warn "CONFLICT (manifest entry not independently verifiable, left on disk): ${rel_path} — ${entry_reason##*: }"
        untrusted_entries=1
        continue
    fi

    # Compute the content hash BEFORE the containment/identity check below,
    # not after. sha256_file forks an external process (sha256sum/shasum)
    # and reads the whole file — measurably slower than the in-process
    # stat(2) calls the identity check below makes. The manifest `source`
    # lookup (jq, another fork) is hoisted up here for the same reason:
    # everything that forks — the content hash and the manifest source
    # lookup — happens before the ascent, so the ascent is the last thing
    # before rm, with nothing but bash builtins in between. That minimizes
    # (plain bash has no O_NOFOLLOW/openat-style primitive to eliminate it
    # outright) the window in which a concurrent writer could swap an
    # already-checked ancestor directory for a symlink into .git between the
    # check and the removal. An earlier version computed the hash after the
    # check, which left a multi-hundred-millisecond window dominated by the
    # sha256sum/shasum fork+exec; that window was verified exploitable —
    # swapping the ancestor directory for a symlink into .git during it
    # caused a real file inside .git to be deleted despite the check having
    # passed moments earlier.
    #
    # A manifest path that is itself a symlink (the .agents/skills/<name> /
    # .claude/skills/<name> core-skill links from lib/skills.sh) is a
    # special case: sha256_file follows the symlink and tries to hash
    # whatever it points at, but that target is a *directory*
    # (.repomethod/skills/<name>), and sha256sum/shasum can't hash a
    # directory — it exits non-zero, which would kill this script outright
    # under set -e. For these, "unmodified" means "the link still points
    # where we put it", so compare readlink output (recorded in the
    # manifest's sha256 field for skill-link entries) instead of a content
    # hash.
    if [ -L "$dst_file" ]; then
        current_hash="$(readlink "$dst_file" 2>/dev/null || true)"
    else
        current_hash="$(sha256_file "$dst_file")"
    fi

    # Read the recorded source (jq — a fork) here, above the identity
    # ascent, not after it: a "local" entry is skipped no matter what the
    # ascent would say, and moving the jq out of the check -> rm gap keeps
    # the ascent the last thing before rm. The pointer-block branch that
    # also consumes recorded_source stays below the ascent — it must not
    # bypass the .git / outside-target refusals.
    recorded_source="$(jq -r --arg path "$rel_path" '.files[$path].source // ""' <<<"$manifest")"
    if [ "$recorded_source" = "local" ]; then
        log_info "KEPT (local file preserved by --preserve, never repomethod's): ${rel_path}"
        continue
    fi

    # Identity-based containment check, replacing a lexical case that
    # pattern-matched the raw manifest key string. That was bypassable: a
    # key like "./.git/sneaky.txt" doesn't lexically match ".git|.git/*"
    # (it starts with "./") yet still resolves on disk to a file inside
    # .git, and on a case-insensitive filesystem a key like ".GIT/x"
    # doesn't lexically match either yet still resolves to the real .git
    # directory. Comparing device:inode identity (stat_id, from
    # lib/common.sh) instead of path strings answers "does this actually
    # point inside .git / outside target" directly, regardless of how the
    # manifest key is spelled.
    #
    # Why device:inode and not a canonicalized path string: an earlier
    # version of this fix canonicalized via "cd "$dir" && pwd -P" (the
    # idiom lib/target.sh's validate_target uses, minus its ".."-only
    # resolution) on the theory that "pwd -P" forces a physical, kernel-
    # level getcwd() that normalizes a differently-cased lookup (e.g.
    # ".GIT") back to the real on-disk spelling (".git") on case-
    # insensitive-but-case-preserving filesystems such as default macOS
    # APFS. That premise is true in isolation but was empirically found to
    # be UNRELIABLE once embedded in a longer script: whether "pwd -P"
    # returns the normalized or the as-typed case for the same lookup
    # varied between otherwise-identical runs (observed both ways for the
    # exact same "cd .GIT && pwd -P" on this machine, with no relevant
    # change to the script) — almost certainly an APFS/kernel namecache
    # effect on getcwd()'s path *reconstruction*, not a case-folding
    # failure. That non-determinism makes it unfit as the mechanism for a
    # safety-critical check, so it is not used here.
    #
    # The stat identity operation does not reconstruct a path string: the
    # kernel resolves the given path (case-insensitively, following "."
    # and "..") directly to a vnode/inode in a single syscall and reports
    # its identity. Two differently-spelled paths that name the same
    # on-disk entry always report the same device:inode, deterministically,
    # which was verified directly against the "pwd -P" non-determinism
    # above (repeated BSD "stat -f '%d:%i' .git" / "... .GIT" calls agreed
    # every time).
    #
    # dst_file itself is checked first (covers a manifest key that names
    # .git exactly, e.g. a worktree's ".git" gitfile). Then each ancestor
    # directory is checked in turn, ascending by literally appending "/.."
    # and re-stat'ing — never by string-editing the path with dirname —
    # because stat() re-resolves the *entire* path fresh from "/" each
    # time, so any number of ".." segments already present (e.g. from a
    # "../outside-target.txt" key) are always resolved correctly by the
    # kernel; walking up by trimming the string with dirname instead was
    # tried and found to mis-resolve a trailing ".." (it strips the ".."
    # component itself rather than cancelling out the parent it refers to,
    # which silently walked back into target_abs and defeated the
    # traversal check).
    dst_id="$(stat_id "$stat_style" "$dst_file" || true)"

    outside_target=1
    inside_git=0
    if [ -n "$git_id" ] && [ -n "$dst_id" ] && [ "$dst_id" = "$git_id" ]; then
        inside_git=1
    fi

    dir="$(dirname "$dst_file")"
    prev_id=""
    while [ "$inside_git" -eq 0 ]; do
        cur_id="$(stat_id "$stat_style" "$dir" || true)"
        [ -z "$cur_id" ] && break
        if [ -n "$git_id" ] && [ "$cur_id" = "$git_id" ]; then
            inside_git=1
            break
        fi
        if [ "$cur_id" = "$target_id" ]; then
            outside_target=0
            break
        fi
        if [ "$cur_id" = "$prev_id" ]; then
            break
        fi
        prev_id="$cur_id"
        dir="${dir}/.."
    done

    if [ "$inside_git" -eq 1 ]; then
        log_warn "refusing to remove unsafe manifest path (inside .git): ${rel_path}"
        continue
    fi
    if [ "$outside_target" -eq 1 ]; then
        log_warn "refusing to remove unsafe manifest path (outside target): ${rel_path}"
        continue
    fi

    # A pointer-block file (AGENTS.md / CLAUDE.md): strip only RepoMethod's
    # marker block. pointer_remove_block deletes the whole file only if
    # RepoMethod created it from nothing and it is still byte-identical to
    # what was written; otherwise it splices the block out and leaves every
    # other byte, and the file's mode, untouched.
    if [ "$recorded_source" = "pointer-block" ]; then
        pointer_remove_block "$target_abs" "$rel_path" \
            '<!-- repomethod:begin -->' '<!-- repomethod:end -->' "$manifest"
        continue
    fi

    if [ "$current_hash" = "$recorded_hash" ]; then
        rm -f -- "$dst_file"
        removed_dirs+=("$(dirname "$dst_file")")
    else
        log_info "KEPT (locally modified): ${rel_path}"
    fi
done

# Remove now-empty directories, deepest first, excluding target root and .git.
# For each directory a file was removed from, walk upward removing empty
# directories as long as each one is now empty, so a parent directory that
# only becomes empty as a result of removing an emptied child directory
# (e.g. a/b/c/file, where a and a/b hold nothing else) is also cleaned up
# in this same run, not just the immediate parent of each removed file.
if [ "${#removed_dirs[@]}" -gt 0 ]; then
    printf '%s\n' "${removed_dirs[@]}" | sort -ur | while IFS= read -r d; do
        [ -z "$d" ] && continue
        while [ "$d" != "$target_abs" ] && [ -d "$d" ]; do
            # Exact match on .git, or anything under .git/ — NOT a plain
            # prefix match, which would also (wrongly) catch .github and
            # similarly-named siblings that merely start with ".git".
            case "$d" in
                "${target_abs}/.git"|"${target_abs}/.git"/*) break ;;
            esac
            if [ -z "$(ls -A "$d")" ]; then
                rmdir "$d"
                d="$(dirname "$d")"
            else
                break
            fi
        done
    done
fi

if [ "$untrusted_entries" -eq 1 ]; then
    # One or more entries could not be structurally verified and were left on
    # disk. Keep the manifest byte-unchanged so a re-run reproduces the
    # identical CONFLICT(s) and the same exit 1 — do NOT rewrite it to a
    # subset. Trusted entries that were removed leave orphaned manifest
    # entries behind; the existence guard skips them on re-run.
    log_warn "manifest kept (${manifest_path}): one or more entries could not be independently verified — resolve the CONFLICT lines above and re-run"
    log_info "partially uninstalled repomethod from ${target_abs} (unverifiable manifest entries left in place)"
    exit 1
fi

require_repo_path_contained "$target_abs" "$manifest_path"
rm -f -- "$manifest_path"

log_info "uninstalled repomethod from ${target_abs}"
