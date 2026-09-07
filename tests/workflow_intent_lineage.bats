setup() {
    bats_require_minimum_version 1.5.0
    load 'test_helper/common-setup'
    _common_setup
    LINEAGE="${REPO_ROOT}/blueprint/.repomethod/scripts/intent-lineage.sh"
    FEATURE="${REPO_ROOT}/blueprint/.repomethod/scripts/feature-workflow.sh"
    GRAPH="${REPO_ROOT}/blueprint/.repomethod/scripts/workflow-graph.sh"
    AGENT_GATE="${REPO_ROOT}/blueprint/.repomethod/scripts/agent-gate.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "$WORK/intents" "$WORK/specs" "$WORK/.repomethod/evidence"
    printf 'true\n' > "$WORK/.repomethod/verify-command"
}

teardown() {
    rm -rf -- "$WORK" "${FRESH:-}"
}

write_intent() {
    local feature="$1"
    cat > "$WORK/intents/${feature}.md" <<EOF_INTENT
# Intent: durable ${feature} lineage

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
    local feature="$1" binding="$2"
    cat > "$WORK/specs/${feature}.md" <<EOF_SPEC
# Task: ${feature}

## Source Intent

\`\`\`json
${binding}
\`\`\`

## Scope

- \`src/**\`
EOF_SPEC
}

write_legacy_spec() {
    local feature="$1"
    cat > "$WORK/specs/${feature}.md" <<EOF_SPEC
# Task: ${feature}

## Scope

- \`src/**\`
EOF_SPEC
}

commit_fixture() {
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m baseline
}

init_bound_feature() {
    local mode="$1" feature="$2" binding
    write_intent "$feature"
    binding="$($LINEAGE pin --intent "$WORK/intents/${feature}.md" --repo "$WORK")"
    write_bound_spec "$feature" "$binding"
    commit_fixture
    if [ "$mode" = classic ]; then
        (cd "$WORK" && "$FEATURE" classic init --feature "$feature" \
            --state ".repomethod/workflows/${feature}.json" \
            --verify-command true --base HEAD >/dev/null)
    else
        (cd "$WORK" && "$FEATURE" graph init --feature "$feature" \
            --state ".repomethod/workflows/${feature}.json" \
            --verify-command true --base HEAD --research single >/dev/null)
    fi
    printf '%s\n' "$binding"
}

@test "Classic and Graph initialization bind the canonical Source Intent into workflow state" {
    write_intent classic-demo
    classic_binding="$($LINEAGE pin --intent "$WORK/intents/classic-demo.md" --repo "$WORK")"
    write_bound_spec classic-demo "$classic_binding"

    write_intent graph-demo
    graph_binding="$($LINEAGE pin --intent "$WORK/intents/graph-demo.md" --repo "$WORK")"
    write_bound_spec graph-demo "$graph_binding"
    commit_fixture

    run bash -c "cd '$WORK' && '$FEATURE' classic init --feature classic-demo --state .repomethod/workflows/classic-demo.json --verify-command true --base HEAD"
    [ "$status" -eq 0 ]
    run jq -e --argjson binding "$classic_binding" '.intent_lineage == $binding' "$WORK/.repomethod/workflows/classic-demo.json"
    [ "$status" -eq 0 ]

    run bash -c "cd '$WORK' && '$FEATURE' graph init --feature graph-demo --state .repomethod/workflows/graph-demo.json --verify-command true --base HEAD --research single"
    [ "$status" -eq 0 ]
    run jq -e --argjson binding "$graph_binding" '.intent_lineage == $binding' "$WORK/.repomethod/workflows/graph-demo.json"
    [ "$status" -eq 0 ]
}

@test "intent-enabled initialization rejects stale or malformed lineage before workflow state exists" {
    write_intent demo
    binding="$($LINEAGE pin --intent "$WORK/intents/demo.md" --repo "$WORK")"
    write_bound_spec demo "$binding"
    commit_fixture
    printf '\nchanged after review\n' >> "$WORK/intents/demo.md"

    run bash -c "cd '$WORK' && '$FEATURE' classic init --feature demo --verify-command true --base HEAD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stale source intent identity"* ]]
    [ ! -e "$WORK/.repomethod/workflows/demo.json" ]

    git -C "$WORK" checkout -q -- intents/demo.md
    cat > "$WORK/specs/demo.md" <<'EOF_SPEC'
# Task: demo

## Source Intent

```json
{"path":"intents/demo.md","schema_version":1,"sha256":"bad"}
```
EOF_SPEC
    run bash -c "cd '$WORK' && '$FEATURE' classic init --feature demo --verify-command true --base HEAD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid shape"* ]]
    [ ! -e "$WORK/.repomethod/workflows/demo.json" ]
}

@test "a relocated fresh checkout recovers Source Intent from workflow state alone" {
    binding="$(init_bound_feature classic demo)"
    FRESH="$(mktemp -d)"
    cp -a "$WORK/." "$FRESH/"
    jq '.repo_root = "/definitely/not/the/current/checkout"' \
        "$FRESH/.repomethod/workflows/demo.json" > "$FRESH/state.tmp"
    mv "$FRESH/state.tmp" "$FRESH/.repomethod/workflows/demo.json"

    run "$LINEAGE" check --state "$FRESH/.repomethod/workflows/demo.json" --repo "$FRESH"
    [ "$status" -eq 0 ]
    [ "$output" = "$binding" ]
    [ "$(jq -r '.path' <<< "$output")" = intents/demo.md ]

    run "$GRAPH" status --state "$FRESH/.repomethod/workflows/demo.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature=demo mode=classic"* ]]
}

@test "stateful lineage fails closed on malformed binding path substitution missing artifact staleness and deletion" {
    binding="$(init_bound_feature classic demo)"
    state="$WORK/.repomethod/workflows/demo.json"
    cp "$state" "$WORK/state.clean"

    jq '.intent_lineage = "tampered"' "$WORK/state.clean" > "$state"
    run "$LINEAGE" check --state "$state" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid shape"* ]]
    run "$GRAPH" status --state "$state"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid source intent lineage"* ]]

    cp "$WORK/state.clean" "$state"
    jq '.intent_lineage.path = "intents/other.md"' "$WORK/state.clean" > "$state"
    run "$LINEAGE" check --state "$state" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path substitution"* ]]

    cp "$WORK/state.clean" "$state"
    rm "$WORK/intents/demo.md"
    run "$LINEAGE" check --state "$state" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"intent not found"* ]]

    write_intent demo
    cp "$WORK/state.clean" "$state"
    printf '\nchanged\n' >> "$WORK/intents/demo.md"
    run "$LINEAGE" check --state "$state" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stale source intent identity"* ]]

    write_intent demo
    cp "$WORK/state.clean" "$state"
    jq 'del(.intent_lineage)' "$WORK/state.clean" > "$state"
    run "$LINEAGE" check --state "$state" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing the pinned source intent binding"* ]]
    run "$GRAPH" status --state "$state"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing the pinned source intent binding"* ]]

    # Sanity: the untouched state still carries exactly the original binding.
    cp "$WORK/state.clean" "$state"
    run jq -e --argjson binding "$binding" '.intent_lineage == $binding' "$state"
    [ "$status" -eq 0 ]
}

@test "legacy Classic workflows without Source Intent stay backward compatible and Quick stays stateless" {
    write_legacy_spec legacy
    commit_fixture

    run bash -c "cd '$WORK' && '$FEATURE' classic init --feature legacy --state .repomethod/workflows/legacy.json --verify-command true --base HEAD"
    [ "$status" -eq 0 ]
    run jq -e 'has("intent_lineage") | not' "$WORK/.repomethod/workflows/legacy.json"
    [ "$status" -eq 0 ]
    run "$LINEAGE" check --state "$WORK/.repomethod/workflows/legacy.json" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]

    rm -rf "$WORK/.repomethod/workflows"
    run bash -c "cd '$WORK' && '$FEATURE' quick-mvp"
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/.repomethod/workflows" ]
}

@test "stateful agent verification forwards workflow state to the canonical lineage authority" {
    bin="$WORK/bin"
    mkdir -p "$bin" "$WORK/.repomethod/evidence"
    cp "$AGENT_GATE" "$bin/agent-gate.sh"
    chmod +x "$bin/agent-gate.sh"

    for name in preflight verify-spec-lint verify verify-scope verify-forbidden plan-obligations verify-provenance verify-contracts verify-acceptance verify-evidence verify-report verify-invariants; do
        cat > "$bin/${name}.sh" <<'EOF_STUB'
#!/usr/bin/env bash
exit 0
EOF_STUB
        chmod +x "$bin/${name}.sh"
    done
    cat > "$bin/intent-lineage.sh" <<'EOF_INTENT_STUB'
#!/usr/bin/env bash
printf 'intent-called:%s\n' "$*"
exit 23
EOF_INTENT_STUB
    chmod +x "$bin/intent-lineage.sh"
    printf '{"mode":"classic"}\n' > "$WORK/state.json"

    run bash -c "cd '$WORK' && '$bin/agent-gate.sh' --spec specs/demo.md --state state.json --base HEAD"
    [ "$status" -eq 23 ]
    [[ "$output" == *"intent-called:check --spec specs/demo.md --state state.json --repo ."* ]]
}

@test "status preview and handoff surface the bound intent and stay silent for a legacy workflow" {
    init_bound_feature classic demo >/dev/null
    state="$WORK/.repomethod/workflows/demo.json"

    run "$GRAPH" status --state "$state"
    [ "$status" -eq 0 ]
    [[ "$output" == *"intent=intents/demo.md"* ]]

    run "$GRAPH" preview --state "$state"
    [ "$status" -eq 0 ]
    [[ "$output" == *"intent=intents/demo.md"* ]]

    run "$GRAPH" handoff --state "$state" --node implementation \
        --next "review" --changed "src/x"
    [ "$status" -eq 0 ]
    run jq -e '.intent_lineage.path == "intents/demo.md" and .intent_lineage.schema_version == 1' \
        "$WORK/.repomethod/workflows/demo.handoff.json"
    [ "$status" -eq 0 ]

    write_legacy_spec legacy
    commit_fixture
    (cd "$WORK" && "$FEATURE" classic init --feature legacy \
        --state ".repomethod/workflows/legacy.json" --verify-command true --base HEAD >/dev/null)
    legacy_state="$WORK/.repomethod/workflows/legacy.json"

    run "$GRAPH" status --state "$legacy_state"
    [ "$status" -eq 0 ]
    [[ "$output" != *"intent="* ]]
    run "$GRAPH" handoff --state "$legacy_state" --node implementation \
        --next "review" --changed "src/x"
    [ "$status" -eq 0 ]
    run jq -e '.intent_lineage == null' "$WORK/.repomethod/workflows/legacy.handoff.json"
    [ "$status" -eq 0 ]
}
