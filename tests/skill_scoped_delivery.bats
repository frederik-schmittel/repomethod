setup() {
    load 'test_helper/common-setup'
    _common_setup
    SKILL_DIR="${REPO_ROOT}/blueprint/.repomethod/skills/scoped-delivery"
    VALIDATOR="${SKILL_DIR}/scripts/validate-packet.sh"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

write_packet() {
    local budget="$1"
    cat > "${WORK}/packet.md" <<EOF
# Work Packet: contract-client

## Objective

Generate the client transport from the approved contract.

## Dependencies

- plan-contracts

## Context Pack

- specs/example.md
- packages/contracts/openapi.json

## Scope

- packages/contracts/src/client/**

## Inputs

- Approved OpenAPI contract

## Outputs

- Generated transport

## Tests

- pnpm test

## Execution Budget

- Context: fresh
- Model class: implementation
- Maximum tokens: ${budget}

## Stop Conditions

- Required interface differs from the approved plan

## Handoff

- Record changes, tests, deviations, and remaining work
EOF
}

@test "scoped-delivery skill and validator exist with valid frontmatter" {
    [ -f "${SKILL_DIR}/SKILL.md" ]
    [ -x "$VALIDATOR" ]
    run grep -c '^name: scoped-delivery$' "${SKILL_DIR}/SKILL.md"
    [ "$output" -eq 1 ]
    run grep -c '^description: Use when' "${SKILL_DIR}/SKILL.md"
    [ "$output" -eq 1 ]
}

@test "all three delivery modes have canonical shared skills" {
    for skill in quick-mvp classic-loop graph-delivery; do
        skill_file="${REPO_ROOT}/blueprint/.repomethod/skills/${skill}/SKILL.md"
        [ -f "$skill_file" ]
        run grep -c "^name: ${skill}$" "$skill_file"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]
        run grep -c '^description:' "$skill_file"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]
    done
}

@test "Claude points to canonical rules without a separate process preference" {
    claude="${REPO_ROOT}/blueprint/CLAUDE.md"
    # The canonical contract now lives in .repomethod/AGENTS.md; the staged
    # CLAUDE.md gets a marker-block pointer to it (see lib/pointer.sh /
    # lib/blueprint.sh). The source stub itself must not establish a
    # competing process preference.
    [ -f "${REPO_ROOT}/blueprint/.repomethod/AGENTS.md" ]
    run grep -Ei "prefer superpowers|superpowers.*over" "$claude"
    [ "$status" -ne 0 ]
}

@test "canonical instructions expose exactly Quick MVP Classic and Graph" {
    agents="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    run grep -F ".repomethod/scripts/feature-workflow.sh quick-mvp" "$agents"
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/scripts/feature-workflow.sh classic init" "$agents"
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/scripts/feature-workflow.sh graph init" "$agents"
    [ "$status" -eq 0 ]
    run grep -F "graph-lean" "$agents"
    [ "$status" -ne 0 ]
    run grep -F "pixel perfection" "$agents"
    [ "$status" -ne 0 ]
    run grep -F "Platform and Console" "$agents"
    [ "$status" -ne 0 ]
}

@test "implementation packet template declares fresh context and a declared token budget" {
    template="${REPO_ROOT}/blueprint/.repomethod/templates/spec-packet.md"
    [ -f "$template" ]
    run grep -cE '^- Maximum tokens: ' "$template"
    [ "$output" -eq 1 ]
    run grep -F '200000' "$template"
    [ "$status" -ne 0 ]
    run grep -c 'Context: fresh' "$template"
    [ "$output" -eq 1 ]
}

@test "spec template offers the optional integration-gate sections" {
    template="${REPO_ROOT}/blueprint/.repomethod/templates/spec.md"
    run grep -c '^## Test Count Command$' "$template"
    [ "$output" -eq 1 ]
    run grep -c '^## Integration Invariants$' "$template"
    [ "$output" -eq 1 ]
}

@test "AGENTS.md states that done requires a fresh handoff" {
    agents="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    run grep -F "fresh handoff" "$agents"
    [ "$status" -eq 0 ]
    run grep -F "verify-invariants" "$agents"
    [ "$status" -eq 0 ]
}

@test "plan template explicitly exempts planning but requires bounded implementation packets" {
    template="${REPO_ROOT}/blueprint/.repomethod/templates/plan.md"
    [ -f "$template" ]
    run grep -c "Planning context is not subject to the implementation packets" "$template"
    [ "$output" -eq 1 ]
    run grep -F '200000' "$template"
    [ "$status" -ne 0 ]
    run grep -c '.repomethod/templates/spec-packet.md' "$template"
    [ "$output" -ge 1 ]
}

@test "validator accepts any positive declared token budget, however large" {
    write_packet 5000000
    run "$VALIDATOR" "${WORK}/packet.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"valid implementation packet"* ]]
}

@test "validator rejects a non-positive declared token budget" {
    write_packet 0
    run "$VALIDATOR" "${WORK}/packet.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be positive"* ]]
}

@test "validator does not impose a token ceiling of its own" {
    run grep -Fi "hard ceiling" "$VALIDATOR"
    [ "$status" -ne 0 ]
    run grep -F "200000" "$VALIDATOR"
    [ "$status" -ne 0 ]
}

@test "validator rejects a packet that omits its handoff contract" {
    write_packet 40000
    sed '/^## Handoff$/,$d' "${WORK}/packet.md" > "${WORK}/incomplete.md"
    run "$VALIDATOR" "${WORK}/incomplete.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing required section: Handoff"* ]]
}
