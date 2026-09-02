setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-forbidden.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/src" "${WORK}/outside" "${WORK}/specs"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    local scope="$1"
    shift
    {
        printf '# Task: forbidden check\n\n## Scope\n\n- `%s`\n\n## Must Not Exist\n\n' "$scope"
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
        printf '\n## Acceptance Criteria\n\n1. it works\n'
    } > "${WORK}/specs/task.md"
}

@test "specs without Must Not Exist retain current behavior" {
    cat > "${WORK}/specs/task.md" <<'EOF_SPEC'
# Task: no prohibitions

## Scope

- `src/**`

## Acceptance Criteria

1. it works
EOF_SPEC
    printf 'legacy_api()\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "spec template exposes an inert optional Must Not Exist section" {
    run grep -c '^## Must Not Exist$' "${REPO_ROOT}/blueprint/.repomethod/templates/spec.md"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    cp "${REPO_ROOT}/blueprint/.repomethod/templates/spec.md" "${WORK}/specs/task.md"
    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a fixed-string match inside Scope fails with file and line" {
    write_spec 'src/**' '- `legacy_api(`'
    printf 'safe\nlegacy_api()\n' > "${WORK}/src/app.py"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/app.py:2"* ]]
}

@test "the same forbidden string outside Scope is ignored" {
    write_spec 'src/**' '- `legacy_api(`'
    printf 'safe\n' > "${WORK}/src/app.py"
    printf 'legacy_api()\n' > "${WORK}/outside/app.py"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 1 scoped files"* ]]
}

@test "fixed declarations do not interpret regular-expression metacharacters" {
    write_spec 'src/**' '- `a.b[0]`'
    printf 'axb0\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 0 ]
}

@test "regex declarations require the explicit regex prefix and match as POSIX ERE" {
    write_spec 'src/**' '- regex: `legacy_[0-9]+\(`'
    printf 'legacy_42(\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/app.txt:1"* ]]
    [[ "$output" == *"(regex:"* ]]
}

@test "an invalid regular expression fails closed" {
    write_spec 'src/**' '- regex: `[`'
    printf 'safe\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid Must Not Exist regex"* ]]
}

@test "an unknown declaration form fails closed" {
    write_spec 'src/**' '- glob: `legacy_*`'

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Must Not Exist declaration"* ]]
}

@test "active prohibitions require at least one valid Scope entry" {
    cat > "${WORK}/specs/task.md" <<'EOF_SPEC'
# Task: missing scope

## Scope

none

## Must Not Exist

- `legacy_api(`
EOF_SPEC

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires at least one valid ## Scope entry"* ]]
}

@test "comments and docstrings are content until a language-aware handler exists" {
    write_spec 'src/**' '- `legacy_api(`'
    cat > "${WORK}/src/app.py" <<'EOF_SOURCE'
# legacy_api(
"""legacy_api("""
EOF_SOURCE

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/app.py:1"* ]]
    [[ "$output" == *"FORBIDDEN: src/app.py:2"* ]]
}

@test "unknown file formats are scanned rather than silently skipped" {
    write_spec 'src/**' '- `legacy_api(`'
    printf 'legacy_api()\n' > "${WORK}/src/data.unknown-format"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/data.unknown-format:1"* ]]
}

@test "tracked pre-existing files inside Scope are scanned" {
    write_spec 'src/**' '- `legacy_api(`'
    printf 'legacy_api()\n' > "${WORK}/src/legacy.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m baseline

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/legacy.txt:1"* ]]
}

@test "repository subdirectory input still uses repository-relative scope paths" {
    mkdir -p "${WORK}/nested"
    write_spec 'src/**' '- `legacy_api(`'
    printf 'legacy_api()\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "${WORK}/nested"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/app.txt:1"* ]]
}

@test "a broad Scope never makes the spec match its own declaration" {
    write_spec '**' '- `self_forbidden_marker`'
    printf 'safe\n' > "${WORK}/src/app.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FORBIDDEN"* ]]
}

@test "a scoped symlink fails closed instead of following its target" {
    write_spec 'src/**' '- `legacy_api(`'
    printf 'legacy_api()\n' > "${WORK}/outside/target.txt"
    ln -s ../outside/target.txt "${WORK}/src/link.txt"

    run "$SCRIPT" --spec "${WORK}/specs/task.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scoped path is a symlink"* ]]
}

@test "agent-gate runs verify-forbidden after scope and before acceptance" {
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/.repomethod/evidence"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts"/*.sh "${WORK}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    chmod +x "${WORK}/.repomethod/scripts"/*.sh
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    write_spec 'src/**' '- `legacy_api(`'
    printf 'legacy_api()\n' > "${WORK}/src/app.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m baseline

    cd "$WORK"
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/task.md --base HEAD \
        --report .repomethod/evidence/missing.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"FORBIDDEN: src/app.txt:1"* ]]
    [[ "$output" != *"report not found"* ]]
}
