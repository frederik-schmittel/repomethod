setup() {
    load 'test_helper/common-setup'
    _common_setup
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "release.sh dies on a non-semver argument" {
    run "${REPO_ROOT}/scripts/release.sh" nope
    [ "$status" -eq 1 ]
}

@test "release.sh dies with no argument" {
    run "${REPO_ROOT}/scripts/release.sh"
    [ "$status" -eq 1 ]
}

@test "project CI keeps cross-platform coverage and delegates the repository-owned gate" {
    workflow="${REPO_ROOT}/.github/workflows/ci.yml"
    run grep -F "ubuntu-latest" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "macos-latest" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "brew install bash" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "Install shellcheck v0.11.0" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "npm run test:timed -- test-results" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "actions/upload-artifact@v4" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F "bash scripts/ci-quality.sh" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'bash scripts/ci-tests.sh shard test-results "${{ matrix.shard }}"' "$workflow"
    [ "$status" -eq 0 ]
}

@test "release.sh refuses to run against a dirty working tree" {
    # release.sh's own verification gate runs this whole suite (including
    # this file) inside a clone. Without this guard, this test would clone
    # again and invoke release.sh again from inside that gate run, which
    # would run this suite again, recursing without end. release.sh
    # exports this marker before its internal `bats` call specifically so
    # the nested run can skip straight past the tests that would recurse.
    if [ -n "${REPOMETHOD_RELEASE_SELFTEST_NESTED:-}" ]; then
        skip "would recurse into release.sh's own gate — already running nested"
    fi

    cp -R "${REPO_ROOT}" "${WORK}/repo"
    rm -rf "${WORK}/repo/.git"
    git -C "${WORK}/repo" init -q
    git -C "${WORK}/repo" config user.email test@example.com
    git -C "${WORK}/repo" config user.name Test
    git -C "${WORK}/repo" add .
    git -C "${WORK}/repo" commit -q -m base
    echo dirty >> "${WORK}/repo/README.md"

    run "${WORK}/repo/scripts/release.sh" 9.9.9
    [ "$status" -eq 1 ]
    [[ "$output" == *"working tree is dirty"* ]]
}

@test "release.sh succeeds end-to-end against a clean clone: VERSION, commit, and tag" {
    if [ -n "${REPOMETHOD_RELEASE_SELFTEST_NESTED:-}" ]; then
        skip "would recurse into release.sh's own gate — already running nested"
    fi

    cp -R "${REPO_ROOT}" "${WORK}/repo"
    rm -rf "${WORK}/repo/.git"
    git -C "${WORK}/repo" init -q
    git -C "${WORK}/repo" config user.email test@example.com
    git -C "${WORK}/repo" config user.name Test
    git -C "${WORK}/repo" add .
    git -C "${WORK}/repo" commit -q -m base

    run env PATH="$PATH" "${WORK}/repo/scripts/release.sh" 9.9.9
    [ "$status" -eq 0 ]
    [ "$(cat "${WORK}/repo/VERSION")" = "9.9.9" ]
    [ "$(node -p "require('${WORK}/repo/package.json').version")" = "9.9.9" ]
    run git -C "${WORK}/repo" show-ref --verify --quiet refs/tags/v9.9.9
    [ "$status" -eq 0 ]
    run git -C "${WORK}/repo" log -1 --pretty=%s
    [ "$status" -eq 0 ]
    [ "$output" = "chore: release v9.9.9" ]
}

@test "release.sh can tag the initial version when metadata already matches" {
    if [ -n "${REPOMETHOD_RELEASE_SELFTEST_NESTED:-}" ]; then
        skip "would recurse into release.sh's own gate — already running nested"
    fi

    cp -R "${REPO_ROOT}" "${WORK}/repo"
    rm -rf "${WORK}/repo/.git"
    git -C "${WORK}/repo" init -q
    git -C "${WORK}/repo" config user.email test@example.com
    git -C "${WORK}/repo" config user.name Test
    git -C "${WORK}/repo" add .
    git -C "${WORK}/repo" commit -q -m base

    current="$(cat "${WORK}/repo/VERSION")"
    before="$(git -C "${WORK}/repo" rev-parse HEAD)"
    run env PATH="$PATH" "${WORK}/repo/scripts/release.sh" "$current"
    [ "$status" -eq 0 ]
    [ "$(git -C "${WORK}/repo" rev-parse HEAD)" = "$before" ]
    run git -C "${WORK}/repo" show-ref --verify --quiet "refs/tags/v${current}"
    [ "$status" -eq 0 ]
}
