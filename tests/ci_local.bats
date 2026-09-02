setup() {
    load 'test_helper/common-setup'
    _common_setup
    WORK="$(mktemp -d)"
    CI_LOCAL="${REPO_ROOT}/scripts/ci-local.sh"
    CI_QUALITY="${REPO_ROOT}/scripts/ci-quality.sh"
    CI_TESTS="${REPO_ROOT}/scripts/ci-tests.sh"
    WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"
}

teardown() {
    rm -rf -- "$WORK"
}

make_fake() {
    local name="$1" body="$2"
    mkdir -p "${WORK}/bin"
    cat > "${WORK}/bin/${name}" <<EOF
#!/usr/bin/env bash
${body}
EOF
    chmod +x "${WORK}/bin/${name}"
}

@test "ci-tests fails explicitly when pinned Bats is missing" {
    make_fake node 'exit 0'
    run env PATH="${WORK}/bin:/usr/bin:/bin" bash "$CI_TESTS" full
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing required command: bats 1.13.0"* ]]
}

@test "ci-tests rejects Bats version drift before running tests" {
    make_fake node 'exit 0'
    make_fake bats 'echo "Bats 9.9.9"'
    run env PATH="${WORK}/bin:/usr/bin:/bin" bash "$CI_TESTS" full
    [ "$status" -ne 0 ]
    [[ "$output" == *"bats version mismatch: expected 1.13.0, got 9.9.9"* ]]
}

@test "ci-quality rejects ShellCheck version drift before quality work" {
    make_fake shellcheck 'printf "version: 9.9.9\n"'
    run env PATH="${WORK}/bin:${PATH}" bash "$CI_QUALITY"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shellcheck version mismatch: expected 0.11.0, got 9.9.9"* ]]
}

@test "ci-local rejects an executable entry point recorded as 100644" {
    repo="${WORK}/repo"
    mkdir -p "$repo/scripts"
    cp "$CI_LOCAL" "$repo/scripts/ci-local.sh"
    cat > "$repo/scripts/ci-quality.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$repo/scripts/ci-tests.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$repo/scripts/validate-bats-shards.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$repo/install.sh" <<'EOF'
#!/usr/bin/env bash
echo install
EOF
    chmod 755 "$repo/scripts/"*.sh
    chmod 644 "$repo/install.sh"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    git -C "$repo" add .
    git -C "$repo" commit -q -m base

    run bash "$repo/scripts/ci-local.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"install.sh is 100644, expected 100755"* ]]
}

@test "local CI composes quality Git modes shard validation and full Bats" {
    run grep -F 'bash scripts/ci-quality.sh' "$CI_LOCAL"
    [ "$status" -eq 0 ]
    run grep -F 'git -C "$ROOT" ls-files --stage' "$CI_LOCAL"
    [ "$status" -eq 0 ]
    run grep -F 'bash scripts/validate-bats-shards.sh .github/ci/bats-shards.tsv 2' "$CI_LOCAL"
    [ "$status" -eq 0 ]
    run grep -F 'bash scripts/ci-tests.sh full test-results' "$CI_LOCAL"
    [ "$status" -eq 0 ]
}

@test "GitHub CI delegates Bats and quality execution to shared scripts" {
    run grep -F 'bash scripts/ci-tests.sh smoke test-results' "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F 'bash scripts/ci-tests.sh shard test-results "${{ matrix.shard }}"' "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F 'bash scripts/ci-quality.sh' "$WORKFLOW"
    [ "$status" -eq 0 ]

    run grep -F 'npm pack --dry-run --json' "$WORKFLOW"
    [ "$status" -ne 0 ]
    run grep -F 'shellcheck lib/*.sh' "$WORKFLOW"
    [ "$status" -ne 0 ]
}

@test "package scripts expose fast and full local CI contracts" {
    run jq -r '.scripts.check' "${REPO_ROOT}/package.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ci-quality.sh"* ]]
    [[ "$output" == *"validate-bats-shards.sh"* ]]

    run jq -r '.scripts["ci:local"]' "${REPO_ROOT}/package.json"
    [ "$status" -eq 0 ]
    [ "$output" = "bash scripts/ci-local.sh" ]
}
