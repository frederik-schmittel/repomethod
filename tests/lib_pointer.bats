setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    source "${REPO_ROOT}/lib/pointer.sh"
    register_cleanup_trap
    WORK="$(mktemp -d)"
    BEGIN='<!-- repomethod:begin -->'
    END='<!-- repomethod:end -->'
    BLOCK='Follow the repository engineering contract in `.repomethod/AGENTS.md`.'
    HEADER='# Agent Instructions'
}

teardown() {
    rm -rf -- "$WORK"
}

_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

@test "pointer_stage creates the file with header + block when it doesn't exist" {
    manifest="$(manifest_init "0.0.1" "core")"
    manifest="$(pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest")"
    [ -f "${WORK}/AGENTS.md" ]
    run grep -F "$HEADER" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "$BLOCK" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
    echo "$manifest" | jq -e '.files["AGENTS.md"].source == "pointer-block"'
    stored_hash="$(echo "$manifest" | jq -r '.files["AGENTS.md"].created_whole_file_sha256')"
    [ "$stored_hash" = "$(sha256_file "${WORK}/AGENTS.md")" ]
}

@test "pointer_stage appends the block, preserving the exact pre-existing bytes as a verbatim prefix" {
    printf '# My Project\n\nSome existing rules the user wrote.\n\n\n' > "${WORK}/AGENTS.md"
    cp "${WORK}/AGENTS.md" "${WORK}/prefix.expected"
    before_bytes="$(wc -c < "${WORK}/AGENTS.md")"
    manifest="$(manifest_init "0.0.1" "core")"
    manifest="$(pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest")"
    after_bytes="$(wc -c < "${WORK}/AGENTS.md")"
    [ "$after_bytes" -gt "$before_bytes" ]
    head -c "$before_bytes" "${WORK}/AGENTS.md" > "${WORK}/prefix.actual"
    diff "${WORK}/prefix.expected" "${WORK}/prefix.actual"
}

@test "pointer_stage replacing the block preserves everything before and after it byte-for-byte, even with no final newline" {
    printf 'BEFORE line one\nBEFORE line two\n%s\nold block text\n%s\nAFTER line one\nAFTER line two' \
        "$BEGIN" "$END" > "${WORK}/AGENTS.md"   # deliberately no trailing newline on the last line
    old_hash="$(sha256_string 'old block text')"
    prior="$(manifest_init "0.0.1" "core")"
    prior="$(manifest_add_file "$prior" "AGENTS.md" "$old_hash" "pointer-block")"
    pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "$prior" "$prior" >/dev/null
    printf 'BEFORE line one\nBEFORE line two\n' > "${WORK}/before.expected"
    head -n 2 "${WORK}/AGENTS.md" > "${WORK}/before.actual"
    diff "${WORK}/before.expected" "${WORK}/before.actual"
    printf 'AFTER line one\nAFTER line two' > "${WORK}/after.expected"
    tail -c 29 "${WORK}/AGENTS.md" > "${WORK}/after.actual"   # 29 = byte length of the two AFTER lines, no trailing newline
    diff "${WORK}/after.expected" "${WORK}/after.actual"
}

@test "pointer_stage preserves the pre-existing file's permission mode" {
    printf '%s\nold\n%s\n' "$BEGIN" "$END" > "${WORK}/AGENTS.md"
    chmod 640 "${WORK}/AGENTS.md"
    old_hash="$(sha256_string 'old')"
    prior="$(manifest_init "0.0.1" "core")"
    prior="$(manifest_add_file "$prior" "AGENTS.md" "$old_hash" "pointer-block")"
    pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "$prior" "$prior" >/dev/null
    [ "$(_mode "${WORK}/AGENTS.md")" = "640" ]
}

@test "pointer_stage refuses to overwrite a block the manifest never recorded as ours" {
    printf '%s\nsomeone else wrote this\n%s\n' "$BEGIN" "$END" > "${WORK}/AGENTS.md"
    manifest="$(manifest_init "0.0.1" "core")"
    run pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    run grep -F "someone else wrote this" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "pointer_stage refuses a file with two marker pairs rather than guessing which one is ours" {
    printf '%s\nblock one\n%s\n\nunrelated middle content\n\n%s\nblock two\n%s\n' \
        "$BEGIN" "$END" "$BEGIN" "$END" > "${WORK}/AGENTS.md"
    one_hash="$(sha256_string 'block one')"
    prior="$(manifest_init "0.0.1" "core")"
    prior="$(manifest_add_file "$prior" "AGENTS.md" "$one_hash" "pointer-block")"
    run pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "$prior" "$prior"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    run grep -F "block one" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "block two" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "pointer_stage refuses a file with a malformed marker pair (end before begin)" {
    printf '%s\nstray content\n%s\n' "$END" "$BEGIN" > "${WORK}/AGENTS.md"
    manifest="$(manifest_init "0.0.1" "core")"
    run pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
}

@test "pointer_stage refuses to write through a pre-planted symlink at a predictable temp-file path" {
    printf '%s\nold\n%s\n' "$BEGIN" "$END" > "${WORK}/AGENTS.md"
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${WORK}/AGENTS.md.repomethod.tmp"
    old_hash="$(sha256_string 'old')"
    prior="$(manifest_init "0.0.1" "core")"
    prior="$(manifest_add_file "$prior" "AGENTS.md" "$old_hash" "pointer-block")"
    run pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "$prior" "$prior"
    [ -z "$(ls -A "$OUTSIDE")" ]
    rm -rf -- "$OUTSIDE"
}

@test "pointer_remove_block deletes a self-created file that is still exactly what repomethod wrote" {
    manifest="$(manifest_init "0.0.1" "core")"
    manifest="$(pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest")"
    pointer_remove_block "$WORK" "AGENTS.md" "$BEGIN" "$END" "$manifest"
    [ ! -e "${WORK}/AGENTS.md" ]
}

@test "pointer_remove_block keeps a self-created file the user has since added content to" {
    manifest="$(manifest_init "0.0.1" "core")"
    manifest="$(pointer_stage "$WORK" "AGENTS.md" "$HEADER" "$BLOCK" "$BEGIN" "$END" "" "$manifest")"
    printf '\n## My own added section\n' >> "${WORK}/AGENTS.md"
    pointer_remove_block "$WORK" "AGENTS.md" "$BEGIN" "$END" "$manifest"
    [ -f "${WORK}/AGENTS.md" ]
    run grep -F "My own added section" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "$BLOCK" "${WORK}/AGENTS.md"
    [ "$status" -ne 0 ]
}

@test "pointer_remove_block strips only the marked block, preserving surrounding bytes and mode exactly" {
    printf 'BEFORE\n%s\n%s\n%s\nAFTER' "$BEGIN" "$BLOCK" "$END" > "${WORK}/AGENTS.md"  # no final newline
    chmod 640 "${WORK}/AGENTS.md"
    hash="$(sha256_string "$BLOCK")"
    manifest="$(manifest_init "0.0.1" "core")"
    manifest="$(manifest_add_file "$manifest" "AGENTS.md" "$hash" "pointer-block")"
    pointer_remove_block "$WORK" "AGENTS.md" "$BEGIN" "$END" "$manifest"
    printf 'BEFORE\nAFTER' > "${WORK}/expected"
    diff "${WORK}/expected" "${WORK}/AGENTS.md"
    [ "$(_mode "${WORK}/AGENTS.md")" = "640" ]
}

@test "pointer_remove_block leaves an untouched file alone when markers are absent" {
    printf 'no markers here\n' > "${WORK}/AGENTS.md"
    manifest="$(manifest_init "0.0.1" "core")"
    pointer_remove_block "$WORK" "AGENTS.md" "$BEGIN" "$END" "$manifest"
    run grep -F "no markers here" "${WORK}/AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "preflight_pointer_block is read-only and passes silently when there is nothing to check" {
    run preflight_pointer_block "$WORK" "AGENTS.md" "$BEGIN" "$END" ""
    [ "$status" -eq 0 ]
    [ ! -e "${WORK}/AGENTS.md" ]
}

@test "preflight_pointer_block refuses a malformed marker file without writing anything" {
    printf '%s\nstray content\n%s\n' "$END" "$BEGIN" > "${WORK}/AGENTS.md"
    before_hash="$(sha256_file "${WORK}/AGENTS.md")"
    run preflight_pointer_block "$WORK" "AGENTS.md" "$BEGIN" "$END" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ "$(sha256_file "${WORK}/AGENTS.md")" = "$before_hash" ]
}
