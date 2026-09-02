setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPTS="${REPO_ROOT}/blueprint/.repomethod/scripts"
    SCRIPT="${SCRIPTS}/plan-obligations.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/specs" "${WORK}/custom" \
        "${WORK}/.repomethod/scripts" "${WORK}/.repomethod/workflows" \
        "${WORK}/.repomethod/evidence" "${WORK}/src"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "near-miss heading guard rejects only headings that try to be Plan Obligations" {
    cat > "${WORK}/custom/My-Feature.md" <<'EOF'
# Task

## Deployment Plan and Rollout Obligations

Nothing normative here.
EOF
    run "$SCRIPT" check --spec "${WORK}/custom/My-Feature.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]

    cat > "${WORK}/custom/My-Feature.md" <<'EOF'
# Task

### Plan Obligations
EOF
    run "$SCRIPT" check --spec "${WORK}/custom/My-Feature.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Plan Obligations heading"* ]]

    cat > "${WORK}/custom/My-Feature.md" <<'EOF'
# Task

## Plan obligations:
EOF
    run "$SCRIPT" check --spec "${WORK}/custom/My-Feature.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected exactly: ## Plan Obligations"* ]]
}

@test "spec path and slug conventions apply only after plan obligations are active" {
    cat > "${WORK}/custom/My-Feature.md" <<'EOF'
# Task

## Plan Obligations

## Acceptance Criteria

1. works
EOF
    run "$SCRIPT" check --spec "${WORK}/custom/My-Feature.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]

    cat > "${WORK}/custom/My-Feature.md" <<'EOF'
# Task

## Plan Obligations

- `api-shape` [shape] API returns id and status.
EOF
    run "$SCRIPT" check --spec "${WORK}/custom/My-Feature.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"top-level feature spec under specs/"* ]]
}

prepare_gate_fixture() {
    cp "${SCRIPTS}"/*.sh "${WORK}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    chmod +x "${WORK}/.repomethod/scripts/"*.sh
    printf 'true\n' > "${WORK}/.repomethod/verify-command"

    cat > "${WORK}/specs/demo.md" <<'EOF'
# Task: mode binding

## Scope

- `src/**`

## Plan Obligations

- `api-shape` [shape] API returns id and status.

## Acceptance Criteria

1. mode matches

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF

    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for demo.md
- [x] 1. mode matches
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"

    "${WORK}/.repomethod/scripts/plan-obligations.sh" extract --mode classic \
        --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "${WORK}/.repomethod/scripts/plan-obligations.sh" approve --mode classic \
        --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m baseline
}

@test "aggregate gate derives plan-obligation mode from workflow state" {
    prepare_gate_fixture
    printf '{"mode":"graph"}\n' > "${WORK}/.repomethod/workflows/state.json"
    git -C "$WORK" add .repomethod/workflows/state.json
    git -C "$WORK" commit -q -m "graph state"

    run bash -c "cd '$WORK' && .repomethod/scripts/agent-gate.sh \
        --spec specs/demo.md --state .repomethod/workflows/state.json \
        --base HEAD --report .repomethod/evidence/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"current spec or workflow mode"* ]]
}

@test "aggregate gate accepts an artifact whose mode matches workflow state" {
    prepare_gate_fixture
    printf '{"mode":"classic"}\n' > "${WORK}/.repomethod/workflows/state.json"
    git -C "$WORK" add .repomethod/workflows/state.json
    git -C "$WORK" commit -q -m "classic state"

    run bash -c "cd '$WORK' && .repomethod/scripts/agent-gate.sh \
        --spec specs/demo.md --state .repomethod/workflows/state.json \
        --base HEAD --report .repomethod/evidence/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[agent-gate] all gates passed"* ]]
}
