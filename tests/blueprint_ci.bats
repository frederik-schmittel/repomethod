setup() {
    load 'test_helper/common-setup'
    _common_setup
    WORKFLOW="${REPO_ROOT}/blueprint/.github/workflows/repomethod-verify.yml"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "target PR workflow uses checkout v5" {
    run grep -F "uses: actions/checkout@v5" "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F "  contents: read" "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "target PR workflow resolves at most one changed task spec and branches on it" {
    run grep -F "Expected at most one changed task spec" "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F "':(top,glob)specs/*.md'" "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F "SPEC: \${{ steps.task.outputs.spec }}" "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F "mode=quick" "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "target PR workflow runs the quick gate when no spec changed" {
    run grep -F -- "agent-gate.sh --quick" "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "target PR workflow passes the canonical evidence paths" {
    run grep -F -- "--report .repomethod/evidence/report.md" "$WORKFLOW"
    [ "$status" -eq 0 ]
    run grep -F -- "--evidence-dir" "$WORKFLOW"
    [ "$status" -ne 0 ]
}

@test "target PR workflow does not swallow the gate exit status in a pipe" {
    run grep -nE 'agent-gate\.sh.*\|' "$WORKFLOW"
    [ "$status" -ne 0 ]
}

@test "target PR gate step pins a pipefail shell" {
    run grep -F "shell: bash" "$WORKFLOW"
    [ "$status" -eq 0 ]
}

@test "task-spec pathspec excludes packet files" {
    git -C "$WORK" init -q
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name Test
    mkdir -p "${WORK}/specs/packets"
    echo "template" > "${WORK}/specs/TEMPLATE.md"
    git -C "$WORK" add .
    git -C "$WORK" commit -q -m base
    base="$(git -C "$WORK" rev-parse HEAD)"
    echo "task" > "${WORK}/specs/task.md"
    echo "packet" > "${WORK}/specs/packets/one.md"
    echo "template changed" > "${WORK}/specs/TEMPLATE.md"
    git -C "$WORK" add .
    git -C "$WORK" commit -q -m task

    run git -C "$WORK" diff --name-only "$base...HEAD" \
        -- ':(top,glob)specs/*.md' ':(top,exclude)specs/TEMPLATE.md'
    [ "$status" -eq 0 ]
    [ "$output" = "specs/task.md" ]
}
