#!/usr/bin/env bash
# update.sh — refresh unmodified managed files from this checkout (or an
# explicit local --source directory), preserving local modifications.
# v0.1 deliberately has no release-download path; see README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${HERE}/lib/common.sh"
# shellcheck source=lib/target.sh disable=SC1091
source "${HERE}/lib/target.sh"
# shellcheck source=lib/manifest.sh disable=SC1091
source "${HERE}/lib/manifest.sh"
# shellcheck source=lib/blueprint.sh disable=SC1091
source "${HERE}/lib/blueprint.sh"
# shellcheck source=lib/skills.sh disable=SC1091
source "${HERE}/lib/skills.sh"
# shellcheck source=lib/pointer.sh disable=SC1091
source "${HERE}/lib/pointer.sh"

require_cmd jq

register_cleanup_trap

target=""
source_dir=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) target="$2"; shift 2 ;;
        --source) source_dir="$2"; shift 2 ;;
        # Accepted as a compatibility no-op: update is always network-free
        # now that there is nothing left to fetch.
        --offline) shift ;;
        *) die "unknown flag: $1" ;;
    esac
done

[ -z "$target" ] && die "--target is required"
[ -z "$source_dir" ] && source_dir="$(blueprint_source_dir)"

# Validated before anything is read, migrated, or written. update.sh
# rewrites the manifest from the source file list at line ~139, before the
# per-file loop even starts, so a source that enumerates to nothing does not
# fail — it succeeds with a manifest that has lost every blueprint entry.
# The three probes below are exactly the files this script already reads
# unconditionally further down; requiring them here only states that
# precondition where it can still be refused cheaply.
[ -d "$source_dir" ] || die "--source is not a directory: ${source_dir}"
for required in "AGENTS.md" "CLAUDE.md" ".repomethod/scripts/agent-gate.sh"; do
    [ -f "${source_dir}/${required}" ] \
        || die "--source is not a blueprint directory (missing ${required}): ${source_dir}"
done

target_abs="$(validate_target "$target")"
manifest_path="${target_abs}/.repomethod/manifest.json"

# Checked before the very first read/write of the manifest: everything
# below — including the manifest_write a few lines down, which runs before
# the per-file loop's own containment checks even start — would otherwise
# silently read or write through a .repomethod replaced by a symlink
# pointing outside target_abs.
require_repo_path_contained "$target_abs" "$manifest_path"

# Every manifest write re-verifies containment immediately before it: jq and
# sha256_file fork between the top-of-loop check and here, and a concurrent
# writer can swap an already-checked ancestor for a symlink in that window.
# This narrows the window to bash builtins; it does not close it.
# manifest_write self-guards too since the propagate-find-errors fix wave —
# this wrapper is now belt-and-suspenders.
manifest_write_checked() {
    require_repo_path_contained "$target_abs" "$manifest_path"
    manifest_write "$@"
}

old_manifest="$(manifest_read "$manifest_path")"

# Run version-scoped migrations from this checkout's migrations/ directory
# before touching any managed file. A migration for version X runs when the
# installed manifest's version is below X and this checkout's VERSION is at
# or above X. Migrations own .repomethod/** state only; a non-zero exit
# aborts the update before the manifest is rewritten.
run_update_migrations() {
    local from="$1" to="$2" tgt="$3" mig ver lower
    # RM_MIGRATIONS_DIR overrides the location only for the test suite.
    local dir="${RM_MIGRATIONS_DIR:-${HERE}/migrations}"
    [ -d "$dir" ] || return 0
    for mig in "$dir"/*.sh; do
        [ -e "$mig" ] || continue
        ver="$(basename "$mig" .sh)"
        ver="${ver%%-*}"
        lower="$(printf '%s\n%s\n' "$from" "$ver" | sort -V | head -n1)"
        [ "$lower" = "$from" ] && [ "$from" != "$ver" ] || continue
        [ "$(printf '%s\n%s\n' "$ver" "$to" | sort -V | head -n1)" = "$ver" ] || continue
        log_info "running migration ${ver}: $(basename "$mig")"
        bash "$mig" "$tgt" || die "migration failed: $(basename "$mig")"
    done
}

# Any manifest recording a profile other than "core" predates this release
# (only "core" can ever be installed now — see install.sh). Refusing outright
# is deliberate: silently dropping the old profile's vendored content would
# be a migration, and the simpler, safer contract is "uninstall cleanly with
# this repository's own uninstall.sh (it doesn't care about profiles, only
# manifest file entries), then install fresh".
if ! jq -e '.profiles == ["core"]' <<<"$old_manifest" >/dev/null; then
    die "this installation contains legacy external profiles, which are no
longer supported. Run this repository's uninstall.sh, then install the
current core release."
fi
profiles_csv="core"

stat_style="$(detect_stat_style "$target_abs")"
target_id="$(stat_id "$stat_style" "$target_abs")"
git_id=""
[ -e "${target_abs}/.git" ] && git_id="$(stat_id "$stat_style" "${target_abs}/.git")"

version="$(cat "${HERE}/VERSION")"

old_version="$(jq -r '.version // "unknown"' <<<"$old_manifest")"
if [ "$old_version" != "$version" ]; then
    log_info "blueprint ${old_version} -> ${version}; review CHANGELOG.md for behavior changes and notes on locally forked scripts"
fi
run_update_migrations "$old_version" "$version" "$target_abs"

# Snapshot the source file list up front (rather than streaming it once
# through the loop below) so it's available both to seed the manifest
# before any file is touched and, after the loop, to detect files that
# were tracked before but no longer exist upstream.
files=()
files_raw="$(blueprint_list_files "$source_dir")" \
    || die "cannot enumerate the blueprint source: ${source_dir}"
[ -n "$files_raw" ] && mapfile -t files <<< "$files_raw"

files_json='[]'
if [ "${#files[@]}" -gt 0 ]; then
    files_json="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
fi

# Seed the new manifest from the old one, keeping only entries for files
# that still exist in the new source tree (files no longer present are
# dropped here — see the orphan-logging loop below). Seeding from the old
# manifest — rather than starting from an empty {} like manifest_init —
# means that if the loop below dies partway through (e.g. a `cp` fails on
# some later file), every file the loop hasn't reached yet still keeps its
# correct, unchanged recorded hash in manifest.json instead of losing its
# entry entirely. Combined with writing the manifest after every
# successfully processed file (below), this guarantees manifest.json is
# always an accurate reflection of on-disk reality, even mid-failure.
new_manifest="$(jq -n \
    --arg version "$version" \
    --arg profiles_csv "$profiles_csv" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson old "$old_manifest" \
    --argjson files "$files_json" \
    '{
        version: $version,
        installed_at: $installed_at,
        profiles: ($profiles_csv | split(",")),
        files: ($old.files | with_entries(select(.key as $k | $files | index($k) != null)))
    }')"
manifest_write_checked "$new_manifest" "$manifest_path"

# Seed the trusted blueprint inventory once (forks one `find`). It is the
# INSTALLED PACKAGE's blueprint (blueprint_source_dir, not --source), so a
# path only a custom --source ships is still "not in this version" and a
# forged "blueprint" entry for it is rejected -> kept as local, never
# overwritten.
manifest_trust_init

for rel_path in "${files[@]}"; do
    # AGENTS.md / CLAUDE.md are pointer-block files, refreshed after this
    # loop by pointer_stage — never copied or diffed as plain managed files.
    blueprint_is_pointer_file "$rel_path" && continue

    dst_file="${target_abs}/${rel_path}"
    require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"

    # A file kept via --preserve at install time was never repomethod's
    # content (see lib/blueprint.sh's merge branch) — it must never be
    # refreshed from upstream, only have its recorded hash kept in sync in
    # case the user has since edited it further, or dropped if the user
    # deleted it.
    recorded_source="$(jq -r --arg path "$rel_path" '.files[$path].source // ""' <<<"$old_manifest")"
    # The old manifest is attacker-writable state. An entry whose recorded
    # source does not structurally validate is treated exactly as if it had
    # no record at all — routed into the "pre-existing local file" branch
    # below: kept on disk, recorded "local", never overwritten from upstream.
    if ! untrusted_reason="$(manifest_entry_trusted "$old_manifest" "$rel_path" "$target_abs" 2>&1)"; then
        recorded_source=""
        untrusted_entry=1
    else
        untrusted_entry=0
    fi
    if [ "$recorded_source" = "local" ]; then
        if [ -e "$dst_file" ]; then
            current_hash="$(sha256_file "$dst_file")"
            new_manifest="$(manifest_add_file "$new_manifest" "$rel_path" "$current_hash" "local")"
        else
            new_manifest="$(manifest_remove_file "$new_manifest" "$rel_path")"
        fi
        manifest_write_checked "$new_manifest" "$manifest_path"
        continue
    fi

    src_file="$(blueprint_source_file "$source_dir" "$rel_path")"
    src_hash="$(sha256_file "$src_file")"

    if [ ! -e "$dst_file" ]; then
        # untrusted_entry is deliberately NOT consulted on this create path:
        # an absent file with an untrusted recorded source is installed fresh
        # as "blueprint", identical to a genuinely unrecorded absent file —
        # the untrusted record buys it nothing either way.
        # KNOWN LIMITATION: a missing file here is ambiguous — it could be a file the user
        # never had before (new upstream file, correct to install) or a
        # managed file the user deliberately deleted (this silently
        # reinstalls it, which the user did not want). The manifest only
        # tracks hashes of currently-installed files, not a "deleted"
        # tombstone, so the two cases are indistinguishable. Decision:
        # preserve the existing behavior; a tombstone flag would require a
        # manifest schema change and a separate migration design.
        # Re-checked here, not only at the top of the loop: sha256_file and
        # blueprint_source_file fork between the two points, so a concurrent
        # writer could swap an already-checked ancestor for a symlink into
        # .git in that window. Narrows it to bash builtins; does not close it.
        require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
        mkdir -p "$(dirname "$dst_file")"
        require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
        cp "$src_file" "$dst_file"
        new_manifest="$(manifest_add_file "$new_manifest" "$rel_path" "$src_hash" "blueprint")"
        # Persist after every successful disk write (not just once at the
        # end of the loop): if a later file's cp fails under set -e, the
        # script dies mid-loop, but manifest.json must already reflect
        # every file that was actually refreshed on disk so far. Writing
        # once at the end would let an earlier successful refresh be
        # recorded under its OLD hash, permanently misclassifying that
        # file as "locally modified" on the next run.
        manifest_write_checked "$new_manifest" "$manifest_path"
        continue
    fi

    recorded_hash="$(manifest_file_hash "$old_manifest" "$rel_path")"
    current_hash="$(sha256_file "$dst_file")"

    if [ -z "$recorded_hash" ] || [ "${untrusted_entry:-0}" -eq 1 ]; then
        # This path exists on disk but was never in the old manifest — a
        # pre-existing local file the new source now happens to also ship
        # a path for. It was never repomethod's, so adopting it as
        # "blueprint" here (the fallback below) would silently discard its
        # real content the very first time this path appears upstream.
        # Record it as "local" instead, exactly like a --preserve-kept file:
        # never overwritten or deleted by a future update/uninstall.
        # An entry whose recorded source failed manifest_entry_trusted lands
        # here too (untrusted_entry=1, recorded_source blanked): the
        # untrusted record buys it nothing — same keep-as-local outcome.
        if [ "${untrusted_entry:-0}" -eq 1 ]; then
            log_info "CONFLICT (manifest source not independently verifiable, kept as local): ${rel_path} — ${untrusted_reason##*: }"
        else
            log_info "KEPT (pre-existing local file, never repomethod's): ${rel_path}"
        fi
        new_manifest="$(manifest_add_file "$new_manifest" "$rel_path" "$current_hash" "local")"
        manifest_write_checked "$new_manifest" "$manifest_path"
        continue
    fi

    if [ "$recorded_hash" != "$current_hash" ]; then
        # A managed file that has diverged from upstream is now a deliberate
        # local fork: keep it, and record it as "local" (with its own hash)
        # exactly like a --preserve-kept or pre-existing local file. From
        # here on the "local" branch above owns it — future updates never
        # overwrite it and `doctor` stops reporting it as drift. What
        # changed upstream is the CHANGELOG's job to surface, not a
        # perpetual per-run conflict line.
        log_info "CONFLICT (diverged from upstream, kept as a local fork): ${rel_path}"
        new_manifest="$(manifest_add_file "$new_manifest" "$rel_path" "$current_hash" "local")"
        manifest_write_checked "$new_manifest" "$manifest_path"
        continue
    fi

    # Re-checked immediately before the refresh cp: sha256_file forked twice
    # (src and dst) since the top-of-loop check.
    require_path_contained "$stat_style" "$target_id" "$git_id" "$dst_file"
    cp "$src_file" "$dst_file"
    new_manifest="$(manifest_add_file "$new_manifest" "$rel_path" "$src_hash" "blueprint")"
    manifest_write_checked "$new_manifest" "$manifest_path"
done

new_manifest="$(stage_core_skills "$target_abs" "$new_manifest" "$old_manifest")"

# Refresh the AGENTS.md / CLAUDE.md pointer blocks last. No standalone
# preflight here (unlike install.sh): update's per-file loop above is
# already incremental and self-healing, so a pointer-block conflict
# discovered now leaves every file it already refreshed correctly updated
# rather than half-done — the same install-only scoping preflight_skill_links
# uses. pointer_stage still runs its own internal ownership check.
# shellcheck disable=SC2016  # backticks below are literal markdown, not command substitution
new_manifest="$(pointer_stage "$target_abs" "AGENTS.md" \
    "$(cat "${source_dir}/AGENTS.md")" \
    'Follow the repository engineering contract in `.repomethod/AGENTS.md`.' \
    '<!-- repomethod:begin -->' '<!-- repomethod:end -->' \
    "$old_manifest" "$new_manifest")"
# shellcheck disable=SC2016
new_manifest="$(pointer_stage "$target_abs" "CLAUDE.md" \
    "$(cat "${source_dir}/CLAUDE.md")" \
    'Claude Code follows the repository engineering contract in `.repomethod/AGENTS.md`.' \
    '<!-- repomethod:begin -->' '<!-- repomethod:end -->' \
    "$old_manifest" "$new_manifest")"

manifest_write_checked "$new_manifest" "$manifest_path"

# Files present in the old manifest but absent from the new source tree
# were removed upstream. They were already dropped from new_manifest by
# the seeding step above; note that explicitly rather than leaving no
# trace of why they're no longer tracked. Skill-link and generated-doc
# entries are excluded here — they are re-derived (not sourced from
# blueprint_list_files) by stage_core_skills above, so flagging them as
# "no longer tracked upstream" would be a false warning about paths that
# were just correctly re-staged. A retired "skill-link-copy" entry gets no
# such exclusion: stage_core_skills no longer gives it any special
# handling, so if it still lingers here (the skill it belonged to was
# retired upstream before this update could ever reach and refuse it),
# this is a true, not false, "no longer tracked upstream" warning.
while IFS= read -r rel_path; do
    [ -z "$rel_path" ] && continue
    log_info "no longer tracked upstream, left on disk as-is: ${rel_path}"
done < <(jq -r --argjson files "$files_json" \
    '.files | to_entries[] | . as $entry |
     select(($entry.value.source | . == "skill-link" or . == "generated") | not) |
     select(($files | index($entry.key)) == null) | $entry.key' \
    <<<"$old_manifest")

log_info "updated repomethod to ${version} in ${target_abs}"
