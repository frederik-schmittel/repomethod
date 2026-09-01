# Tests for scripts/release.sh. No network is used: the "real behavior"
# tests operate on a `git clone` of this repo into a temp directory rather
# than the actual working checkout, so a full, successful release run never
# touches this repo's own VERSION file, history, or tags.

setup() {
    load 'test_helper/common-setup'
    _common_setup
}

# Sets CLONE to a fresh local clone of this repo with scripts/release.sh
# and this test file copied in from the working tree (not just cloned from
# git history), since both may still be uncommitted at test time — the
# clone otherwise only contains committed content. Configures a local git
# identity so commits inside the clone succeed even without a global user
# config.
_make_clone() {
    CLONE="$(mktemp -d)"
    # --no-tags: REPO_ROOT accumulates real release tags over time (e.g.
    # v0.1.0 after the first release), and this clone must start tagless so
    # release.sh's own tagging is what these tests exercise, not a collision
    # with a tag the clone happened to inherit.
    git clone -q --no-tags "$REPO_ROOT" "$CLONE"
    git -C "$CLONE" config user.email "test@example.com"
    git -C "$CLONE" config user.name "Test User"
    mkdir -p "${CLONE}/scripts"
    cp "${REPO_ROOT}/scripts/release.sh" "${CLONE}/scripts/release.sh"
    chmod +x "${CLONE}/scripts/release.sh"
    cp "${REPO_ROOT}/tests/release_script.bats" "${CLONE}/tests/release_script.bats"
    cp "${REPO_ROOT}/package.json" "${CLONE}/package.json"
    cp "${REPO_ROOT}/package-lock.json" "${CLONE}/package-lock.json"
    mkdir -p "${CLONE}/bin"
    cp "${REPO_ROOT}/bin/repomethod.js" "${CLONE}/bin/repomethod.js"
    chmod +x "${CLONE}/bin/repomethod.js"
    cp "${REPO_ROOT}/blueprint/.repomethod/gitignore.template" "${CLONE}/blueprint/.repomethod/gitignore.template"
    # Commit so the clone's working tree is clean before a test invokes
    # release.sh. Both files above may or may not already be committed in
    # REPO_ROOT depending on when this runs, so the clone may already have
    # identical copies (nothing to stage) or none at all (untracked, which
    # would make every test hit the dirty-tree guard instead of what it's
    # testing) — --allow-empty covers both cases uniformly.
    git -C "$CLONE" add scripts/release.sh tests/release_script.bats package.json package-lock.json \
        bin/repomethod.js blueprint/.repomethod/gitignore.template
    git -C "$CLONE" commit -q --allow-empty -m "test setup: add release script"
}

# The repository's actual Bats and ShellCheck gates are already run as
# separate CI steps. The release E2E test is responsible for the mechanics
# after those gates succeed: VERSION, commit, and annotated tag. Running the
# complete 130-test suite recursively from inside this one test made the
# result depend on nested runner/HOME/toolchain state and obscured the real
# failure behind test 108. These test-only PATH doubles preserve the release
# script's command/exit-code contract without re-running CI inside CI.
_install_successful_gate_doubles() {
    TEST_BIN="$(mktemp -d)"

    cat > "${TEST_BIN}/bats" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "${TEST_BIN}/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${TEST_BIN}/bats" "${TEST_BIN}/shellcheck"
}

teardown() {
    [ -n "${CLONE:-}" ] && [ -d "$CLONE" ] && rm -rf -- "$CLONE"
    [ -n "${TEST_BIN:-}" ] && [ -d "$TEST_BIN" ] && rm -rf -- "$TEST_BIN"
    true
}

@test "release.sh dies on a non-semver argument" {
    _install_successful_gate_doubles
    run env PATH="${TEST_BIN}:${PATH}" "${REPO_ROOT}/scripts/release.sh" "not-a-version"
    [ "$status" -eq 1 ]
    [[ "$output" == *"semver"* ]]
}

@test "release.sh dies with no argument" {
    run "${REPO_ROOT}/scripts/release.sh"
    [ "$status" -eq 1 ]
}

@test "project CI runs the offline gate on Linux and macOS" {
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
    run grep -F "Verify npm package" "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'npm pack --dry-run --json' "$workflow"
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
    _make_clone
    _install_successful_gate_doubles
    echo "local edit" >> "${CLONE}/README.md"
    run env PATH="${TEST_BIN}:${PATH}" "${CLONE}/scripts/release.sh" "9.9.9"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dirty"* ]]
    # confirm it aborted before touching anything
    [ "$(cat "${CLONE}/VERSION")" != "9.9.9" ]
    [ "$(jq -r '.version' "${CLONE}/package.json")" != "9.9.9" ]
}

@test "release.sh succeeds end-to-end against a clean clone: VERSION, commit, and tag" {
    # See the comment in the dirty-tree test above: same recursion guard.
    if [ -n "${REPOMETHOD_RELEASE_SELFTEST_NESTED:-}" ]; then
        skip "would recurse into release.sh's own gate — already running nested"
    fi
    _make_clone
    _install_successful_gate_doubles
    run env PATH="${TEST_BIN}:${PATH}" "${CLONE}/scripts/release.sh" "9.9.9"
    [ "$status" -eq 0 ]
    [[ "$output" == *"running verification gate: bats"* ]]
    [[ "$output" == *"running verification gate: shellcheck"* ]]
    [[ "$output" == *"running verification gate: npm package"* ]]
    [[ "$output" == *"npm publish"* ]]
    [[ "$output" == *"git push origin v9.9.9"* ]]

    [ "$(cat "${CLONE}/VERSION")" = "9.9.9" ]
    [ "$(jq -r '.version' "${CLONE}/package.json")" = "9.9.9" ]
    [ "$(jq -r '.version' "${CLONE}/package-lock.json")" = "9.9.9" ]
    [ "$(jq -r '.packages[""].version' "${CLONE}/package-lock.json")" = "9.9.9" ]

    # working tree is clean again after the release commit
    [ -z "$(git -C "$CLONE" status --porcelain)" ]

    # HEAD is the release commit
    log_subject="$(git -C "$CLONE" log -1 --format=%s)"
    [[ "$log_subject" == "chore: release v9.9.9" ]]

    # annotated tag exists and points at HEAD
    run git -C "$CLONE" tag -l "v9.9.9"
    [[ "$output" == "v9.9.9" ]]
    tag_commit="$(git -C "$CLONE" rev-list -n 1 v9.9.9)"
    head_commit="$(git -C "$CLONE" rev-parse HEAD)"
    [ "$tag_commit" = "$head_commit" ]

    # it's a real annotated tag (has its own tag object), not a lightweight one
    run git -C "$CLONE" cat-file -t v9.9.9
    [[ "$output" == "tag" ]]
}

@test "release.sh can tag the initial version when metadata already matches" {
    if [ -n "${REPOMETHOD_RELEASE_SELFTEST_NESTED:-}" ]; then
        skip "would recurse into release.sh's own gate — already running nested"
    fi
    _make_clone
    _install_successful_gate_doubles
    current_version="$(cat "${CLONE}/VERSION")"
    before="$(git -C "$CLONE" rev-parse HEAD)"

    run env PATH="${TEST_BIN}:${PATH}" "${CLONE}/scripts/release.sh" "$current_version"
    [ "$status" -eq 0 ]
    [[ "$output" == *"release metadata already matches"* ]]
    [ "$(git -C "$CLONE" rev-parse HEAD)" = "$before" ]
    [ "$(git -C "$CLONE" rev-list -n 1 "v${current_version}")" = "$before" ]
}
