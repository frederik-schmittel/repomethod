setup() {
    load 'test_helper/common-setup'
    _common_setup

    TEST_ROOT="$(mktemp -d)"
    TARGET="${TEST_ROOT}/target"
    NPM_CACHE="${TEST_ROOT}/npm-cache"
    mkdir -p "$TARGET" "$NPM_CACHE"
    git -C "$TARGET" init -q
    mkdir -p "${TARGET}/nested"
}

teardown() {
    [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ] && rm -rf -- "$TEST_ROOT"
    true
}

@test "npm metadata exposes one dependency-free repomethod command" {
    [ "$(jq -r '.name' "${REPO_ROOT}/package.json")" = "repomethod" ]
    [ "$(jq -r '.bin | keys | join(",")' "${REPO_ROOT}/package.json")" = "repomethod" ]
    [ "$(jq -r '.dependencies // {} | length' "${REPO_ROOT}/package.json")" -eq 0 ]
    [ "$(jq -r '.scripts.postinstall // empty' "${REPO_ROOT}/package.json")" = "" ]
    [ "$(jq -r '.publishConfig.access' "${REPO_ROOT}/package.json")" = "public" ]
    [ "$(jq -r '.version' "${REPO_ROOT}/package.json")" = "$(cat "${REPO_ROOT}/VERSION")" ]
}

@test "CLI reports version and rejects an unknown command" {
    run node "${REPO_ROOT}/bin/repomethod.js" --version
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "${REPO_ROOT}/VERSION")" ]

    run node "${REPO_ROOT}/bin/repomethod.js" unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown command"* ]]
}

@test "doctor resolves the repository root and remains read-only before install" {
    expected_target="$(git -C "$TARGET" rev-parse --show-toplevel)"
    run bash -c 'cd "$1" && node "$2" doctor' _ \
        "${TARGET}/nested" "${REPO_ROOT}/bin/repomethod.js"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ok] target: ${expected_target}"* ]]
    [[ "$output" == *"installation: not installed"* ]]
    [ ! -e "${TARGET}/.repomethod" ]
}

@test "doctor rejects Bash older than 4.4" {
    # inherit_errexit (lib/common.sh) requires Bash 4.4+; on an older Bash
    # it's silently a no-op, so doctor must actually gate on it rather than
    # accepting any Bash 4.x.
    stub_dir="$(mktemp -d)"
    cat > "${stub_dir}/bash" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *BASH_VERSINFO*) printf '4.2' ;;
    *) exec /bin/bash "$@" ;;
esac
EOF
    chmod +x "${stub_dir}/bash"
    run env PATH="${stub_dir}:${PATH}" node "${REPO_ROOT}/bin/repomethod.js" doctor --target "$TARGET"
    [ "$status" -eq 1 ]
    [[ "$output" == *"4.4"* ]]
    rm -rf -- "$stub_dir"
}

@test "doctor rejects a directory outside a Git repository" {
    plain="${TEST_ROOT}/plain"
    mkdir -p "$plain"
    run node "${REPO_ROOT}/bin/repomethod.js" doctor --target "$plain"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a git repository"* ]]
}

@test "repository-local npm CLI installs into only that repository" {
    run env npm_config_cache="$NPM_CACHE" npm pack --silent --pack-destination "$TEST_ROOT" "$REPO_ROOT"
    [ "$status" -eq 0 ]
    tarball="${TEST_ROOT}/${output##*$'\n'}"
    [ -f "$tarball" ]

    run env npm_config_cache="$NPM_CACHE" npm install --save-dev --ignore-scripts \
        --prefix "$TARGET" "$tarball"
    [ "$status" -eq 0 ]

    run bash -c 'cd "$1" && npm exec -- repomethod doctor' _ "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installation: not installed"* ]]

    run bash -c 'cd "$1" && npm exec -- repomethod install --offline' _ "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/AGENTS.md" ]
    [ -f "${TARGET}/node_modules/.bin/repomethod" ]
}

@test "packed global CLI installs, diagnoses, updates, and uninstalls the current repository" {
    run env npm_config_cache="$NPM_CACHE" npm pack --silent --pack-destination "$TEST_ROOT" "$REPO_ROOT"
    [ "$status" -eq 0 ]
    tarball="${TEST_ROOT}/${output##*$'\n'}"
    [ -f "$tarball" ]

    run tar -tf "$tarball"
    [ "$status" -eq 0 ]
    [[ "$output" == *"package/bin/repomethod.js"* ]]
    [[ "$output" == *"package/blueprint/.repomethod/gitignore.template"* ]]
    [[ "$output" != *"package/tests/"* ]]
    # Retired network/lockfile infrastructure must never resurface in a
    # published tarball, even if a future change re-adds one of these
    # files to the source tree without updating package.json's files list.
    [[ "$output" != *"package/lib/fetch.sh"* ]]
    [[ "$output" != *"package/lib/lockfile.sh"* ]]
    [[ "$output" != *"package/skills.lock.json"* ]]
    [[ "$output" != *"package/tools.lock.json"* ]]

    prefix="${TEST_ROOT}/global"
    run env npm_config_cache="$NPM_CACHE" npm install --global --prefix "$prefix" --ignore-scripts "$tarball"
    [ "$status" -eq 0 ]

    cli="${prefix}/bin/repomethod"
    [ -x "$cli" ]

    run bash -c 'cd "$1" && "$2" install --offline' _ "${TARGET}/nested" "$cli"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/AGENTS.md" ]
    [ -f "${TARGET}/.repomethod/.gitignore" ]
    [ ! -e "${TARGET}/nested/AGENTS.md" ]

    run bash -c 'cd "$1" && "$2" doctor' _ "${TARGET}/nested" "$cli"
    [ "$status" -eq 0 ]
    [[ "$output" == *"managed files:"*"unchanged"* ]]

    run bash -c 'cd "$1" && "$2" update --offline' _ "${TARGET}/nested" "$cli"
    [ "$status" -eq 0 ]

    run bash -c 'cd "$1" && "$2" uninstall' _ "${TARGET}/nested" "$cli"
    [ "$status" -eq 0 ]
    [ ! -e "${TARGET}/AGENTS.md" ]
    [ ! -e "${TARGET}/.repomethod/manifest.json" ]
    git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null
}
