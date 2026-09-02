setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPTS="${REPO_ROOT}/blueprint/.repomethod/scripts"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/.repomethod" "${WORK}/specs"
    cp "${SCRIPTS}"/*.sh "${WORK}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    chmod +x "${WORK}/.repomethod/scripts"/*.sh
}

teardown() {
    rm -rf -- "$WORK"
}

@test "agent-gate.sh requires --spec and fails closed with no default" {
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --base main \
        --report "${WORK}/.repomethod/evidence/report.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--spec is required"* ]]
}

@test "agent-gate.sh no longer accepts --evidence-dir" {
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md \
        --evidence-dir "${WORK}/.repomethod/evidence"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag: --evidence-dir"* ]]
}

@test "an ambient SPEC in the environment does not satisfy the gate" {
    run env SPEC="${WORK}/specs/my-feature.md" bash "${WORK}/.repomethod/scripts/agent-gate.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--spec is required"* ]]
}

@test "agent-gate.sh's defaults resolve without --base, --report, or --evidence-dir" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence"
    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: defaults

## Scope

- `src/**`

## Acceptance Criteria

1. it works

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for my-feature.md
- [x] 1. done
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"
    cd "$WORK" && git init -q -b main && git config user.email t@e.x && git config user.name T \
        && git add -A && git commit -q -m init
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"all gates passed"* ]]
}

@test "agent-gate.sh --spec with no --base on a non-main fork base has no false-positive scope violation" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/src"
    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: stacked base

## Scope

- `src/**`

## Acceptance Criteria

1. it works

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for my-feature.md
- [x] 1. done
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    git add -A && git commit -q -m init
    git checkout -q -b feature-base
    echo x > feature-base-file.txt
    git add -A && git commit -q -m "feature base file"
    git checkout -q -b work
    git config branch.work.remote .
    git config branch.work.merge refs/heads/feature-base
    echo impl > src/app.txt
    git add -A && git commit -q -m "in-scope work"
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"all gates passed"* ]]
    [[ "$output" != *"VIOLATION"* ]]
}

@test "agent-gate.sh fails explicitly when no verify-command is configured, given an explicit spec" {
    cp "${REPO_ROOT}/blueprint/.repomethod/templates/spec.md" "${WORK}/specs/my-feature.md"
    cd "$WORK"
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md --base main \
        --report "${WORK}/.repomethod/evidence/report.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *".repomethod/verify-command missing"* ]]
}

@test "agent gate quiet preflight aborts before every gate" {
    # Both --spec and --quick run preflight.sh --quiet right after argument
    # validation; a hard finding aborts before the gate itself.
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    git commit -q --allow-empty -m init
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'note\n' > "${WORK}/.repomethod/evidence/report.md"
    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: x

## Scope

- `src/**`

## Acceptance Criteria

1. it works

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    # no .repomethod/verify-command -> a hard preflight finding

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md --base HEAD
    [ "$status" -ne 0 ]
    [[ "$output" == *".repomethod/verify-command missing"* ]]
    [[ "$output" != *"all gates passed"* ]]

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -ne 0 ]
    [[ "$output" == *".repomethod/verify-command missing"* ]]
    [[ "$output" != *"quick gate passed"* ]]
}

@test "agent-gate.sh runs every gate in order and reports success" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence"

    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: agent-gate smoke

## Scope

- `src/**`

## Akzeptanzkriterien

1. erste Bedingung
2. zweite Bedingung

## Erwartete Evidenz

- `.repomethod/evidence/proof.txt`
EOF

    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for my-feature.md
- [x] 1. erledigt
- [x] 2. erledigt
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"

    cd "$WORK" && git init -q && git config user.email t@e.x && git config user.name T \
        && git add -A && git commit -q -m init

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md --base HEAD \
        --report "${WORK}/.repomethod/evidence/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[agent-gate] all gates passed"* ]]
}

@test "verify.sh propagates the configured command's exact exit status" {
    printf 'exit 3\n' > "${WORK}/.repomethod/verify-command"
    run "${WORK}/.repomethod/scripts/verify.sh" "$WORK"
    [ "$status" -eq 3 ]
}

quick_repo() {
    cd "$WORK" && git init -q && git config user.email t@e.x && git config user.name T \
        && git add -A && git commit -q -m init
}

@test "agent-gate.sh --quick passes with a green command, an evidence note, and a clean scope" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'Built X. Verified: make test (green).\n' > "${WORK}/.repomethod/evidence/report.md"
    quick_repo
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"quick gate passed"* ]]
    [[ "$output" != *"--spec is required"* ]]
}

@test "agent-gate.sh --quick fails when the evidence report is missing or empty" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    quick_repo
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -ne 0 ]
    [[ "$output" == *"evidence report"* ]]
}

@test "agent-gate.sh --quick fails when the configured command is red" {
    printf 'exit 1\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'note\n' > "${WORK}/.repomethod/evidence/report.md"
    quick_repo
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -ne 0 ]
}

@test "agent-gate.sh --quick fails when a protected zone was touched" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/infra"
    printf 'note\n' > "${WORK}/.repomethod/evidence/report.md"
    quick_repo
    echo "x" > "${WORK}/infra/x.tf"
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -ne 0 ]
    [[ "$output" == *"VIOLATION"* ]]
}

@test "agent gate forwards state base_ref without a base flag" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/.repomethod/workflows" "${WORK}/src"
    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: pinned base

## Scope

- `src/**`

## Acceptance Criteria

1. it works

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for my-feature.md
- [x] 1. done
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    git add -A && git commit -q -m A
    git checkout -q -b feature-base
    echo out > out-of-scope.txt
    git add -A && git commit -q -m B
    b="$(git rev-parse HEAD)"
    git symbolic-ref refs/remotes/origin/HEAD refs/heads/feature-base
    git checkout -q -b work
    echo impl > src/app.txt
    git add -A && git commit -q -m C
    printf '{"config":{"base_ref":"%s"}}\n' "$b" > .repomethod/workflows/wf.json
    # drop origin/HEAD so a re-resolution would fall back to main (A) and drag
    # out-of-scope.txt into the diff. The forwarded pinned base_ref (B) does not.
    git symbolic-ref -d refs/remotes/origin/HEAD

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md --state .repomethod/workflows/wf.json
    [ "$status" -eq 0 ]
    [[ "$output" == *"all gates passed"* ]]
    [[ "$output" != *"VIOLATION"* ]]
    [[ "$output" != *"out-of-scope.txt"* ]]
}

@test "quick gate rejects state" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence"
    printf 'note\n' > "${WORK}/.repomethod/evidence/report.md"
    quick_repo
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD --state "${WORK}/x.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--state is only valid with --spec"* ]]
}

@test "coverage warning text and exit status match at init and spec gate" {
    local warning_text="WARN: change touches frontend files but verify-command runs no JS check"
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/.repomethod/workflows" "${WORK}/src"
    cat > "${WORK}/specs/my-feature.md" <<'EOF'
# Task: frontend warning

## Scope

- `src/**`
- `.repomethod/verify-command`

## Acceptance Criteria

1. frontend change is verified

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    cat > "${WORK}/.repomethod/evidence/report.md" <<'EOF'
Report for my-feature.md
- [x] 1. frontend change is verified
EOF
    printf 'evidence\n' > "${WORK}/.repomethod/evidence/proof.txt"
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    git add -A && git commit -q -m baseline
    echo 'export const x = 1' > src/app.tsx
    git add src/app.tsx

    run "${WORK}/.repomethod/scripts/feature-workflow.sh" classic init \
        --feature demo --state "${WORK}/.repomethod/workflows/demo.json" --base HEAD --verify-command true
    local init_status="$status"
    local init_warning
    init_warning="$(printf '%s\n' "$output" | grep -Fx "$warning_text")"
    [ "$init_status" -eq 0 ]
    [ "$init_warning" = "$warning_text" ]

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md \
        --base HEAD --report "${WORK}/.repomethod/evidence/report.md"
    local gate_status="$status"
    local gate_warning
    gate_warning="$(printf '%s\n' "$output" | grep -Fx "$warning_text")"
    [ "$gate_status" -eq "$init_status" ]
    [ "$gate_warning" = "$init_warning" ]

    printf 'echo pnpm test\n' > "${WORK}/.repomethod/verify-command"
    run "${WORK}/.repomethod/scripts/agent-gate.sh" --spec specs/my-feature.md \
        --base HEAD --report "${WORK}/.repomethod/evidence/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$warning_text"* ]]
}

@test "quick gate does not emit the frontend coverage warning" {
    local warning_text="WARN: change touches frontend files but verify-command runs no JS check"
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    mkdir -p "${WORK}/.repomethod/evidence" "${WORK}/src"
    printf 'frontend quick change\n' > "${WORK}/.repomethod/evidence/report.md"
    cd "$WORK"
    git init -q -b main && git config user.email t@e.x && git config user.name T
    git add -A && git commit -q -m baseline
    echo 'export const x = 1' > src/app.tsx
    git add src/app.tsx

    run "${WORK}/.repomethod/scripts/agent-gate.sh" --quick --base HEAD
    [ "$status" -eq 0 ]
    [[ "$output" != *"$warning_text"* ]]
}

@test "canonical AGENTS.md documents the quick-mvp close-out" {
    run grep -F "agent-gate.sh --quick" "${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    [ "$status" -eq 0 ]
}
