setup() {
    load 'test_helper/common-setup'
    _common_setup
    GRAPH="${REPO_ROOT}/blueprint/.repomethod/scripts/workflow-graph.sh"
    PLAN="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-obligations.sh"
    CONFORMANCE="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-conformance.sh"
    SUP="${REPO_ROOT}/blueprint/.repomethod/scripts/supervisor.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/src" "${WORK}/specs" "${WORK}/.repomethod/templates" \
        "${WORK}/.repomethod/workflows" "${WORK}/.repomethod/evidence"
    printf 'base\n' > "${WORK}/src/app.txt"
    git -C "$WORK" add src/app.txt
    git -C "$WORK" commit -q -m base
    BASE="$(git -C "$WORK" rev-parse HEAD)"
    cp "${REPO_ROOT}/blueprint/.repomethod/templates/plan-conformance-rubric.md" \
        "${WORK}/.repomethod/templates/plan-conformance-rubric.md"
    STATE="${WORK}/.repomethod/workflows/demo.json"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    cat > "${WORK}/specs/demo.md" <<'SPEC'
# Task: demo

## Scope

- `src/**`

## Plan Obligations

- `shape` [shape] The implementation keeps the required file shape.
- `behaviour` [behaviour] The implementation delivers the requested behavior.

## Acceptance Criteria

1. Shape is delivered.
2. Behavior is delivered.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | shape-check | main | `obl.shape` |
| 2 | behaviour-check | main | `obl.behaviour` |
SPEC
}

approve_obligations() {
    "$PLAN" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$PLAN" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text reviewed >/dev/null
}

complete_node() {
    local node="$1" evidence="${WORK}/.repomethod/evidence/${node}.txt"
    printf '%s\n' "$node" > "$evidence"
    "$GRAPH" start --state "$STATE" --node "$node" >/dev/null
    "$GRAPH" complete --state "$STATE" --node "$node" --output "$evidence" --evidence "$evidence" >/dev/null
}

activate_graph() {
    write_spec
    approve_obligations
    ( cd "$WORK" && "$GRAPH" init --feature demo --state "$STATE" --base "$BASE" --verify-command true >/dev/null )
    complete_node research
    complete_node plan
    revision="$(jq -r '.design_revision' "$STATE")"
    printf 'approved\n' > "${WORK}/.repomethod/evidence/approval.txt"
    "$GRAPH" approve-graph --state "$STATE" --revision "$revision" \
        --evidence "${WORK}/.repomethod/evidence/approval.txt" >/dev/null
    printf 'feature\n' >> "${WORK}/src/app.txt"
    complete_node implementation
    "$GRAPH" verify --state "$STATE" --node verification \
        --evidence "${WORK}/.repomethod/evidence/verification.txt" >/dev/null
}

write_pass_verdict() {
    local file="$1"
    cat > "$file" <<'JSON'
{"schema_version":1,"overall":"pass","table":[{"plan_ref":"obl.shape","type":"shape","status":"pass","rationale":"required shape is present in the reviewed diff"},{"plan_ref":"obl.behaviour","type":"behaviour","status":"pass","rationale":"requested behavior is implemented and verified"}],"blockers":[]}
JSON
}

pass_conformance() {
    local node="${1:-plan-conformance}" verdict="${WORK}/.repomethod/evidence/reviewer-${1:-plan-conformance}.json"
    "$GRAPH" start --state "$STATE" --node "$node" >/dev/null
    write_pass_verdict "$verdict"
    "$GRAPH" conform --state "$STATE" --node "$node" --verdict "$verdict" >/dev/null
}

@test "Graph requires plan-conformance between verification and completion and dispatches it fresh" {
    activate_graph
    [ "$(jq -r '.nodes[] | select(.id == "plan-conformance") | .dependencies | join(",")' "$STATE")" = "verification" ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .dependencies | join(",")' "$STATE")" = "plan-conformance" ]

    run "$GRAPH" dispatch --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.runnable[0].node_id' <<< "$output")" = "plan-conformance" ]
    [ "$(jq -r '.runnable[0].fresh_context_required' <<< "$output")" = "true" ]

    printf 'done\n' > "${WORK}/.repomethod/evidence/done.txt"
    run "$GRAPH" complete --state "$STATE" --node completion \
        --output "${WORK}/.repomethod/evidence/done.txt" --evidence "${WORK}/.repomethod/evidence/done.txt"
    [ "$status" -ne 0 ]
}

@test "conformance context is pinned to base and a passing verdict becomes stale after source changes" {
    activate_graph
    run "$GRAPH" start --state "$STATE" --node plan-conformance
    [ "$status" -eq 0 ]
    context="${WORK}/$(jq -r '.context' <<< "$output")"
    [ "$(jq -r '.snapshot.base_ref' "$context")" = "$BASE" ]
    [ "$(jq -r '.approved_plan.revision' "$context")" = "$(jq -r '.design_revision' "$STATE")" ]
    grep -Fq '+feature' "${WORK}/$(jq -r '.authorities.full_feature_diff' "$context")"

    write_pass_verdict "${WORK}/.repomethod/evidence/reviewer.json"
    "$GRAPH" conform --state "$STATE" --node plan-conformance \
        --verdict "${WORK}/.repomethod/evidence/reviewer.json" >/dev/null
    run "$CONFORMANCE" check --state "$STATE"
    [ "$status" -eq 0 ]

    printf 'after-verdict\n' >> "${WORK}/src/app.txt"
    run "$CONFORMANCE" check --state "$STATE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
}

@test "unreviewed descopes prevent a passing conformance verdict" {
    activate_graph
    "${REPO_ROOT}/blueprint/.repomethod/scripts/descope-ledger.sh" add --state "$STATE" \
        --id descope.behaviour --plan-ref obl.behaviour --description omitted \
        --rationale pending --owner test >/dev/null
    "$GRAPH" start --state "$STATE" --node plan-conformance >/dev/null
    write_pass_verdict "${WORK}/.repomethod/evidence/reviewer.json"

    run "$GRAPH" conform --state "$STATE" --node plan-conformance \
        --verdict "${WORK}/.repomethod/evidence/reviewer.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"descopes prevent"* ]]
}

@test "blocked conformance creates numbered fix re-verification and fresh conformance retry" {
    activate_graph
    "$GRAPH" start --state "$STATE" --node plan-conformance >/dev/null
    cat > "${WORK}/.repomethod/evidence/blocked.json" <<'JSON'
{"schema_version":1,"overall":"blocked","table":[{"plan_ref":"obl.shape","type":"shape","status":"pass","rationale":"shape is present"},{"plan_ref":"obl.behaviour","type":"behaviour","status":"fail","rationale":"behavior drifts from the approved plan"}],"blockers":[{"id":"blocker.behaviour","category":"behaviour","plan_ref":"obl.behaviour","message":"correct the behavior"}]}
JSON
    run "$GRAPH" conform --state "$STATE" --node plan-conformance \
        --verdict "${WORK}/.repomethod/evidence/blocked.json"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.conformance_retry_count' "$STATE")" = "1" ]
    [ "$(jq -r '.nodes[] | select(.id == "conformance-fix-1") | .dependencies[0]' "$STATE")" = "plan-conformance" ]
    [ "$(jq -r '.nodes[] | select(.id == "conformance-verification-1") | .dependencies[0]' "$STATE")" = "conformance-fix-1" ]
    [ "$(jq -r '.nodes[] | select(.id == "plan-conformance-1") | .dependencies[0]' "$STATE")" = "conformance-verification-1" ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .dependencies[0]' "$STATE")" = "plan-conformance-1" ]
}

@test "current successful conformance unlocks completion and is stored in handoff" {
    activate_graph
    pass_conformance plan-conformance
    printf 'done\n' > "${WORK}/.repomethod/evidence/done.txt"
    "$GRAPH" complete --state "$STATE" --node completion \
        --output "${WORK}/.repomethod/evidence/done.txt" --evidence "${WORK}/.repomethod/evidence/done.txt" >/dev/null
    "$GRAPH" handoff --state "$STATE" --node completion --changed src/app.txt --next none --claim complete >/dev/null
    handoff="${WORK}/.repomethod/workflows/demo.handoff.json"
    [ "$(jq -r '.plan_conformance.status' "$handoff")" = "passed" ]
    [ "$(jq -r '.workflow_status' "$handoff")" = "completed" ]
}

@test "supervisor counts plan-obligation approval as progress without relying on supervisor rewrites" {
    write_spec
    "$PLAN" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    ( cd "$WORK" && "$GRAPH" init --feature demo --state "$STATE" --base "$BASE" --verify-command true >/dev/null )

    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$status" -eq 10 ]
    [ "$(jq -r '.idle_runs' <<< "$output")" = "0" ]

    "$PLAN" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text reviewed >/dev/null
    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$status" -eq 10 ]
    [ "$(jq -r '.progress' <<< "$output")" = "true" ]
    [ "$(jq -r '.idle_runs' <<< "$output")" = "0" ]
}

@test "supervisor counts conformance state changes as progress without self-triggered progress" {
    activate_graph

    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$status" -eq 10 ]
    [ "$(jq -r '.idle_runs' <<< "$output")" = "0" ]

    pass_conformance plan-conformance
    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$status" -eq 10 ]
    [ "$(jq -r '.progress' <<< "$output")" = "true" ]
    [ "$(jq -r '.idle_runs' <<< "$output")" = "0" ]

    run "$SUP" check --state "$STATE" --max-idle-runs 2
    [ "$status" -eq 10 ]
    [ "$(jq -r '.progress' <<< "$output")" = "false" ]
}

@test "Classic remains free of plan-conformance nodes and conformance is not applicable" {
    write_spec
    cstate="${WORK}/.repomethod/workflows/classic.json"
    ( cd "$WORK" && "$GRAPH" init --feature classic --mode classic --state "$cstate" \
        --base "$BASE" --verify-command true >/dev/null )
    [ "$(jq '[.nodes[] | select(.type == "plan-conformance")] | length' "$cstate")" -eq 0 ]

    run "$CONFORMANCE" status --state "$cstate"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.required' <<< "$output")" = "false" ]
    [ "$(jq -r '.status' <<< "$output")" = "not_applicable" ]
}
