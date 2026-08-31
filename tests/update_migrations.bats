setup() {
    load 'test_helper/common-setup'
    _common_setup
    TARGET="$(mktemp -d)"
    git -C "$TARGET" init -q
    "${REPO_ROOT}/install.sh" --target "$TARGET" >/dev/null
    NEW_SRC="$(mktemp -d)/blueprint"
    cp -R "${REPO_ROOT}/blueprint" "$(dirname "$NEW_SRC")"
    MIGDIR="$(mktemp -d)"
    VERSION="$(cat "${REPO_ROOT}/VERSION")"
}

teardown() {
    rm -rf -- "$TARGET" "$(dirname "$NEW_SRC")" "$MIGDIR"
}

# Rewrite the installed manifest's version so update sees a delta.
age_install_to() {
    jq --arg v "$1" '.version = $v' "${TARGET}/.repomethod/manifest.json" > "${TARGET}/.repomethod/m.tmp"
    mv "${TARGET}/.repomethod/m.tmp" "${TARGET}/.repomethod/manifest.json"
}

@test "update prints the version delta and a CHANGELOG pointer" {
    age_install_to "0.0.0"
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0.0.0 -> ${VERSION}"* ]]
    [[ "$output" == *"CHANGELOG.md"* ]]
}

@test "update runs an in-range migration and hands it the target root" {
    age_install_to "0.0.0"
    cat > "${MIGDIR}/${VERSION}.sh" <<'EOS'
#!/usr/bin/env bash
echo "ran against $1" > "$1/.repomethod/migration-marker.txt"
EOS
    run env RM_MIGRATIONS_DIR="$MIGDIR" "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"running migration ${VERSION}"* ]]
    [ -f "${TARGET}/.repomethod/migration-marker.txt" ]
    [ "$(cat "${TARGET}/.repomethod/migration-marker.txt")" = "ran against ${TARGET}" ]
}

@test "update skips an out-of-range migration" {
    age_install_to "0.0.0"
    cat > "${MIGDIR}/9.9.9.sh" <<'EOS'
#!/usr/bin/env bash
touch "$1/.repomethod/should-not-exist.txt"
EOS
    run env RM_MIGRATIONS_DIR="$MIGDIR" "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [ ! -f "${TARGET}/.repomethod/should-not-exist.txt" ]
}

@test "a failing migration aborts the update before files are refreshed" {
    age_install_to "0.0.0"
    cat > "${MIGDIR}/${VERSION}.sh" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
    echo "upstream change" >> "${NEW_SRC}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run env RM_MIGRATIONS_DIR="$MIGDIR" "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -ne 0 ]
    [[ "$output" == *"migration failed"* ]]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" != *"upstream change"* ]]
}

@test "no version delta means no migration notice" {
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$output" != *"review CHANGELOG.md"* ]]
}
