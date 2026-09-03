setup() {
    bats_require_minimum_version 1.5.0
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/intent-lineage.sh"
    TEMPLATE="${REPO_ROOT}/blueprint/.repomethod/templates/intent.md"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "$WORK/intents" "$WORK/specs" "$WORK/custom"
}

teardown() { rm -rf -- "$WORK"; }

write_intent() {
    cat > "$WORK/intents/demo.md" <<'EOF_INTENT'
# Intent: durable lineage

## Problem

Purpose is lost between sessions.

## Desired Outcome

A reviewer can recover the original purpose.

## Affected Users / Systems

Coding agents and reviewers.

## Constraints

Repository-native and deterministic.

## Non-Goals

No external tracker.

## Open Questions

None.

## Provenance / Source

GitHub issue #14.
EOF_INTENT
}

write_bound_spec() {
    local binding="$1"
    cat > "$WORK/specs/demo.md" <<EOF_SPEC
# Task: demo

## Source Intent

\`\`\`json
${binding}
\`\`\`

## Scope

- \`src/**\`
EOF_SPEC
}

@test "intent template stays deliberately small and pin emits canonical identity" {
    for heading in '## Problem' '## Desired Outcome' '## Affected Users / Systems' \
        '## Constraints' '## Non-Goals' '## Open Questions' '## Provenance / Source'; do
        grep -Fxq -- "$heading" "$TEMPLATE"
    done
    ! grep -Eq '^## (Plan|Acceptance Criteria|Work Packets|Implementation)' "$TEMPLATE"

    write_intent
    run "$SCRIPT" pin --intent "$WORK/intents/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [ "$output" = "$(jq -cS . <<< "$output")" ]
    [ "$(jq -r '.schema_version' <<< "$output")" = 1 ]
    [ "$(jq -r '.path' <<< "$output")" = intents/demo.md ]
    [ "$(jq -r '.sha256 | length' <<< "$output")" = 64 ]
}

@test "valid source intent checks and specs without lineage stay backward compatible" {
    write_intent
    binding="$($SCRIPT pin --intent "$WORK/intents/demo.md" --repo "$WORK")"
    write_bound_spec "$binding"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [ "$output" = "$binding" ]

    printf '# Task\n\n## Scope\n\n- `src/**`\n' > "$WORK/custom/Legacy Feature.md"
    run "$SCRIPT" check --spec "$WORK/custom/Legacy Feature.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]
}

@test "comment-only Source Intent section remains an opt-in no-op" {
    cat > "$WORK/custom/Legacy Feature.md" <<'EOF_SPEC'
# Task

## Source Intent

<!-- Optional lineage instructions only. -->

## Scope
EOF_SPEC
    run "$SCRIPT" check --spec "$WORK/custom/Legacy Feature.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]
}

@test "malformed headings and non-canonical or malformed bindings fail closed" {
    printf '# Task\n\n### Source Intent\n' > "$WORK/custom/demo.md"
    run "$SCRIPT" check --spec "$WORK/custom/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Source Intent heading"* ]]

    write_intent
    digest="$($SCRIPT pin --intent "$WORK/intents/demo.md" --repo "$WORK" | jq -r .sha256)"
    write_bound_spec "{\"schema_version\":1,\"path\":\"intents/demo.md\",\"sha256\":\"$digest\"}"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not canonical JSON"* ]]

    write_bound_spec "$(jq -cnS --arg path intents/demo.md --arg sha256 "$digest" '{schema_version:1,path:$path,sha256:$sha256,extra:true}')"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid shape"* ]]
}

@test "missing substituted and stale intent references fail closed" {
    write_intent
    binding="$($SCRIPT pin --intent "$WORK/intents/demo.md" --repo "$WORK")"
    write_bound_spec "$binding"
    rm "$WORK/intents/demo.md"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"intent not found"* ]]

    write_intent
    other_sha="0000000000000000000000000000000000000000000000000000000000000000"
    write_bound_spec "$(jq -cnS --arg path intents/other.md --arg sha256 "$other_sha" '{schema_version:1,path:$path,sha256:$sha256}')"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path substitution"* ]]

    binding="$($SCRIPT pin --intent "$WORK/intents/demo.md" --repo "$WORK")"
    write_bound_spec "$binding"
    printf '\nchanged\n' >> "$WORK/intents/demo.md"
    run "$SCRIPT" check --spec "$WORK/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stale source intent identity"* ]]
}

@test "intent path symlinks are rejected" {
    write_intent
    cp "$WORK/intents/demo.md" "$WORK/real.md"
    rm "$WORK/intents/demo.md"
    ln -s ../real.md "$WORK/intents/demo.md"
    run "$SCRIPT" pin --intent "$WORK/intents/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]
}

@test "full gate invokes canonical intent checker while Quick never requires it" {
    bin="$WORK/bin"
    mkdir -p "$bin" "$WORK/.repomethod/evidence"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts/agent-gate.sh" "$bin/agent-gate.sh"
    chmod +x "$bin/agent-gate.sh"

    for name in preflight verify verify-scope verify-forbidden plan-obligations verify-provenance verify-contracts verify-acceptance verify-evidence verify-report verify-invariants; do
        cat > "$bin/${name}.sh" <<'EOF_STUB'
#!/usr/bin/env bash
exit 0
EOF_STUB
        chmod +x "$bin/${name}.sh"
    done
    printf 'quick evidence\n' > "$WORK/.repomethod/evidence/report.md"

    # No intent-lineage.sh exists in the fixture. Quick must still succeed,
    # proving the new full-gate dependency is unreachable from Quick MVP.
    run bash -c "cd '$WORK' && '$bin/agent-gate.sh' --quick --base HEAD --report .repomethod/evidence/report.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"quick gate passed"* ]]

    cat > "$bin/intent-lineage.sh" <<'EOF_INTENT_STUB'
#!/usr/bin/env bash
printf 'intent-called:%s\n' "$*"
exit 23
EOF_INTENT_STUB
    chmod +x "$bin/intent-lineage.sh"
    run bash -c "cd '$WORK' && '$bin/agent-gate.sh' --spec specs/demo.md --base HEAD"
    [ "$status" -eq 23 ]
    [[ "$output" == *"intent-called:check --spec specs/demo.md --repo ."* ]]
}
