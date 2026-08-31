# tests/skill_docs_sync.bats
setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/skills/docs-sync/scripts/check-doc-references.sh"
    SKILL_MD="${REPO_ROOT}/blueprint/.repomethod/skills/docs-sync/SKILL.md"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "SKILL.md has valid frontmatter and required sections" {
    [ -f "$SKILL_MD" ]
    run grep -c '^name: docs-sync$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## When NOT to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "passes when all referenced paths exist" {
    mkdir -p "${WORK}/scripts"
    touch "${WORK}/scripts/setup.sh"
    cat > "${WORK}/README.md" <<'EOF'
Run `scripts/setup.sh` to get started.
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "flags a reference to a path that no longer exists" {
    cat > "${WORK}/README.md" <<'EOF'
Run `scripts/does-not-exist.sh` to get started.
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE: README.md: scripts/does-not-exist.sh"* ]]
}

@test "checks AGENTS.md and CLAUDE.md too when present" {
    cat > "${WORK}/AGENTS.md" <<'EOF'
See `nonexistent/file.md`.
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE: AGENTS.md: nonexistent/file.md"* ]]
}


@test "ignores inline-code URLs instead of treating them as repo paths" {
    cat > "${WORK}/README.md" <<'EOF'
See `https://example.com/docs/install.sh` for details.
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 0 references checked"* ]]
}
