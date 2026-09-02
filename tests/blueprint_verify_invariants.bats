setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-invariants.sh"
    PLAN="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-obligations.sh"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "passes when the spec declares no integration invariants" {
    printf '# Task: x\n\n## Akzeptanzkriterien\n\n1. y\n' > "${WORK}/spec.md"
    run "$SCRIPT" --spec "${WORK}/spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no integration invariants declared"* ]]
}

@test "accepts the English Integration Invariants heading" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: x

## Integration Invariants

- `true`
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1/1 integration invariants passed"* ]]
}

@test "runs each invariant in order and passes when all exit 0" {
    cat > "${WORK}/spec.md" <<EOF
# Task: budget

## Integrationsinvarianten

- \`printf '{"e":"budget_exhausted"}\n{"e":"budget_exhausted"}\n' > ${WORK}/smoke.jsonl\`
- \`test "\$(grep -c budget_exhausted ${WORK}/smoke.jsonl)" -le 5\`
- \`grep -q budget_exhausted ${WORK}/smoke.jsonl\`
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3/3 integration invariants passed"* ]]
}

@test "fails on the first invariant that exits non-zero and names it" {
    cat > "${WORK}/spec.md" <<EOF
# Task: budget

## Integrationsinvarianten

- \`printf 'a\nb\nc\nd\ne\nf\n' > ${WORK}/smoke.txt\`
- \`test "\$(wc -l < ${WORK}/smoke.txt)" -le 5\`
- \`echo unreached > ${WORK}/unreached\`
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"INVARIANT-FAILED: [2]"* ]]
    [ ! -f "${WORK}/unreached" ]
}

@test "section ends at the next heading" {
    cat > "${WORK}/spec.md" <<EOF
# Task: x

## Integrationsinvarianten

- \`true\`

## Eskalationsbedingungen

- \`false\`
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1/1 integration invariants passed"* ]]
}

make_obligation_repo() {
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/specs" "${WORK}/.repomethod/workflows"
}

approve_demo() {
    "$PLAN" extract --mode classic --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    local revision
    revision="$(jq -r '.revision' "${WORK}/.repomethod/workflows/demo.plan-obligations.json")"
    "$PLAN" approve --mode classic --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision "$revision" --approval-text reviewed >/dev/null
}

@test "invariant_required obligation needs an explicitly matching integration invariant" {
    make_obligation_repo
    cat > "${WORK}/specs/demo.md" <<'EOF_SPEC'
# Task: x

## Plan Obligations

- `edge` [behaviour] [invariant_required] Error ordering is preserved.

## Integration Invariants

- `true`
EOF_SPEC
    approve_demo

    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"INVARIANT-MISSING: obl.edge"* ]]

    cat >> "${WORK}/specs/demo.md" <<'EOF_SPEC'
- `obl.edge`: `true`
EOF_SPEC
    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2/2 integration invariants passed"* ]]
}

@test "unknown or malformed invariant obligation references fail closed" {
    make_obligation_repo
    cat > "${WORK}/specs/demo.md" <<'EOF_SPEC'
# Task: x

## Plan Obligations

- `known` [behaviour] Known behaviour.

## Integration Invariants

- `obl.unknown`: `true`
EOF_SPEC
    approve_demo
    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown obligation reference obl.unknown"* ]]

    cat > "${WORK}/specs/demo.md" <<'EOF_SPEC'
# Task: x

## Plan Obligations

- `known` [behaviour] Known behaviour.

## Integration Invariants

- `obl.known` `true`
EOF_SPEC
    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed obligation-referenced invariant"* ]]

    cat > "${WORK}/specs/demo.md" <<'EOF_SPEC'
# Task: x

## Plan Obligations

- `known` [behaviour] Known behaviour.

## Integration Invariants

- `obl.KNOWN`: `true`
EOF_SPEC
    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed obligation-referenced invariant"* ]]
}

@test "error ordering and edge-case keyword lint warns only" {
    make_obligation_repo
    cat > "${WORK}/specs/demo.md" <<'EOF_SPEC'
# Task: x

## Plan Obligations

- `edge` [behaviour] Error ordering covers edge cases.

## Integration Invariants

- `true`
EOF_SPEC
    approve_demo

    run "$SCRIPT" --spec "${WORK}/specs/demo.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INVARIANT-WARN: obl.edge"* ]]
    [[ "$output" == *"1/1 integration invariants passed"* ]]
}
