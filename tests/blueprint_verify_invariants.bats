setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-invariants.sh"
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
