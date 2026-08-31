#!/usr/bin/env bash
# lib/pointer.sh — the one deliberately-supported merge mechanism: a marker-
# delimited block inserted into a host-owned file (AGENTS.md, CLAUDE.md).
# RepoMethod never owns or intentionally modifies content outside its marker
# block. This is not a general file merger — it exists for exactly the two
# callers wired up in install.sh/update.sh/uninstall.sh.
#
# Regions outside the block are always copied with head/tail (raw byte
# ranges), never reconstructed by printing awk records — awk's print adds
# its own output record separator, which silently gives a file a trailing
# newline it never had, and can mis-handle non-"\n"-only line endings.
# head/tail return exactly the bytes that were already there.
set -euo pipefail

pointer_block_owned() {
    local prior_manifest_json="$1" rel_path="$2" current_hash="$3"
    [ -n "$prior_manifest_json" ] || return 1
    local prior_source prior_hash
    prior_source="$(jq -r --arg path "$rel_path" '.files[$path].source // ""' <<<"$prior_manifest_json")"
    prior_hash="$(jq -r --arg path "$rel_path" '.files[$path].sha256 // ""' <<<"$prior_manifest_json")"
    [ "$prior_source" = "pointer-block" ] && [ "$prior_hash" = "$current_hash" ]
}

# "absent" (no begin marker), "present" (exactly one well-formed pair), or
# "malformed" (anything else). Callers refuse on "malformed" rather than
# guess which occurrence is the real one. Read-only.
pointer_marker_state() {
    local file_path="$1" begin_marker="$2" end_marker="$3"
    [ -f "$file_path" ] || { printf 'absent'; return 0; }
    awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { begins++; if (begins > open+1) { bad=1 }; open++; next }
        $0 == e { if (open == 0) { bad=1 }; open--; ends++; next }
        END {
            if (bad || open != 0 || begins > 1 || ends > 1) { print "malformed"; exit }
            if (begins == 0 && ends == 0) { print "absent"; exit }
            print "present"
        }
    ' "$file_path"
}

# Prints "<begin_line> <end_line>" for the single well-formed pair. Only
# call after pointer_marker_state returned "present". Read-only.
_pointer_marker_lines() {
    local file_path="$1" begin_marker="$2" end_marker="$3"
    local begin_line end_line
    begin_line="$(grep -nFx -- "$begin_marker" "$file_path" | head -1 | cut -d: -f1)"
    end_line="$(grep -nFx -- "$end_marker" "$file_path" | head -1 | cut -d: -f1)"
    # Trailing newline is required: `read -r a b < <(...)` on newline-less
    # input returns 1 (EOF mid-read), which aborts the caller under
    # `set -e` + inherit_errexit even though a and b were populated fine.
    printf '%s %s\n' "$begin_line" "$end_line"
}

# The text strictly between the marker lines, via head/tail (byte-exact),
# not awk print. Only call after pointer_marker_state returned "present".
pointer_extract_block() {
    local file_path="$1" begin_marker="$2" end_marker="$3"
    local begin_line end_line
    read -r begin_line end_line < <(_pointer_marker_lines "$file_path" "$begin_marker" "$end_marker")
    if [ "$((end_line - begin_line))" -gt 1 ]; then
        head -n "$((end_line - 1))" "$file_path" | tail -n "+$((begin_line + 1))"
    fi
}

_pointer_file_mode() {
    local path="$1"
    stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null
}

# Fresh, unpredictable temp file inside dirname(file_path) — a fixed suffix
# would let a pre-planted symlink redirect the write. If file_path already
# exists, the temp file's mode is set to match it before the caller writes
# anything (mktemp defaults to 0600, which would otherwise silently
# downgrade an existing file's permissions on the later mv).
_pointer_new_tmp() {
    local file_path="$1"
    local tmp_file
    # ${file_path%/*} is dirname for every path this is called with (all
    # contain a "/") — a builtin, so pointer_remove_block's containment
    # recheck is not separated from this mktemp by a dirname fork.
    tmp_file="$(mktemp "${file_path%/*}/.repomethod.tmp.XXXXXX")"
    if [ -e "$file_path" ]; then
        local mode
        mode="$(_pointer_file_mode "$file_path")"
        [ -n "$mode" ] && chmod "$mode" "$tmp_file"
    fi
    printf '%s' "$tmp_file"
}

# Read-only. Dies exactly like pointer_stage would refuse, without writing
# anything — lets install.sh check this before stage_blueprint writes any
# other file, mirroring preflight_skill_links. Also called internally by
# pointer_stage itself, so the two never drift out of sync.
preflight_pointer_block() {
    local target_dir="$1" rel_path="$2" begin_marker="$3" end_marker="$4"
    local prior_manifest_json="$5"
    local file_path="${target_dir}/${rel_path}"

    require_repo_path_contained "$target_dir" "$file_path"
    [ -e "$file_path" ] || return 0

    local state
    state="$(pointer_marker_state "$file_path" "$begin_marker" "$end_marker")"
    case "$state" in
        malformed)
            die "conflict: ${rel_path} has more than one, or a malformed, repomethod marker block — resolve it manually"
            ;;
        present)
            local existing_block current_hash
            existing_block="$(pointer_extract_block "$file_path" "$begin_marker" "$end_marker")"
            current_hash="$(sha256_string "$existing_block")"
            pointer_block_owned "$prior_manifest_json" "$rel_path" "$current_hash" || \
                die "conflict: ${rel_path} already has a repomethod block that was not created by repomethod — remove it manually"
            ;;
    esac
}

# Prints the updated manifest_json on stdout. header_text (may be "") is
# only used when creating file_path from nothing.
pointer_stage() {
    local target_dir="$1" rel_path="$2" header_text="$3" block_content="$4"
    local begin_marker="$5" end_marker="$6"
    local prior_manifest_json="$7" manifest_json="$8"
    local file_path="${target_dir}/${rel_path}"

    preflight_pointer_block "$target_dir" "$rel_path" "$begin_marker" "$end_marker" "$prior_manifest_json"

    local new_hash tmp_file
    new_hash="$(sha256_string "$block_content")"

    if [ ! -e "$file_path" ]; then
        mkdir -p "$(dirname "$file_path")"
        tmp_file="$(_pointer_new_tmp "$file_path")"
        {
            [ -n "$header_text" ] && printf '%s\n\n' "$header_text"
            printf '%s\n%s\n%s\n' "$begin_marker" "$block_content" "$end_marker"
        } > "$tmp_file"
        chmod 644 "$tmp_file"
        mv "$tmp_file" "$file_path"
        local whole_hash
        whole_hash="$(sha256_file "$file_path")"
        printf '%s' "$(manifest_add_file "$manifest_json" "$rel_path" "$new_hash" "pointer-block" \
            "$(jq -n --arg h "$whole_hash" '{created_whole_file_sha256: $h}')")"
        return 0
    fi

    local state
    state="$(pointer_marker_state "$file_path" "$begin_marker" "$end_marker")"

    case "$state" in
        absent)
            tmp_file="$(_pointer_new_tmp "$file_path")"
            {
                cat "$file_path"
                printf '\n%s\n%s\n%s\n' "$begin_marker" "$block_content" "$end_marker"
            } > "$tmp_file"
            mv "$tmp_file" "$file_path"
            printf '%s' "$(manifest_add_file "$manifest_json" "$rel_path" "$new_hash" "pointer-block")"
            ;;
        present)
            # preflight_pointer_block above already proved ownership; splice
            # the new block in by line number, copying the untouched
            # regions on either side verbatim via head/tail.
            local begin_line end_line
            read -r begin_line end_line < <(_pointer_marker_lines "$file_path" "$begin_marker" "$end_marker")
            tmp_file="$(_pointer_new_tmp "$file_path")"
            {
                [ "$begin_line" -gt 1 ] && head -n "$((begin_line - 1))" "$file_path"
                printf '%s\n%s\n%s\n' "$begin_marker" "$block_content" "$end_marker"
                tail -n "+$((end_line + 1))" "$file_path"
            } > "$tmp_file"
            mv "$tmp_file" "$file_path"
            # Carry created_whole_file_sha256 forward, but only while the
            # re-spliced file is still byte-identical to what pointer_stage
            # first created — so uninstall keeps cleanly deleting a
            # RepoMethod-created AGENTS.md/CLAUDE.md across routine (no-op)
            # updates, and correctly stops the moment the user adds content
            # of their own or the block text itself changes.
            local prior_created present_extra='{}'
            prior_created="$(jq -r --arg p "$rel_path" '.files[$p].created_whole_file_sha256 // ""' <<<"$prior_manifest_json")"
            if [ -n "$prior_created" ] && [ "$(sha256_file "$file_path")" = "$prior_created" ]; then
                present_extra="$(jq -n --arg h "$prior_created" '{created_whole_file_sha256: $h}')"
            fi
            printf '%s' "$(manifest_add_file "$manifest_json" "$rel_path" "$new_hash" "pointer-block" "$present_extra")"
            ;;
    esac
}

# Deletes the whole file if RepoMethod created it from nothing and it is
# still byte-identical to what was created; otherwise splices out only the
# marker-delimited block via head/tail, preserving everything else and the
# file's mode exactly. A malformed/absent marker state, or a block the
# manifest can't prove ownership of, is a no-op.
pointer_remove_block() {
    local target_dir="$1" rel_path="$2" begin_marker="$3" end_marker="$4"
    local prior_manifest_json="$5"
    local file_path="${target_dir}/${rel_path}"

    require_repo_path_contained "$target_dir" "$file_path"
    [ -f "$file_path" ] || return 0

    local state
    state="$(pointer_marker_state "$file_path" "$begin_marker" "$end_marker")"
    [ "$state" = "present" ] || return 0

    local existing_block current_hash
    existing_block="$(pointer_extract_block "$file_path" "$begin_marker" "$end_marker")"
    current_hash="$(sha256_string "$existing_block")"
    pointer_block_owned "$prior_manifest_json" "$rel_path" "$current_hash" || return 0

    local created_whole_hash
    created_whole_hash="$(jq -r --arg path "$rel_path" '.files[$path].created_whole_file_sha256 // ""' <<<"$prior_manifest_json")"
    if [ -n "$created_whole_hash" ] && [ "$(sha256_file "$file_path")" = "$created_whole_hash" ]; then
        # Re-checked immediately before each sink: the top-of-function check
        # is separated from here by pointer_marker_state / pointer_extract_block
        # / sha256_string / sha256_file, every one of which forks. A
        # concurrent writer can swap an already-checked ancestor for a
        # symlink into .git in that window. This narrows it to bash
        # builtins; it does not close it.
        require_repo_path_contained "$target_dir" "$file_path"
        rm -f -- "$file_path"
        return 0
    fi

    local begin_line end_line tmp_file
    read -r begin_line end_line < <(_pointer_marker_lines "$file_path" "$begin_marker" "$end_marker")
    require_repo_path_contained "$target_dir" "$file_path"
    tmp_file="$(_pointer_new_tmp "$file_path")"
    {
        [ "$begin_line" -gt 1 ] && head -n "$((begin_line - 1))" "$file_path"
        tail -n "+$((end_line + 1))" "$file_path"
    } > "$tmp_file"
    require_repo_path_contained "$target_dir" "$file_path"
    mv "$tmp_file" "$file_path"
}
