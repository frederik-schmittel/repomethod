setup() {
    load 'test_helper/common-setup'
    _common_setup
    bats_require_minimum_version 1.5.0
    WRAPPER="${REPO_ROOT}/blueprint/.repomethod/scripts/feature-workflow.sh"
    GRAPH="${REPO_ROOT}/blueprint/.repomethod/scripts/workflow-graph.sh"
    PLAN="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-obligations.sh"
    RUBRIC="${REPO_ROOT}/blueprint/.repomethod/templates/plan-conformance-rubric.md"
    WORK="$(mktemp -d)"
    STATE="${WORK}/feature.json"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email t@e.x
    git -C "$WORK" config user.name T
    git -C "$WORK" commit -q -m init --allow-empty
    mkdir -p "${WORK}/.repomethod" "${WORK}/.repomethod/templates" \
        "${WORK}/.repomethod/workflows" "${WORK}/specs"
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    cp "$RUBRIC" "${WORK}/.repomethod/templates/plan-conformance-rubric.md"
    cd "$WORK"
}

teardown() { rm -rf -- "$WORK"; }

evidence_for() {
    local node="$1"
    mkdir -p "${WORK}/evidence" "${WORK}/outputs"
    printf 'evidence for %s\n' "$node" > "${WORK}/evidence/${node}.txt"
    printf 'output for %s\n' "$node" > "${WORK}/outputs/${node}.md"
}

complete_node() {
    local node="$1"
    evidence_for "$node"
    "$GRAPH" start --state "$STATE" --node "$node" >/dev/null
    "$GRAPH" complete --state "$STATE" --node "$node" \
        --output "${WORK}/outputs/${node}.md" \
        --evidence "${WORK}/evidence/${node}.txt" >/dev/null
}

finish_graph_design() {
    local node
    while IFS= read -r node; do complete_node "$node"; done \
        < <(jq -r '.nodes[] | select(.type == "research") | .id' "$STATE")
    complete_node plan
}

seed_conformance_authorities() {
    local feature spec revision
    feature="$(jq -r '.feature' "$STATE")"
    spec="${WORK}/specs/${feature}.md"
    cat > "$spec" <<SPEC
# Task: ${feature}

## Plan Obligations

- \`graph\` [behaviour] The approved graph behavior is delivered.

## Acceptance Criteria

1. Graph behavior is delivered.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | graph-check | main | \`obl.graph\` |
SPEC
    "$PLAN" extract --mode graph --spec "$spec" --repo "$WORK" >/dev/null
    revision="$(jq -r '.revision' "${WORK}/.repomethod/workflows/${feature}.plan-obligations.json")"
    "$PLAN" approve --mode graph --spec "$spec" --repo "$WORK" \
        --revision "$revision" --approval-text reviewed >/dev/null
}

approve_graph() {
    local revision
    seed_conformance_authorities
    revision="$(jq -r '.design_revision' "$STATE")"
    evidence_for graph-approval
    "$GRAPH" approve-graph --state "$STATE" --revision "$revision" \
        --evidence "${WORK}/evidence/graph-approval.txt" >/dev/null
}

pass_graph_conformance() {
    local node="${1:-plan-conformance}" verdict="${WORK}/evidence/${1:-plan-conformance}-verdict.json"
    "$GRAPH" start --state "$STATE" --node "$node" >/dev/null
    cat > "$verdict" <<'JSON'
{"schema_version":1,"overall":"pass","table":[{"plan_ref":"obl.graph","type":"behaviour","status":"pass","rationale":"approved graph behavior is present in the reviewed diff"}],"blockers":[]}
JSON
    "$GRAPH" conform --state "$STATE" --node "$node" --verdict "$verdict" >/dev/null
}

@test "public workflow surface has exactly quick-mvp classic and graph" {
    run "$WRAPPER" graph-lean init --feature removed --state "$STATE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"quick-mvp | classic | graph"* ]]
    [ ! -e "$STATE" ]
}

@test "quick-mvp stays stateless and bounded" {
    run "$WRAPPER" quick-mvp
    [ "$status" -eq 0 ]
    [[ "$output" == *"Goal, Scope, Test"* ]]
    [[ "$output" == *"targeted test"* ]]
    [[ "$output" == *"one correction"* ]]
    [ ! -e "$STATE" ]
}

@test "init refuses a verify command containing an angle-bracket placeholder" {
    run "$GRAPH" init --feature demo --mode classic --state "${WORK}/s.json" \
        --verify-command ".repomethod/scripts/agent-gate.sh --spec <spec>"
    [ "$status" -ne 0 ]
    [[ "$output" == *"placeholder"* ]]
    [ ! -f "${WORK}/s.json" ]
}

@test "init requires an explicit verify command" {
    run "$GRAPH" init --feature demo --mode classic --state "${WORK}/s.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--verify-command is required"* ]]
}

@test "decline-graph is no longer a subcommand" {
    run bash "$GRAPH" decline-graph --state "$STATE" --reason x
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command: decline-graph"* ]]
}

@test "add-task announces that it replaces the default implementation node" {
    "$WRAPPER" graph init --feature addtask --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    run "$GRAPH" add-task --state "$STATE" --id impl-a --goal "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"replacing the default 'implementation' node"* ]]
}

@test "init rejects --max-parallel 0 and a non-numeric --max-parallel" {
    run bash "$GRAPH" init --feature demo --state "${WORK}/a.json" --max-parallel 0 --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"--max-parallel must be greater than zero"* ]]
    run bash "$GRAPH" init --feature demo --state "${WORK}/b.json" --max-parallel x --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"--max-parallel must be a non-negative integer"* ]]
}

@test "graph discovers before proposing an execution revision" {
    run --separate-stderr "$WRAPPER" graph init --feature discovery --state "$STATE" --verify-command true
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' "$STATE")" = "2" ]
    [ "$(jq -r '.mode' "$STATE")" = "graph" ]
    [ "$(jq -r '.status' "$STATE")" = "discovering" ]
    [ "$(jq -r '.config.research' "$STATE")" = "single" ]
    [ "$(jq -r '.runnable[0].node_id' <<<"$output")" = "research" ]
    [ "$(jq -r '[.nodes[].id] | join(",")' "$STATE")" = \
        "research,plan,implementation,verification,completion,plan-conformance" ]
}

@test "parallel research is a configurable fan-out joined by plan" {
    run --separate-stderr "$WRAPPER" graph init --feature research-fanout --state "$STATE" \
        --research parallel --max-parallel 2 --sequential-fallback block --verify-command true
    [ "$status" -eq 0 ]
    [ "$(jq -r '.config.research' "$STATE")" = "parallel" ]
    [ "$(jq -r '.config.max_parallel' "$STATE")" = "2" ]
    [ "$(jq -r '.config.sequential_fallback' "$STATE")" = "block" ]
    [ "$(jq -r '[.nodes[] | select(.type == "research") | .id] | join(",")' "$STATE")" = \
        "research-architecture,research-tests,research-risks" ]
    [ "$(jq -r '.nodes[] | select(.id == "plan") | .dependencies | join(",")' "$STATE")" = \
        "research-architecture,research-tests,research-risks" ]
    [ "$(jq -r '.runnable | length' <<<"$output")" = "2" ]
}

@test "init applies task-specific node goals atomically" {
    run "$WRAPPER" graph init --feature custom-goals --state "$STATE" \
        --node-goal research "Research inventory and order constraints" \
        --node-goal implementation "Implement the purchasing recommendation" --verify-command true
    [ "$status" -eq 0 ]
    [ "$(jq -r '.nodes[] | select(.id == "research") | .goal' "$STATE")" = "Research inventory and order constraints" ]
    [ "$(jq -r '.nodes[] | select(.id == "implementation") | .goal' "$STATE")" = "Implement the purchasing recommendation" ]
    second="${WORK}/duplicate.json"
    run "$WRAPPER" graph init --feature invalid --state "$second" \
        --node-goal plan "Plan once" --node-goal plan "Plan twice" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate node goal: plan"* ]]
    [ ! -e "$second" ]
}

@test "approval is available only after research and plan" {
    "$WRAPPER" graph init --feature lifecycle --state "$STATE" --verify-command true >/dev/null
    evidence_for early-approval
    run "$GRAPH" approve-graph --state "$STATE" --revision 1 --evidence "${WORK}/evidence/early-approval.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not awaiting approval"* ]]
    finish_graph_design
    [ "$(jq -r '.status' "$STATE")" = "awaiting_approval" ]
    [ "$(jq -r '.nodes[] | select(.id == "plan") | .status' "$STATE")" = "completed" ]
    approve_graph
    [ "$(jq -r '.status' "$STATE")" = "active" ]
    run "$GRAPH" next --state "$STATE"
    [ "$output" = "implementation" ]
}

@test "proposed execution graph can be revised before exact approval" {
    "$WRAPPER" graph init --feature revise --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    displayed_revision="$(jq -r '.design_revision' "$STATE")"
    "$GRAPH" add-task --state "$STATE" --id api --goal "Implement API" >/dev/null
    "$GRAPH" add-task --state "$STATE" --id ui --goal "Implement UI" >/dev/null
    [ "$(jq -r '.nodes[] | select(.id == "verification") | .dependencies | sort | join(",")' "$STATE")" = "api,ui" ]
    evidence_for stale-approval
    run "$GRAPH" approve-graph --state "$STATE" --revision "$displayed_revision" --evidence "${WORK}/evidence/stale-approval.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
    approve_graph
    run "$GRAPH" dispatch --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.runnable[].node_id] | sort | join(",")' <<<"$output")" = "api,ui" ]
}

@test "graph structure is editable only while awaiting approval" {
    "$WRAPPER" graph init --feature frozen --state "$STATE" --verify-command true >/dev/null
    run "$GRAPH" edit-node --state "$STATE" --node plan --goal "Changed too early"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only while awaiting approval"* ]]
    finish_graph_design
    run "$GRAPH" edit-node --state "$STATE" --node plan --goal "Propose bounded work"
    [ "$status" -eq 0 ]
    approve_graph
    run "$GRAPH" edit-node --state "$STATE" --node plan --goal "Changed too late"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only while awaiting approval"* ]]
}

@test "approve-and-dispatch records the displayed revision and returns work" {
    "$WRAPPER" graph init --feature approved-ux --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    seed_conformance_authorities
    revision="$(jq -r '.design_revision' "$STATE")"
    run "$GRAPH" approve-and-dispatch --state "$STATE" --revision "$revision" --approval-text "Passt, leg los."
    [ "$status" -eq 0 ]
    [ "$(jq -r '.workflow_status' <<<"$output")" = "active" ]
    [ "$(jq -r '.runnable[0].node_id' <<<"$output")" = "implementation" ]
    evidence_path="$(jq -r '.events[] | select(.action == "graph_approved") | .evidence[0]' "$STATE")"
    [ -s "$evidence_path" ]
    grep -Fq "Revision: $revision" "$evidence_path"
    grep -Fq "Approval: Passt, leg los." "$evidence_path"
}

@test "classic is an active bounded loop without graph approval" {
    run --separate-stderr "$WRAPPER" classic init --feature demo --state "$STATE" --verify-command true --max-retries 1
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema_version' "$STATE")" = "2" ]
    [ "$(jq -r '.mode' "$STATE")" = "classic" ]
    [ "$(jq -r '.status' "$STATE")" = "active" ]
    [ "$(jq -r '.config.verification_command' "$STATE")" = "true" ]
    [ "$(jq -r '.runnable[0].node_id' <<<"$output")" = "implementation" ]
}

@test "generic completion cannot declare verification passed" {
    "$WRAPPER" classic init --feature verifier --state "$STATE" --verify-command true >/dev/null
    complete_node implementation
    evidence_for verification
    "$GRAPH" start --state "$STATE" --node verification >/dev/null
    run "$GRAPH" complete --state "$STATE" --node verification --output "${WORK}/outputs/verification.md" --evidence "${WORK}/evidence/verification.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"use verify"* ]]
    [ "$(jq -r '.nodes[] | select(.id == "verification") | .status' "$STATE")" = "in_progress" ]
}

@test "verify executes the configured command and records a real pass" {
    "$WRAPPER" classic init --feature pass --state "$STATE" --verify-command "printf 'verified output\\n'" >/dev/null
    complete_node implementation
    run "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verification.log"
    [ "$status" -eq 0 ]
    [ -s "${WORK}/verification.log" ]
    grep -Fq "verified output" "${WORK}/verification.log"
    grep -Fq "exit_code=0" "${WORK}/verification.log"
    [ "$(jq -r '.nodes[] | select(.id == "verification") | .outcome' "$STATE")" = "passed" ]
    run "$GRAPH" next --state "$STATE"
    [ "$output" = "completion" ]
}

@test "failed verification creates a bounded fix and re-verification" {
    "$WRAPPER" classic init --feature retry --state "$STATE" --verify-command "printf 'failed check\\n'; false" --max-retries 1 >/dev/null
    complete_node implementation
    run "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verification-failed.log"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.status' "$STATE")" = "active" ]
    [ "$(jq -r '.retry_count' "$STATE")" = "1" ]
    [ "$(jq -r '.nodes[] | select(.id == "fix-1") | .status' "$STATE")" = "pending" ]
    complete_node fix-1
    jq '.config.verification_command = "true"' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
    run "$GRAPH" verify --state "$STATE" --node verification-1 --evidence "${WORK}/verification-pass.log"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.nodes[] | select(.id == "verification-1") | .outcome' "$STATE")" = "passed" ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .dependencies[0]' "$STATE")" = "verification-1" ]
}

@test "verification blocks the workflow when the retry budget is exhausted" {
    "$WRAPPER" classic init --feature blocked --state "$STATE" --verify-command false --max-retries 0 >/dev/null
    complete_node implementation
    run "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verification-failed.log"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.status' "$STATE")" = "blocked" ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .status' "$STATE")" = "blocked" ]
}

@test "parallel limit applies to dispatch and start" {
    "$WRAPPER" graph init --feature bounded --state "$STATE" --max-parallel 1 --verify-command true >/dev/null
    finish_graph_design
    "$GRAPH" add-task --state "$STATE" --id api --goal "Implement API" >/dev/null
    "$GRAPH" add-task --state "$STATE" --id ui --goal "Implement UI" >/dev/null
    approve_graph
    run "$GRAPH" dispatch --state "$STATE"
    [ "$(jq -r '.runnable | length' <<<"$output")" = "1" ]
    "$GRAPH" start --state "$STATE" --node api >/dev/null
    run "$GRAPH" start --state "$STATE" --node ui
    [ "$status" -ne 0 ]
    [[ "$output" == *"parallel limit reached"* ]]
}

@test "human gates pause a completed node until explicit approval" {
    "$WRAPPER" graph init --feature human-gate --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    "$GRAPH" add-node --state "$STATE" --id legal --type review --role Reviewer --goal "Review legal constraints" --order 35 --depends plan --human-gate true >/dev/null
    "$GRAPH" edit-node --state "$STATE" --node implementation --depends legal >/dev/null
    approve_graph
    complete_node legal
    [ "$(jq -r '.nodes[] | select(.id == "legal") | .status' "$STATE")" = "awaiting_human" ]
    evidence_for legal-approval
    "$GRAPH" approve --state "$STATE" --node legal --evidence "${WORK}/evidence/legal-approval.txt" >/dev/null
    run "$GRAPH" next --state "$STATE"
    [ "$output" = "implementation" ]
}

@test "blocking a runnable node blocks the workflow" {
    "$WRAPPER" classic init --feature blocked-node --state "$STATE" --verify-command true >/dev/null
    run "$GRAPH" block --state "$STATE" --node implementation --reason "missing input"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.status' "$STATE")" = "blocked" ]
    [ "$(jq -r '.nodes[] | select(.id == "implementation") | .outcome' "$STATE")" = "blocked" ]
}

@test "approval refuses a completion node that skips verification" {
    "$GRAPH" init --feature demo --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    jq '.nodes |= map(if .id == "completion" then .dependencies = ["plan"] | .inputs = ["plan"] else . end)' "$STATE" > "${STATE}.new" && mv "${STATE}.new" "$STATE"
    revision="$(jq -r '.design_revision' "$STATE")"
    evidence_for graph-approval
    run "$GRAPH" approve-graph --state "$STATE" --revision "$revision" --evidence "${WORK}/evidence/graph-approval.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Verification"* ]]
}

@test "edit-node refuses to change a required boundary node's dependencies" {
    "$GRAPH" init --feature demo --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    run "$GRAPH" edit-node --state "$STATE" --node completion --depends plan
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot change required boundary node dependencies"* ]]
}

@test "completing the completion node refuses a bypassed verification" {
    "$GRAPH" init --feature demo --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    approve_graph
    jq '.nodes |= map(if .id == "completion" then .dependencies = ["plan"] | .inputs = ["plan"] else . end)' "$STATE" > "${STATE}.new" && mv "${STATE}.new" "$STATE"
    evidence_for completion
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    run "$GRAPH" complete --state "$STATE" --node completion --output "${WORK}/outputs/completion.md" --evidence "${WORK}/evidence/completion.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plan conformance"* ]]
    [ "$(jq -r '.status' "$STATE")" != "completed" ]
}

@test "the normal graph path still reaches completed end to end" {
    "$WRAPPER" graph init --feature normal-path --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    approve_graph
    complete_node implementation
    "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verify.log" >/dev/null
    pass_graph_conformance
    evidence_for completion
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    run "$GRAPH" complete --state "$STATE" --node completion --output "${WORK}/outputs/completion.md" --evidence "${WORK}/evidence/completion.txt"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.status' "$STATE")" = "completed" ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .status' "$STATE")" = "completed" ]
}

@test "complete auto-starts a pending node" {
    "$WRAPPER" graph init --feature auto-start --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    approve_graph
    complete_node implementation
    "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verify.log" >/dev/null
    pass_graph_conformance
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .status' "$STATE")" = "pending" ]
    evidence_for completion
    run "$GRAPH" complete --state "$STATE" --node completion --output "${WORK}/outputs/completion.md" --evidence "${WORK}/evidence/completion.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[auto-start] completion"* ]]
    [ "$(jq -r '[.events[] | select(.node_id == "completion" and .action == "started")] | length' "$STATE")" -eq 1 ]
    [ "$(jq -r '[.events[] | select(.node_id == "completion" and .action == "completed")] | length' "$STATE")" -eq 1 ]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .status' "$STATE")" = "completed" ]
}

@test "complete on an already in_progress node does not auto-start" {
    "$WRAPPER" graph init --feature no-auto --state "$STATE" --verify-command true >/dev/null
    finish_graph_design
    approve_graph
    complete_node implementation
    "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/verify.log" >/dev/null
    pass_graph_conformance
    evidence_for completion
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    run "$GRAPH" complete --state "$STATE" --node completion --output "${WORK}/outputs/completion.md" --evidence "${WORK}/evidence/completion.txt"
    [ "$status" -eq 0 ]
    [[ "$output" != *"[auto-start]"* ]]
    [ "$(jq -r '.nodes[] | select(.id == "completion") | .status' "$STATE")" = "completed" ]
}

@test "the retry path still reaches completed after fix and re-verification" {
    "$WRAPPER" classic init --feature retry-path --state "$STATE" --verify-command "false" --max-retries 1 >/dev/null
    complete_node implementation
    run "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/v1.log"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.nodes[] | select(.id == "verification") | .outcome' "$STATE")" = "failed" ]
    complete_node fix-1
    jq '.config.verification_command = "true"' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
    "$GRAPH" verify --state "$STATE" --node verification-1 --evidence "${WORK}/v2.log" >/dev/null
    evidence_for completion
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    run "$GRAPH" complete --state "$STATE" --node completion --output "${WORK}/outputs/completion.md" --evidence "${WORK}/evidence/completion.txt"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.status' "$STATE")" = "completed" ]
}

_git_target_with_impl_done() {
    local repo="$1" feat="${2:-f}"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@e.x
    git -C "$repo" config user.name T
    mkdir -p "${repo}/.repomethod/workflows" "${repo}/.repomethod/evidence" "${repo}/o"
    git -C "$repo" commit -q -m init --allow-empty
    local rstate="${repo}/.repomethod/workflows/${feat}.json"
    ( cd "$repo" && "$GRAPH" init --feature "$feat" --mode classic --state "$rstate" --verify-command "printf 'ok\\n'" >/dev/null )
    printf impl > "${repo}/o/impl.txt"
    "$GRAPH" start --state "$rstate" --node implementation >/dev/null
    "$GRAPH" complete --state "$rstate" --node implementation --output "${repo}/o/impl.txt" --evidence "${repo}/o/impl.txt" >/dev/null
    printf '%s\n' "$rstate"
}

@test "verify force-adds its evidence even under a matching .gitignore" {
    repo="$(mktemp -d)"; printf '*.log\n' > "${repo}/.gitignore"; rstate="$(_git_target_with_impl_done "$repo")"; ev="${repo}/.repomethod/evidence/x.log"
    run "$GRAPH" verify --state "$rstate" --node verification --evidence "$ev"
    [ "$status" -eq 0 ]; [ -s "$ev" ]
    run git -C "$repo" status --porcelain; [[ "$output" == *"A  .repomethod/evidence/x.log"* ]]
    rm -rf -- "$repo"
}

@test "reverify regenerates evidence on a passed node" {
    repo="$(mktemp -d)"; rstate="$(_git_target_with_impl_done "$repo")"
    "$GRAPH" verify --state "$rstate" --node verification --evidence "${repo}/.repomethod/evidence/v.txt" >/dev/null
    [ "$(jq -r '.nodes[] | select(.id=="verification") | .status' "$rstate")" = "completed" ]
    [ "$(jq -r '.nodes[] | select(.id=="verification") | .outcome' "$rstate")" = "passed" ]
    nodes_before="$(jq '.nodes | length' "$rstate")"; rm -f "${repo}/.repomethod/evidence/v.txt"; re="${repo}/.repomethod/evidence/re.txt"
    run "$GRAPH" reverify --state "$rstate" --node verification --evidence "$re"
    [ "$status" -eq 0 ]; [ -s "$re" ]
    run git -C "$repo" status --porcelain; [[ "$output" == *"re.txt"* ]]
    [ "$(jq -r '.nodes[] | select(.id=="verification") | .status' "$rstate")" = "completed" ]
    [ "$(jq -r '.nodes[] | select(.id=="verification") | .outcome' "$rstate")" = "passed" ]
    [ "$(jq -r '[.events[] | select(.action=="reverified")] | length' "$rstate")" -eq 1 ]
    [ "$(jq '.nodes | length' "$rstate")" -eq "$nodes_before" ]
    [ "$(jq -r '.nodes[] | select(.id=="verification") | .evidence[0]' "$rstate")" = "$re" ]
    rm -rf -- "$repo"
}

@test "reverify refuses a verification node that never passed" {
    "$WRAPPER" classic init --feature rvp --state "$STATE" --verify-command true >/dev/null
    run "$GRAPH" reverify --state "$STATE" --node verification --evidence "${WORK}/re.txt"
    [ "$status" -ne 0 ]; [[ "$output" == *"passed verification node"* ]]; [[ "$output" == *"status=pending"* ]]; [ ! -e "${WORK}/re.txt" ]
}

@test "reverify refuses a verification node that failed" {
    "$WRAPPER" classic init --feature rvf --state "$STATE" --verify-command "false" --max-retries 0 >/dev/null
    complete_node implementation
    run "$GRAPH" verify --state "$STATE" --node verification --evidence "${WORK}/v.log"; [ "$status" -ne 0 ]
    run "$GRAPH" reverify --state "$STATE" --node verification --evidence "${WORK}/re.txt"
    [ "$status" -ne 0 ]; [[ "$output" == *"passed verification node"* ]]; [[ "$output" == *"outcome=failed"* ]]
}

@test "reverify refuses a non-verification node" {
    "$WRAPPER" classic init --feature rvn --state "$STATE" --verify-command true >/dev/null
    run "$GRAPH" reverify --state "$STATE" --node implementation --evidence "${WORK}/re.txt"
    [ "$status" -ne 0 ]; [[ "$output" == *"verification node"* ]]
}

_base_repo() {
    local r="$1" a b
    git -C "$r" init -q -b main; git -C "$r" config user.email t@e.x; git -C "$r" config user.name T
    git -C "$r" commit -q --allow-empty -m A; a="$(git -C "$r" rev-parse HEAD)"
    git -C "$r" checkout -q -b feature-base; git -C "$r" commit -q --allow-empty -m B; b="$(git -C "$r" rev-parse HEAD)"
    git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/heads/feature-base; git -C "$r" checkout -q -b work; git -C "$r" commit -q --allow-empty -m C
    printf '%s %s\n' "$a" "$b"
}

@test "init pins an explicit merge base as a 40-character SHA" {
    repo="$(mktemp -d)"; read -r a _b < <(_base_repo "$repo")
    run bash -c "cd '$repo' && '$GRAPH' init --feature f --mode classic --state '$repo/f.json' --base main --verify-command true"
    [ "$status" -eq 0 ]; pinned="$(jq -r '.config.base_ref' "$repo/f.json")"; [ "$pinned" = "$a" ]; [[ "$pinned" =~ ^[0-9a-f]{40}$ ]]; [ "$(jq -r '.schema_version' "$repo/f.json")" = "2" ]; rm -rf -- "$repo"
}

@test "init chooses foreign upstream then origin HEAD then main" {
    repo="$(mktemp -d)"; read -r a b < <(_base_repo "$repo")
    git -C "$repo" config branch.work.remote .; git -C "$repo" config branch.work.merge refs/heads/feature-base
    run bash -c "cd '$repo' && '$GRAPH' init --feature up --mode classic --state '$repo/up.json' --verify-command true"; [ "$status" -eq 0 ]; [ "$(jq -r '.config.base_ref' "$repo/up.json")" = "$b" ]
    git -C "$repo" config --unset branch.work.remote; git -C "$repo" config --unset branch.work.merge
    run bash -c "cd '$repo' && '$GRAPH' init --feature oh --mode classic --state '$repo/oh.json' --verify-command true"; [ "$status" -eq 0 ]; [ "$(jq -r '.config.base_ref' "$repo/oh.json")" = "$b" ]
    git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD
    run bash -c "cd '$repo' && '$GRAPH' init --feature mn --mode classic --state '$repo/mn.json' --verify-command true"; [ "$status" -eq 0 ]; [ "$(jq -r '.config.base_ref' "$repo/mn.json")" = "$a" ]; rm -rf -- "$repo"
}

@test "init rejects an invalid explicit base without fallback" {
    repo="$(mktemp -d)"; read -r _a _b < <(_base_repo "$repo")
    run bash -c "cd '$repo' && '$GRAPH' init --feature f --mode classic --state '$repo/f.json' --base no-such-ref --verify-command true"
    [ "$status" -ne 0 ]; [[ "$output" == *"cannot resolve explicit base ref: no-such-ref"* ]]; [ ! -e "$repo/f.json" ]
    run bash -c "cd '$repo' && '$GRAPH' init --feature f --mode classic --state '$repo/g.json' --verify-command true --base"
    [ "$status" -ne 0 ]; [[ "$output" == *"--base requires a value"* ]]; [ ! -e "$repo/g.json" ]; rm -rf -- "$repo"
}

@test "init leaves a non-gate verification command byte-identical" {
    repo="$(mktemp -d)"; read -r _a _b < <(_base_repo "$repo")
    run bash -c "cd '$repo' && '$GRAPH' init --feature f --mode classic --state '$repo/f.json' --verify-command 'make test'"; [ "$status" -eq 0 ]; [ "$(jq -r '.config.verification_command' "$repo/f.json")" = "make test" ]
    run bash -c "cd '$repo' && '$GRAPH' init --feature g --mode classic --state '$repo/g.json' --verify-command '.repomethod/scripts/agent-gate.sh --spec specs/g.md'"; [ "$status" -eq 0 ]; [ "$(jq -r '.config.verification_command' "$repo/g.json")" = ".repomethod/scripts/agent-gate.sh --spec specs/g.md" ]; rm -rf -- "$repo"
}

@test "verify defaults to force-staged txt evidence" {
    repo="$(mktemp -d)"; printf '*.log\n' > "${repo}/.gitignore"; rstate="$(_git_target_with_impl_done "$repo" demo)"
    run "$GRAPH" verify --state "$rstate" --node verification; [ "$status" -eq 0 ]
    ev="${repo}/.repomethod/evidence/demo-verification.txt"; [ -s "$ev" ]; grep -Fq "exit_code=0" "$ev"
    run git -C "$repo" status --porcelain; [[ "$output" == *"A  .repomethod/evidence/demo-verification.txt"* ]]; rm -rf -- "$repo"
}

@test "reverify reuses the default txt evidence path" {
    repo="$(mktemp -d)"; rstate="$(_git_target_with_impl_done "$repo" demo)"; "$GRAPH" verify --state "$rstate" --node verification >/dev/null
    ev="${repo}/.repomethod/evidence/demo-verification.txt"; [ -s "$ev" ]; printf 'STALE-MARKER\n' > "$ev"
    run "$GRAPH" reverify --state "$rstate" --node verification; [ "$status" -eq 0 ]; [ -s "$ev" ]; grep -Fq "exit_code=0" "$ev"; ! grep -Fq "STALE-MARKER" "$ev"
    run git -C "$repo" status --porcelain; [[ "$output" == *"demo-verification.txt"* ]]; [[ "$(jq -r '.nodes[] | select(.id=="verification") | .evidence[0]' "$rstate")" == *"/.repomethod/evidence/demo-verification.txt" ]]; rm -rf -- "$repo"
}

@test "explicit verification evidence path still wins" {
    repo="$(mktemp -d)"; rstate="$(_git_target_with_impl_done "$repo" demo)"; ev="${repo}/.repomethod/evidence/custom.log"
    run "$GRAPH" verify --state "$rstate" --node verification --evidence "$ev"; [ "$status" -eq 0 ]; [ -s "$ev" ]; [ ! -e "${repo}/.repomethod/evidence/demo-verification.txt" ]; [ "$(jq -r '.nodes[] | select(.id=="verification") | .evidence[0]' "$rstate")" = "$ev" ]; rm -rf -- "$repo"
}
