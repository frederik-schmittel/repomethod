setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-spec-lint.sh"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: lint fixture

## Scope

- `src/**`

## Acceptance Criteria

1. feature behavior is covered
EOF
}

@test "accepts a meaningful scope and numbered acceptance criteria" {
    write_spec

    run "$SCRIPT" --spec "${WORK}/spec.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: spec structure"* ]]
}

@test "rejects a missing Scope section" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: no scope

## Acceptance Criteria

- [ ] behavior is covered
EOF

    run "$SCRIPT" --spec "${WORK}/spec.md"

    [ "$status" -ne 0 ]
    [[ "$output" == *"REJECTED: Scope"* ]]
}

@test "rejects an empty or placeholder-only Scope section" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: placeholder scope

## Scope

- `TBD`

## Acceptance Criteria

- behavior is covered
EOF

    run "$SCRIPT" --spec "${WORK}/spec.md"

    [ "$status" -ne 0 ]
    [[ "$output" == *"REJECTED: Scope"* ]]
}

@test "rejects missing or empty Acceptance Criteria" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: no acceptance

## Scope

- `src/**`

## Acceptance Criteria

Narrative alone is not a criterion.
EOF

    run "$SCRIPT" --spec "${WORK}/spec.md"

    [ "$status" -ne 0 ]
    [[ "$output" == *"REJECTED: Acceptance Criteria"* ]]
}

@test "all repository feature specs pass unchanged" {
    local spec
    for spec in "${REPO_ROOT}"/specs/*.md; do
        run "$SCRIPT" --spec "$spec"
        [ "$status" -eq 0 ]
    done
}
