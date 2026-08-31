setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/blueprint.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    WORK="$(mktemp -d)"
    # Task 10B: seed the trusted inventory from the package's own blueprint
    # (blueprint_source_dir -> ${REPO_ROOT}/blueprint) once per test, so the
    # "blueprint" branch of manifest_entry_trusted has a real inventory to
    # cross-check against.
    manifest_trust_init
}

teardown() {
    rm -rf -- "$WORK"
}

@test "sha256_file computes a stable digest" {
    printf 'hello\n' > "${WORK}/f.txt"
    run sha256_file "${WORK}/f.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]]
}

@test "manifest_init produces valid empty manifest JSON" {
    run manifest_init "0.1.0" "core,web"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.version == "0.1.0"'
    echo "$output" | jq -e '.profiles == ["core","web"]'
    echo "$output" | jq -e '.files == {}'
}

@test "manifest_add_file adds an entry" {
    m="$(manifest_init "0.1.0" "core")"
    m="$(manifest_add_file "$m" "AGENTS.md" "abc123" "blueprint")"
    echo "$m" | jq -e '.files["AGENTS.md"].sha256 == "abc123"'
    echo "$m" | jq -e '.files["AGENTS.md"].source == "blueprint"'
}

@test "sha256_string hashes the exact bytes with no trailing newline" {
    printf 'hello world' > "${WORK}/f"
    [ "$(sha256_string 'hello world')" = "$(sha256_file "${WORK}/f")" ]
}

@test "sha256_string of the empty string is the empty-input digest" {
    printf '' > "${WORK}/e"
    [ "$(sha256_string '')" = "$(sha256_file "${WORK}/e")" ]
}

@test "manifest_add_file merges optional extra_json into the entry" {
    m="$(manifest_init "0.1.0" "core")"
    m="$(manifest_add_file "$m" "AGENTS.md" "abc" "pointer-block" '{"created_whole_file_sha256":"deadbeef"}')"
    echo "$m" | jq -e '.files["AGENTS.md"].sha256 == "abc"'
    echo "$m" | jq -e '.files["AGENTS.md"].source == "pointer-block"'
    echo "$m" | jq -e '.files["AGENTS.md"].created_whole_file_sha256 == "deadbeef"'
}

@test "manifest_add_file without extra_json records exactly sha256 and source" {
    m="$(manifest_init "0.1.0" "core")"
    m="$(manifest_add_file "$m" "AGENTS.md" "abc" "blueprint")"
    echo "$m" | jq -e '.files["AGENTS.md"] | keys == ["sha256","source"]'
}

@test "manifest_write then manifest_read round-trips" {
    m="$(manifest_init "0.1.0" "core")"
    manifest_write "$m" "${WORK}/.repomethod/manifest.json"
    [ -f "${WORK}/.repomethod/manifest.json" ]
    run manifest_read "${WORK}/.repomethod/manifest.json"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.version == "0.1.0"'
}

@test "manifest_write refuses to write when .repomethod is swapped to a symlink outside the repo" {
    W="$(mktemp -d)"
    git -C "$W" init -q
    ext="$(mktemp -d)"
    ln -s "$ext" "${W}/.repomethod"
    m="$(manifest_init "0.1.0" "core")"

    run manifest_write "$m" "${W}/.repomethod/manifest.json"

    [ "$status" -ne 0 ]
    [ ! -e "${ext}/manifest.json" ]

    rm -rf -- "$W" "$ext"
}

@test "manifest_read dies on missing file" {
    run manifest_read "${WORK}/nope.json"
    [ "$status" -eq 1 ]
}

@test "manifest_read dies on a top-level shape violation (.files is an array)" {
    printf '%s\n' '{"version":"0.0.1","files":[]}' > "${WORK}/m.json"
    run manifest_read "${WORK}/m.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"top-level"* ]] || [[ "$output" == *"malformed"* ]]
}

@test "manifest_entry_trusted rejects an unknown source class and says so" {
    json='{"version":"0.0.1","files":{"src/app.ts":{"sha256":"deadbeef","source":"forged"}}}'
    run manifest_entry_trusted "$json" "src/app.ts"
    [ "$status" -ne 0 ]
    [[ "$output" == *"forged"* ]]
    [[ "$output" == *"unknown source"* ]]
}

@test "manifest_entry_trusted rejects the vestigial 'generated' source class" {
    json='{"version":"0.0.1","files":{"a.txt":{"sha256":"d","source":"generated"}}}'
    run manifest_entry_trusted "$json" "a.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"generated"* ]]
}

@test "manifest_entry_trusted rejects a '..' traversal key" {
    json='{"version":"0.0.1","files":{"../outside.txt":{"sha256":"d","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" "../outside.txt"
    [ "$status" -ne 0 ]
}

@test "manifest_entry_trusted rejects a './'-prefixed key" {
    json='{"version":"0.0.1","files":{"./.git/x.txt":{"sha256":"d","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" "./.git/x.txt"
    [ "$status" -ne 0 ]
}

@test "manifest_entry_trusted rejects an absolute key" {
    json='{"version":"0.0.1","files":{"/etc/passwd":{"sha256":"d","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" "/etc/passwd"
    [ "$status" -ne 0 ]
}

@test "manifest_entry_trusted rejects a pointer-block source on a non-pointer path" {
    json='{"version":"0.0.1","files":{"src/app.ts":{"sha256":"d","source":"pointer-block"}}}'
    run manifest_entry_trusted "$json" "src/app.ts"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pointer-block"* ]]
}

@test "manifest_entry_trusted accepts a pointer-block source on AGENTS.md" {
    json='{"version":"0.0.1","files":{"AGENTS.md":{"sha256":"d","source":"pointer-block"}}}'
    run manifest_entry_trusted "$json" "AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "manifest_entry_trusted rejects a skill-link source outside the skill namespaces" {
    json='{"version":"0.0.1","files":{"src/evil":{"sha256":"d","source":"skill-link"}}}'
    run manifest_entry_trusted "$json" "src/evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"skill-link"* ]]
}

@test "manifest_entry_trusted accepts a skill-link entry with a present canonical dir and canonical target" {
    mkdir -p "${WORK}/.repomethod/skills/my-skill"
    json='{"version":"0.0.1","files":{".claude/skills/my-skill":{"sha256":"../../.repomethod/skills/my-skill","source":"skill-link"}}}'
    run manifest_entry_trusted "$json" ".claude/skills/my-skill" "$WORK"
    [ "$status" -eq 0 ]
}

@test "manifest_entry_trusted rejects a skill-link entry whose canonical skill dir is missing" {
    json='{"version":"0.0.1","files":{".claude/skills/my-skill":{"sha256":"../../.repomethod/skills/my-skill","source":"skill-link"}}}'
    run manifest_entry_trusted "$json" ".claude/skills/my-skill" "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *".claude/skills/my-skill"* ]]
    [[ "$output" == *"canonical"* ]]
}

@test "manifest_entry_trusted rejects a skill-link entry with a wrong recorded target" {
    mkdir -p "${WORK}/.repomethod/skills/my-skill"
    json='{"version":"0.0.1","files":{".claude/skills/my-skill":{"sha256":"../../.repomethod/skills/bar","source":"skill-link"}}}'
    run manifest_entry_trusted "$json" ".claude/skills/my-skill" "$WORK"
    [ "$status" -ne 0 ]
    json2='{"version":"0.0.1","files":{".claude/skills/my-skill":{"sha256":"/etc/x","source":"skill-link"}}}'
    run manifest_entry_trusted "$json2" ".claude/skills/my-skill" "$WORK"
    [ "$status" -ne 0 ]
}

@test "manifest_entry_trusted fails a skill-link entry closed when target_abs is not passed" {
    json='{"version":"0.0.1","files":{".claude/skills/my-skill":{"sha256":"../../.repomethod/skills/my-skill","source":"skill-link"}}}'
    run manifest_entry_trusted "$json" ".claude/skills/my-skill"
    [ "$status" -ne 0 ]
}

@test "manifest_entry_trusted accepts a normal blueprint entry whose key is in the package inventory" {
    json='{"version":"0.0.1","files":{".repomethod/scripts/verify.sh":{"sha256":"abc123","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" ".repomethod/scripts/verify.sh"
    [ "$status" -eq 0 ]
}

@test "manifest_entry_trusted accepts a blueprint entry for .repomethod/verify-command (inventory key)" {
    json='{"version":"0.0.1","files":{".repomethod/verify-command":{"sha256":"abc123","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" ".repomethod/verify-command"
    [ "$status" -eq 0 ]
}

@test "manifest_entry_trusted rejects a blueprint entry whose key is not in the package inventory" {
    json='{"version":"0.0.1","files":{"src/app.ts":{"sha256":"abc123","source":"blueprint"}}}'
    run manifest_entry_trusted "$json" "src/app.ts"
    [ "$status" -ne 0 ]
    [[ "$output" == *"src/app.ts"* ]]
    [[ "$output" == *"inventory"* ]]
}

@test "manifest_entry_trusted accepts a local entry with a clean key that is not in the inventory (Ruling P2)" {
    json='{"version":"0.0.1","files":{"src/app.ts":{"sha256":"abc123","source":"local"}}}'
    run manifest_entry_trusted "$json" "src/app.ts"
    [ "$status" -eq 0 ]
}

@test "manifest_entry_trusted accepts a local entry with a clean key (no inventory needed)" {
    json='{"version":"0.0.1","files":{"docs/mine.md":{"sha256":"abc123","source":"local"}}}'
    run manifest_entry_trusted "$json" "docs/mine.md"
    [ "$status" -eq 0 ]
}

@test "manifest_file_hash returns recorded hash" {
    m="$(manifest_init "0.1.0" "core")"
    m="$(manifest_add_file "$m" "AGENTS.md" "abc123" "blueprint")"
    run manifest_file_hash "$m" "AGENTS.md"
    [ "$output" = "abc123" ]
}

@test "manifest_file_hash returns empty for unknown file" {
    m="$(manifest_init "0.1.0" "core")"
    run manifest_file_hash "$m" "unknown.md"
    [ "$output" = "" ]
}
