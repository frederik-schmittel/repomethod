# tests/blueprint_verify_evidence.bats
setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-evidence.sh"
    WORK="$(mktemp -d)"
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Erwartete Evidenz

- `.repomethod/evidence/test-output.txt`
- `.repomethod/evidence/curl-response.txt`
EOF
    mkdir -p "${WORK}/.repomethod/evidence"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "--evidence-dir is no longer accepted" {
    cd "$WORK"
    run "$SCRIPT" --spec spec.md --evidence-dir "${WORK}/.repomethod/evidence"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag: --evidence-dir"* ]]
}

@test "accepts the English Expected Evidence heading" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Expected Evidence

- `.repomethod/evidence/test-output.txt`
EOF
    echo "data" > "${WORK}/.repomethod/evidence/test-output.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 1/1"* ]]
}

@test "passes when all evidence files exist and are non-empty" {
    echo "data" > "${WORK}/.repomethod/evidence/test-output.txt"
    echo "data" > "${WORK}/.repomethod/evidence/curl-response.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 2/2"* ]]
}

@test "fails when an evidence file is missing" {
    echo "data" > "${WORK}/.repomethod/evidence/test-output.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING: .repomethod/evidence/curl-response.txt"* ]]
}

@test "fails when an evidence file is empty" {
    echo "data" > "${WORK}/.repomethod/evidence/test-output.txt"
    : > "${WORK}/.repomethod/evidence/curl-response.txt"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING: .repomethod/evidence/curl-response.txt"* ]]
}

# --- containment: an evidence path may not leave .repomethod/evidence/ -------

@test "a traversal evidence declaration is refused" {
    echo "not evidence" > "${WORK}/README.md"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/../../README.md`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "a leaf symlink in the evidence directory is refused" {
    echo "outside" > "${WORK}/outside.txt"
    ln -s "${WORK}/outside.txt" "${WORK}/.repomethod/evidence/leaf.txt"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/leaf.txt`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "a symlinked parent inside the evidence directory is refused" {
    mkdir -p "${WORK}/elsewhere"
    echo "outside" > "${WORK}/elsewhere/a.txt"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod/evidence/sub"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/sub/a.txt`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "a symlinked evidence root is refused" {
    mkdir -p "${WORK}/elsewhere"
    echo "outside" > "${WORK}/elsewhere/a.txt"
    rm -rf "${WORK}/.repomethod/evidence"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod/evidence"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/a.txt`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "a symlinked .repomethod root is refused" {
    mkdir -p "${WORK}/elsewhere/evidence"
    echo "outside" > "${WORK}/elsewhere/evidence/a.txt"
    rm -rf "${WORK}/.repomethod"
    ln -s "${WORK}/elsewhere" "${WORK}/.repomethod"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/a.txt`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}

@test "a real nested evidence file still passes" {
    mkdir -p "${WORK}/.repomethod/evidence/sub"
    echo "data" > "${WORK}/.repomethod/evidence/sub/a.txt"
    cat > "${WORK}/spec.md" <<'EOF'
## Expected Evidence

- `.repomethod/evidence/sub/a.txt`
EOF
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 1/1"* ]]
}

@test "a traversal among many declared evidence files is still refused" {
    echo "not evidence" > "${WORK}/README.md"
    {
        echo "## Expected Evidence"
        echo
        echo '- `.repomethod/evidence/../../README.md`'
        for i in $(seq 1 200); do
            echo "data" > "${WORK}/.repomethod/evidence/f${i}.txt"
            echo "- \`.repomethod/evidence/f${i}.txt\`"
        done
    } > "${WORK}/spec.md"
    cd "$WORK"
    run "$SCRIPT" --spec spec.md
    [ "$status" -eq 1 ]
    [[ "$output" == *"REJECTED"* ]]
}
