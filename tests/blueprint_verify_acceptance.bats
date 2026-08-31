setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-acceptance.sh"
    WORK="$(mktemp -d)"
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200
2. Response body contains "ok"
EOF
}

teardown() {
    rm -rf -- "$WORK"
}

@test "accepts English section headings" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Acceptance Criteria

1. does the thing
EOF
    printf -- '- [x] 1. done\n' > "${WORK}/report.md"
    run "$SCRIPT" --spec "${WORK}/spec.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
}

@test "accepts the English Acceptance Mapping heading in strict mode" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Acceptance Criteria

1. Endpoint returns 200

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet |
| --- | --- | --- |
| 1 | `.repomethod/evidence/endpoint.log` | p1 |
EOF
    cat > "${WORK}/report.md" <<'EOF'
- [x] 1. Endpoint returns 200
EOF
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'HTTP/1.1 200 OK\n' > "${WORK}/.repomethod/evidence/endpoint.log"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 strict"* ]]
}

@test "passes when report checks off all criteria" {
    cat > "${WORK}/report.md" <<'EOF'
- [x] 1. Endpoint returns 200 — verified via curl
- [x] 2. Response body contains "ok" — verified via curl
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 2/2"* ]]
}

@test "fails when a criterion is missing from the report" {
    cat > "${WORK}/report.md" <<'EOF'
- [x] 1. Endpoint returns 200 — verified via curl
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md" --report "${WORK}/report.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING: 2"* ]]
}

@test "fails when report is missing entirely" {
    run "$SCRIPT" --spec "${WORK}/spec.md" --report "${WORK}/does-not-exist.md"
    [ "$status" -eq 1 ]
}

write_mapped_spec() {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200
2. Retry backoff caps at 5

## Akzeptanz-Mapping

| Kriterium | Test/Evidenz | Work Packet |
| --- | --- | --- |
| 1 | `.repomethod/evidence/endpoint.log` | p1 |
| 2 | `test_retry_backoff_caps` | p2 |
EOF
    cat > "${WORK}/report.md" <<'EOF'
- [x] 1. Endpoint returns 200
- [x] 2. Retry backoff caps at 5
EOF
    mkdir -p "${WORK}/.repomethod/evidence"
}

@test "strict: passes when the mapped evidence file exists and the mapped test id appears in evidence" {
    write_mapped_spec
    printf 'HTTP/1.1 200 OK\n' > "${WORK}/.repomethod/evidence/endpoint.log"
    printf 'tests/test_client.py::test_retry_backoff_caps PASSED\n' > "${WORK}/.repomethod/evidence/pytest.log"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 2/2"* ]]
}

@test "strict: fails when the mapped evidence file is absent" {
    write_mapped_spec
    printf 'test_retry_backoff_caps PASSED\n' > "${WORK}/.repomethod/evidence/pytest.log"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-MISSING: 1"* ]]
}

@test "strict: fails when the mapped test id is nowhere in evidence" {
    write_mapped_spec
    printf 'HTTP/1.1 200 OK\n' > "${WORK}/.repomethod/evidence/endpoint.log"
    printf 'some other unrelated log line\n' > "${WORK}/.repomethod/evidence/pytest.log"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-MISSING: 2"* ]]
}

@test "a strict test-id token found only in plan.md does not satisfy the check" {
    write_mapped_spec
    printf 'HTTP/1.1 200 OK\n' > "${WORK}/.repomethod/evidence/endpoint.log"
    # the token appears ONLY in the agent's own planning artifact, not in any
    # real test output — this must not be treated as evidence.
    printf 'plan: run test_retry_backoff_caps to close criterion 2\n' \
        > "${WORK}/.repomethod/evidence/plan.md"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-MISSING: 2"* ]]

    # regression: the same token in a normal evidence log still passes
    printf 'tests/test_client.py::test_retry_backoff_caps PASSED\n' \
        > "${WORK}/.repomethod/evidence/pytest.log"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 2/2"* ]]
}

# --- containment: a mapped evidence path may not leave .repomethod/evidence/ -

write_containment_spec() {
    # $1 = the token to drop into the mapping's Test/Evidence cell
    cat > "${WORK}/spec.md" <<EOF
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200

## Akzeptanz-Mapping

| Kriterium | Test/Evidenz | Work Packet |
| --- | --- | --- |
| 1 | \`$1\` | p1 |
EOF
    printf -- '- [x] 1. Endpoint returns 200\n' > "${WORK}/report.md"
}

@test "strict: a traversal evidence path is refused" {
    mkdir -p "${WORK}/.repomethod/evidence"
    echo "not evidence" > "${WORK}/README.md"
    write_containment_spec ".repomethod/evidence/../../README.md"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a leaf symlink in the evidence directory is refused" {
    mkdir -p "${WORK}/.repomethod/evidence"
    echo "outside" > "${WORK}/outside.txt"
    ln -s "${WORK}/outside.txt" "${WORK}/.repomethod/evidence/leaf.txt"
    write_containment_spec ".repomethod/evidence/leaf.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a symlinked parent inside the evidence directory is refused" {
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/elsewhere"
    echo "outside" > "${WORK}/elsewhere/a.txt"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod/evidence/sub"
    write_containment_spec ".repomethod/evidence/sub/a.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a symlinked evidence root is refused" {
    mkdir -p "${WORK}/.repomethod" "${WORK}/elsewhere"
    echo "outside" > "${WORK}/elsewhere/a.txt"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod/evidence"
    write_containment_spec ".repomethod/evidence/a.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a symlinked .repomethod root is refused" {
    mkdir -p "${WORK}/elsewhere/evidence"
    echo "outside" > "${WORK}/elsewhere/evidence/a.txt"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod"
    write_containment_spec ".repomethod/evidence/a.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a symlinked .repomethod root is refused for a test-id token too" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200

## Akzeptanz-Mapping

| Kriterium | Test/Evidenz | Work Packet |
| --- | --- | --- |
| 1 | `test_only_outside` | p1 |
EOF
    printf -- '- [x] 1. Endpoint returns 200\n' > "${WORK}/report.md"
    mkdir -p "${WORK}/elsewhere/evidence"
    printf 'test_only_outside PASSED\n' > "${WORK}/elsewhere/evidence/log.txt"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"STRICT-REJECTED"* ]]
}

@test "strict: a real in-repo test-id token still passes with the same spec" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200

## Akzeptanz-Mapping

| Kriterium | Test/Evidenz | Work Packet |
| --- | --- | --- |
| 1 | `test_only_outside` | p1 |
EOF
    printf -- '- [x] 1. Endpoint returns 200\n' > "${WORK}/report.md"
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'test_only_outside PASSED\n' > "${WORK}/.repomethod/evidence/log.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 1/1"* ]]
}

@test "strict: a real nested evidence file still passes" {
    mkdir -p "${WORK}/.repomethod/evidence/sub"
    printf 'data\n' > "${WORK}/.repomethod/evidence/sub/a.txt"
    write_containment_spec ".repomethod/evidence/sub/a.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 strict"* ]]
}

@test "strict: a test id matching an early file among many is found" {
    write_mapped_spec
    printf 'HTTP/1.1 200 OK\n' > "${WORK}/.repomethod/evidence/endpoint.log"
    printf 'tests/test_client.py::test_retry_backoff_caps PASSED\n' \
        > "${WORK}/.repomethod/evidence/aaa-early.log"
    for i in $(seq 1 300); do
        printf 'unrelated log line %s\n' "$i" > "${WORK}/.repomethod/evidence/z${i}.log"
    done
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --report report.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 2/2"* ]]
}

@test "strict: a placeholder token in angle brackets is treated as non-strict" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Akzeptanzkriterien

1. Endpoint returns 200
2. Response body contains "ok"

## Akzeptanz-Mapping

| Kriterium | Test/Evidenz | Work Packet |
| --- | --- | --- |
| 1 | `<exakter Test oder Evidenzpfad>` | `<packet-id>` |
EOF
    cat > "${WORK}/report.md" <<'EOF'
- [x] 1. Endpoint returns 200
- [x] 2. Response body contains "ok"
EOF
    run "$SCRIPT" --spec "${WORK}/spec.md" --report "${WORK}/report.md"
    [ "$status" -eq 0 ]
}
