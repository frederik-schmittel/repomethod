setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify.sh"
    AGENTS="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/.repomethod"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "verify.sh fails closed when nothing is configured" {
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no verification command configured"* ]]
}

@test "verify.sh lists Makefile targets it found as candidates" {
    printf 'test:\n\tgo test ./...\nbuild:\n\tgo build ./...\n.PHONY: test build\n' > "${WORK}/Makefile"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Makefile"* ]]
    [[ "$output" == *"test"* ]]
    [[ "$output" == *"build"* ]]
    [[ "$output" != *".PHONY"* ]]
}

@test "verify.sh lists package.json scripts it found as candidates" {
    cat > "${WORK}/package.json" <<'EOF'
{
  "name": "x",
  "scripts": {
    "test": "vitest run",
    "lint": "eslint ."
  }
}
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"package.json"* ]]
    [[ "$output" == *"test"* ]]
    [[ "$output" == *"lint"* ]]
}

@test "verify.sh suggests pytest when pyproject configures it" {
    cat > "${WORK}/pyproject.toml" <<'EOF'
[project]
name = "x"

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pyproject.toml"* ]]
    [[ "$output" == *"pytest"* ]]
}

@test "verify.sh still runs a configured command and trusts its exit status" {
    printf 'exit 7\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 7 ]
}

@test "verify.sh runs every non-comment line and fails if any line fails" {
    printf 'true\nfalse\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[verify] true"* ]]
    [[ "$output" == *"[verify] false"* ]]
}

@test "verify.sh does not let a stdin-reading line swallow the rest of the file" {
    printf 'cat >/dev/null\nfalse\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[verify] false"* ]]
}

@test "verify.sh succeeds when all non-comment lines pass" {
    printf 'true\ntrue\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
}

@test "verify.sh still fails closed on a comments-and-blanks-only file" {
    printf '# a comment\n\n   \n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no verification command configured"* ]]
}

@test "warning flag preserves verify command exit status" {
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git add -A
    printf 'exit 7\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" --warn-frontend-uncovered "$WORK"
    [ "$status" -eq 7 ]
    [[ "$output" == *"WARN: change touches frontend files but verify-command runs no JS check"* ]]
}

@test "warning flag uses the existing frontend token set" {
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git add -A

    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" --warn-frontend-uncovered "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: change touches frontend files but verify-command runs no JS check"* ]]

    # Every token in the existing set silences the warning without invoking it.
    for token in pnpm npm npx vitest jest tsc eslint; do
        printf 'echo %s check\n' "$token" > "${WORK}/.repomethod/verify-command"
        run "$SCRIPT" --warn-frontend-uncovered "$WORK"
        [ "$status" -eq 0 ]
        [[ "$output" != *"WARN: change touches frontend files"* ]]
    done

    # Commented tokens do not count as an active JS check.
    printf '# pnpm test\ntrue\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" --warn-frontend-uncovered "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: change touches frontend files but verify-command runs no JS check"* ]]
}

@test "verify without warning flag stays silent" {
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git add -A
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: change touches frontend files"* ]]
}

@test "canonical AGENTS.md no longer describes a separate full-verification command" {
    run grep -Fi "full-verification command" "$AGENTS"
    [ "$status" -ne 0 ]
    run grep -Fi "separate from the" "$AGENTS"
    [ "$status" -ne 0 ]
    run grep -F ".repomethod/verify-command" "$AGENTS"
    [ "$status" -eq 0 ]
}
