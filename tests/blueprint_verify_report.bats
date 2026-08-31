setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-report.sh"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    # $1 optional extra section appended verbatim
    cat > "${WORK}/spec.md" <<'EOF'
# Task: p4-p6

## Akzeptanzkriterien

1. it integrates
EOF
    [ -n "${1:-}" ] && printf '%s\n' "$1" >> "${WORK}/spec.md"
    # give the spec a stable filename the report can name
    mv "${WORK}/spec.md" "${WORK}/p4-p6.md"
}

@test "accepts the English Test Count Command heading" {
    write_spec "$(printf '## Test Count Command\n\n`printf 7`\n')"
    printf 'Report for p4-p6.md\nTests: 7\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tests: 7 confirmed"* ]]
}

@test "passes when the report names the spec and no test-count command is declared" {
    write_spec
    printf 'Report for p4-p6.md\nAll good.\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: report names p4-p6.md"* ]]
}

@test "fails when the report does not name its spec" {
    write_spec
    printf 'Report for some other phase\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE-REPORT"* ]]
}

@test "passes when the declared test-count command matches the report" {
    write_spec "$(printf '## Testzahl-Befehl\n\n`printf 53`\n')"
    printf 'Report for p4-p6.md\nTests: 53\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tests: 53 confirmed"* ]]
}

@test "fails when the report states a stale test count" {
    write_spec "$(printf '## Testzahl-Befehl\n\n`printf 53`\n')"
    printf 'Report for p4-p6.md\nTests: 37\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TEST-COUNT"* ]]
    [[ "$output" == *"Tests: 53"* ]]
}

@test "Tests: 5 does not satisfy a required count of 53" {
    write_spec "$(printf '## Testzahl-Befehl\n\n`printf 53`\n')"
    printf 'Report for p4-p6.md\nTests: 5\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TEST-COUNT"* ]]
}

@test "fails when the declared test-count command does not produce an integer" {
    write_spec "$(printf '## Testzahl-Befehl\n\n`echo not-a-number`\n')"
    printf 'Report for p4-p6.md\nTests: 53\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/p4-p6.md" --report "${WORK}/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TEST-COUNT"* ]]
}
