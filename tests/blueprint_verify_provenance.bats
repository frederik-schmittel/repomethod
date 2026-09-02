setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-provenance.sh"
    PLAN="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-obligations.sh"
    DESCOPE="${REPO_ROOT}/blueprint/.repomethod/scripts/descope-ledger.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/specs/packets" "${WORK}/.repomethod/workflows"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    local mapping_a="${1:-}" mapping_b="${2:-}" packet="${3:-}"
    [ -n "$mapping_a" ] || mapping_a='`obl.a`'
    [ -n "$mapping_b" ] || mapping_b='-'
    cat > "${WORK}/specs/demo.md" <<SPEC
# Task: provenance

## Plan Obligations

- \`a\` [shape] A is delivered.
- \`b\` [behaviour] B is delivered.

## Acceptance Criteria

1. A works.
2. B works.

## Acceptance Mapping

| Criterion | Test/Evidence | Work Packet | Plan Ref |
| --- | --- | --- | --- |
| 1 | test-a | main | ${mapping_a} |
| 2 | test-b | ${packet:-main} | ${mapping_b} |

## Work Packets
SPEC
    if [ -n "$packet" ]; then
        printf '\n- `%s`: packet\n' "$packet" >> "${WORK}/specs/demo.md"
    fi
}

approve_plan() {
    local mode="$1"
    "$PLAN" extract --mode "$mode" --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$PLAN" approve --mode "$mode" --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text reviewed >/dev/null
}

@test "provenance verifier is executable in the blueprint" {
    [ -x "$SCRIPT" ]
}

@test "valid acceptance mappings cover approved obligations" {
    write_spec '`obl.a`' '`obl.b`'
    approve_plan classic

    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"covers all 2 obligations"* ]]
}

@test "unknown and malformed Plan Ref values fail closed" {
    write_spec '`obl.a`' '`obl.unknown`'
    approve_plan classic
    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown obligation reference obl.unknown"* ]]

    write_spec '`obl.a`' 'obl.b'
    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Plan Ref"* ]]

    write_spec '`obl.a`,' '`obl.b`'
    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty obligation reference"* ]]
}

@test "orphan obligations warn in Classic and block in Graph" {
    write_spec '`obl.a`' '-'
    approve_plan classic
    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROVENANCE-WARN: orphan plan obligation obl.b"* ]]

    rm -f "${WORK}/.repomethod/workflows/demo.plan-obligations.json"
    approve_plan graph
    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PROVENANCE-ORPHAN: obl.b"* ]]
}

@test "references aggregate across declared work packets and duplicates count once" {
    write_spec '`obl.a`, `obl.a`' '-' packet-one
    cat > "${WORK}/specs/packets/packet-one.md" <<'PACKET'
# Work Packet: packet-one

## Acceptance Mapping

| Criterion | Test/Evidence | Plan Ref |
| --- | --- | --- |
| 2 | packet-test | `obl.b`, `obl.a` |
PACKET
    approve_plan graph

    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"covers all 2 obligations"* ]]
}

@test "empty mappings produce true orphans rather than parse failures" {
    write_spec '-' '-'
    approve_plan classic

    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan plan obligation obl.a"* ]]
    [[ "$output" == *"orphan plan obligation obl.b"* ]]
}

@test "accepted canonical descopes are treated as resolved orphan obligations" {
    write_spec '`obl.a`' '-'
    approve_plan graph
    state="${WORK}/.repomethod/workflows/demo.json"
    printf '{"feature":"demo"}\n' > "$state"
    "$DESCOPE" init --state "$state" >/dev/null
    "$DESCOPE" add --state "$state" --id descope.b --plan-ref obl.b \
        --description 'B omitted' --rationale 'reviewed omission' --owner test >/dev/null
    "$DESCOPE" review --state "$state" --id descope.b --status accepted \
        --rationale 'accepted omission' --owner reviewer >/dev/null

    run "$SCRIPT" --spec "${WORK}/specs/demo.md" --state "$state" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"covers all 2 obligations"* ]]
}

@test "invariant_required metadata is reviewed without changing stable obligation IDs" {
    cat > "${WORK}/specs/demo.md" <<'SPEC'
# Task: metadata

## Plan Obligations

- `a` [shape] A.
- `b` [behaviour] B.
SPEC
    approve_plan classic
    file="${WORK}/.repomethod/workflows/demo.plan-obligations.json"
    [ "$(jq -r '.obligations[] | select(.id == "obl.a") | .invariant_required' "$file")" = "false" ]

    cat > "${WORK}/specs/demo.md" <<'SPEC'
# Task: metadata

## Plan Obligations

- `a` [shape] A.
- `b` [behaviour] [invariant_required] B.
SPEC
    run "$PLAN" extract --mode classic --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.revision' "$file")" = "2" ]
    [ "$(jq -r '.revision_diff.changed[0].id' "$file")" = "obl.b" ]
    [ "$(jq -r '.obligations[] | select(.id == "obl.a") | .review_status' "$file")" = "approved" ]
    [ "$(jq -r '.obligations[] | select(.id == "obl.b") | .review_status' "$file")" = "pending" ]
    [ "$(jq -r '.obligations[] | select(.id == "obl.b") | .invariant_required' "$file")" = "true" ]
}

@test "legacy approved artifacts without invariant_required remain compatible as false" {
    write_spec '`obl.a`' '`obl.b`'
    approve_plan classic
    file="${WORK}/.repomethod/workflows/demo.plan-obligations.json"
    jq 'del(.obligations[].invariant_required)' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"

    run "$PLAN" check --mode classic --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved plan obligations revision 1"* ]]
}
