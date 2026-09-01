setup() {
    load 'test_helper/common-setup'
    _common_setup
    GRAPH="${REPO_ROOT}/blueprint/.repomethod/scripts/workflow-graph.sh"
    WORK="$(mktemp -d)"
    STATE="${WORK}/feature.json"
    "$GRAPH" init --feature demo --mode classic --state "$STATE" --verify-command true --base HEAD >/dev/null
    HF="${WORK}/demo.handoff.json"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "handoff writes a schema-1 sidecar next to the state" {
    run "$GRAPH" handoff --state "$STATE" --node implementation \
        --changed "src/a.py,tests/test_a.py" --next "wire retry backoff"
    [ "$status" -eq 0 ]
    [ -f "$HF" ]
    [ "$(jq -r '.schema_version' "$HF")" = "1" ]
    [ "$(jq -r '.feature' "$HF")" = "demo" ]
    [ "$(jq -r '.node' "$HF")" = "implementation" ]
    [ "$(jq -r '.next_step' "$HF")" = "wire retry backoff" ]
    [ "$(jq -r '.changed_files | length' "$HF")" = "2" ]
    [ "$(jq -r '.blocker' "$HF")" = "null" ]
    [ "$(jq -r '.claim' "$HF")" = "none" ]
    [ "$(jq -r '.workflow_status' "$HF")" = "active" ]
    [ "$(jq -r '.workflow_revision' "$HF")" = "1" ]
}

@test "handoff rejects an unknown node" {
    run "$GRAPH" handoff --state "$STATE" --node nope --changed "x" --next "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown node"* ]]
}

@test "handoff rejects --blocker together with --claim complete" {
    run "$GRAPH" handoff --state "$STATE" --node implementation --next "done" \
        --claim complete --blocker "still broken"
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocker cannot be combined"* ]]
}

@test "handoff requires --blocker when the claim is needs_human" {
    run "$GRAPH" handoff --state "$STATE" --node implementation --next "need a decision" \
        --claim needs_human
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs_human requires --blocker"* ]]
}

@test "handoff allows an empty --changed when a blocker is set" {
    run "$GRAPH" handoff --state "$STATE" --node implementation --next "resolve auth model" \
        --blocker "auth decision missing from spec"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.blocker' "$HF")" = "auth decision missing from spec" ]
    [ "$(jq -r '.changed_files | length' "$HF")" = "0" ]
}

@test "handoff requires --changed when there is no blocker" {
    run "$GRAPH" handoff --state "$STATE" --node implementation --next "y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least one file"* ]]
}

@test "handoff rejects an invalid claim value" {
    run "$GRAPH" handoff --state "$STATE" --node implementation --changed x --next y --claim maybe
    [ "$status" -ne 0 ]
    [[ "$output" == *"claim must be"* ]]
}

@test "a second handoff overwrites the first" {
    "$GRAPH" handoff --state "$STATE" --node implementation --changed a --next "first" >/dev/null
    "$GRAPH" handoff --state "$STATE" --node implementation --changed b --next "second" >/dev/null
    [ "$(jq -r '.next_step' "$HF")" = "second" ]
    [ "$(jq -r '.changed_files[0]' "$HF")" = "b" ]
}

@test "handoff refuses a state whose feature is not a slug" {
    esc="$(dirname "$WORK")/rm-t4-escape.$$"
    mkdir -p "$esc"
    echo sentinel > "${esc}/keep"
    jq --arg f "../rm-t4-escape.$$/pwn" '.feature = $f' "$STATE" > "${STATE}.new"
    mv "${STATE}.new" "$STATE"
    run "$GRAPH" handoff --state "$STATE" --node implementation \
        --changed "src/a.py" --next "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid feature slug"* ]]
    [ ! -e "${esc}/pwn.handoff.json" ]
    [ -f "${esc}/keep" ]
    rm -rf -- "$esc"
}

@test "status refuses a state whose feature is not a slug" {
    jq '.feature = "../evil"' "$STATE" > "${STATE}.new"
    mv "${STATE}.new" "$STATE"
    run "$GRAPH" status --state "$STATE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid feature slug"* ]]
}

@test "handoff refuses a state file in a symlinked directory" {
    real="$(mktemp -d)"
    cp "$STATE" "${real}/feature.json"
    ln -s "$real" "${WORK}/linked"
    run "$GRAPH" handoff --state "${WORK}/linked/feature.json" \
        --node implementation --changed "src/a.py" --next "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlinked"* ]]
    rm -rf -- "$real"
}

@test "handoff refuses a state file that is itself a symlink" {
    mv "$STATE" "${WORK}/real.json"
    ln -s "${WORK}/real.json" "$STATE"
    run "$GRAPH" handoff --state "$STATE" --node implementation \
        --changed "src/a.py" --next "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
}

@test "handoff refuses a state under a symlinked ancestor directory" {
    real="$(mktemp -d)"
    mkdir -p "${real}/sub"
    git -C "$real" init -q
    mv "$STATE" "${real}/sub/feature.json"
    ln -s "$real" "${WORK}/tree"
    run "$GRAPH" handoff --state "${WORK}/tree/sub/feature.json" \
        --node implementation --changed "src/a.py" --next "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    rm -rf -- "$real"
}
