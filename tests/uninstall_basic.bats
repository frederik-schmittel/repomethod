setup() {
    load 'test_helper/common-setup'
    _common_setup
    TARGET="$(mktemp -d)"
    git -C "$TARGET" init -q
    "${REPO_ROOT}/install.sh" --target "$TARGET" >/dev/null
}

teardown() {
    rm -rf -- "$TARGET"
}

@test "uninstall.sh removes unmodified managed files" {
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -f "${TARGET}/AGENTS.md" ]
}

@test "uninstall.sh keeps a locally modified file" {
    echo "my local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md" ]
    [[ "$output" == *"KEPT (locally modified): .repomethod/docs/WORKFLOW_GRAPH.md"* ]]
}

@test "uninstall.sh removes now-empty installer-created directories" {
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -d "${TARGET}/specs" ]
}

@test "uninstall.sh removes the manifest file" {
    "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ ! -f "${TARGET}/.repomethod/manifest.json" ]
}

# A manifest key with a leading "./" (e.g. "./.git/x.txt") is now
# structurally untrusted — it carries a "." path component — so it is
# caught by manifest_entry_trusted's CONFLICT path BEFORE the device:inode
# identity ascent ever runs. The security intent is unchanged: the file is
# left on disk with its content, the run reports a CONFLICT naming the
# path, exits non-zero, and keeps the manifest. The device:inode .git
# ascent stays covered by tests/uninstall_toctou.bats (clean key +
# symlinked ancestor).
@test "uninstall.sh refuses a structurally untrusted manifest entry that resolves inside .git" {
    echo "real git internal" > "${TARGET}/.git/x.txt"
    hash="$(sha256sum "${TARGET}/.git/x.txt" 2>/dev/null || shasum -a 256 "${TARGET}/.git/x.txt")"
    hash="${hash%% *}"
    cat > "${TARGET}/.repomethod/manifest.json" <<EOF
{"version":"0.1.0","installed_at":"2026-07-19T00:00:00Z","profiles":["core"],"files":{"./.git/x.txt":{"sha256":"${hash}","source":"blueprint"}}}
EOF

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [ -f "${TARGET}/.git/x.txt" ]
    [ "$(cat "${TARGET}/.git/x.txt")" = "real git internal" ]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"./.git/x.txt"* ]]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
}

@test "uninstall refuses to delete a forged blueprint entry for a repository file" {
    mkdir -p "${TARGET}/src" && echo "my code" > "${TARGET}/src/app.ts"
    h="$(sha256sum "${TARGET}/src/app.ts" 2>/dev/null || shasum -a 256 "${TARGET}/src/app.ts")"
    h="${h%% *}"
    jq --arg h "$h" '.files["src/app.ts"] = {sha256:$h, source:"blueprint"}' \
        "${TARGET}/.repomethod/manifest.json" > "${TARGET}/.repomethod/m.new"
    mv "${TARGET}/.repomethod/m.new" "${TARGET}/.repomethod/manifest.json"

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [[ "$output" == *"CONFLICT"* ]]
    [ -f "${TARGET}/src/app.ts" ]
    [ "$(cat "${TARGET}/src/app.ts")" = "my code" ]
    [ "$status" -ne 0 ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]

    # Repeatable: manifest byte-unchanged, so a re-run reproduces it.
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [[ "$output" == *"CONFLICT"* ]]
    [ "$(cat "${TARGET}/src/app.ts")" = "my code" ]
    [ "$status" -ne 0 ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
}

@test "uninstall preserves and reports a manifest entry with an unknown source" {
    jq '.files["src/app.ts"] = {sha256:"d", source:"forged"}' \
        "${TARGET}/.repomethod/manifest.json" > "${TARGET}/.repomethod/m.new"
    mv "${TARGET}/.repomethod/m.new" "${TARGET}/.repomethod/manifest.json"
    mkdir -p "${TARGET}/src" && echo "mine" > "${TARGET}/src/app.ts"

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"src/app.ts"* ]]
    [ -f "${TARGET}/src/app.ts" ]
    [ "$(cat "${TARGET}/src/app.ts")" = "mine" ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]

    # Repeatable: the manifest is byte-unchanged, so a re-run reproduces the
    # identical CONFLICT and identical non-zero exit.
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONFLICT"* ]]
    [ -f "${TARGET}/src/app.ts" ]
    [ "$(cat "${TARGET}/src/app.ts")" = "mine" ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
}
