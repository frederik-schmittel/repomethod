setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/plan-obligations.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/specs" "${WORK}/.repomethod/workflows"
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    local name="$1"
    shift
    {
        printf '# Task\n\n## Plan Obligations\n\n'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
        printf '\n## Acceptance Criteria\n\n1. works\n'
    } > "${WORK}/specs/${name}.md"
}

artifact() {
    printf '%s/.repomethod/workflows/%s.plan-obligations.json\n' "$WORK" "$1"
}

@test "quick-mvp reports plan obligations as explicitly not applicable" {
    run "$SCRIPT" check --mode quick-mvp --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]

    run "$SCRIPT" approve --mode quick-mvp --repo "$WORK" --revision 1 --approval-text approved
    [ "$status" -eq 1 ]
    [[ "$output" == *"no plan-obligation approval step"* ]]
}

@test "a spec without plan obligations is not applicable until an artifact exists" {
    write_spec empty

    run "$SCRIPT" check --mode classic --spec "${WORK}/specs/empty.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "NOT_APPLICABLE:"* ]]
    [ ! -e "$(artifact empty)" ]
}

@test "extract assigns stable IDs and all four supported types" {
    write_spec demo \
        '- `api-shape` [shape] API returns id and status.' \
        '- `retry-order` [behaviour] Retry happens before completion.' \
        '- `no-eval` [prohibition] Plan content is never evaluated as shell code.' \
        '- `approval-first` [process] Implementation starts only after approval.'

    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"revision 1 pending review"* ]]

    file="$(artifact demo)"
    [ "$(jq -r '.revision' "$file")" = "1" ]
    [ "$(jq -r '[.obligations[].id] | join(",")' "$file")" = \
        "obl.api-shape,obl.retry-order,obl.no-eval,obl.approval-first" ]
    [ "$(jq -r '[.obligations[].type] | join(",")' "$file")" = \
        "shape,behaviour,prohibition,process" ]
    [ "$(jq -r '.review.status' "$file")" = "pending" ]
}

@test "unreviewed extraction cannot satisfy check" {
    write_spec demo '- `api-shape` [shape] API returns id and status.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    run "$SCRIPT" check --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not approved"* ]]
}

@test "approval is bound to the displayed revision and current spec" {
    write_spec demo '- `api-shape` [shape] API returns id and status.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    run "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved
    [ "$status" -eq 0 ]
    [ "$(jq -r '.review.status' "$(artifact demo)")" = "approved" ]

    run "$SCRIPT" check --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved plan obligations revision 1"* ]]
}

@test "unchanged extraction preserves revision and approval" {
    write_spec demo '- `api-shape` [shape] API returns id and status.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNCHANGED: plan obligations revision 1 (approved)"* ]]
}

@test "wording changes retain IDs and create a changed pending revision" {
    write_spec demo \
        '- `api-shape` [shape] API returns id and status.' \
        '- `retry-order` [behaviour] Retry happens before completion.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    write_spec demo \
        '- `api-shape` [shape] API returns id, status, and result.' \
        '- `retry-order` [behaviour] Retry happens before completion.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    file="$(artifact demo)"
    [ "$(jq -r '.revision' "$file")" = "2" ]
    [ "$(jq -r '.revision_diff.changed[0].id' "$file")" = "obl.api-shape" ]
    [ "$(jq -r '.obligations[] | select(.id == "obl.api-shape") | .review_status' "$file")" = "pending" ]
    [ "$(jq -r '.obligations[] | select(.id == "obl.retry-order") | .review_status' "$file")" = "approved" ]
}

@test "added removed and changed obligations appear in the revision diff" {
    write_spec demo \
        '- `keep` [shape] Keep this.' \
        '- `change` [behaviour] Old wording.' \
        '- `remove` [prohibition] Remove this.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    write_spec demo \
        '- `keep` [shape] Keep this.' \
        '- `change` [process] New wording.' \
        '- `add` [process] Added now.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    file="$(artifact demo)"
    [ "$(jq -r '.revision_diff.added[0].id' "$file")" = "obl.add" ]
    [ "$(jq -r '.revision_diff.removed[0].id' "$file")" = "obl.remove" ]
    [ "$(jq -r '.revision_diff.changed[0].id' "$file")" = "obl.change" ]
}

@test "removing the last obligation still requires a reviewed revision" {
    write_spec demo '- `last` [shape] Last obligation.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    write_spec demo
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    file="$(artifact demo)"
    [ "$(jq -r '.revision' "$file")" = "2" ]
    [ "$(jq '.obligations | length' "$file")" = "0" ]
    [ "$(jq -r '.revision_diff.removed[0].id' "$file")" = "obl.last" ]
    [ "$(jq -r '.review.status' "$file")" = "pending" ]
}

@test "stale displayed revisions and stale source edits cannot be approved" {
    write_spec demo '- `api` [shape] Old.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    write_spec demo '- `api` [shape] New.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null

    run "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text stale
    [ "$status" -eq 1 ]
    [[ "$output" == *"displayed revision 1 is stale"* ]]

    write_spec demo '- `api` [shape] Edited after extraction.'
    run "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 2 --approval-text stale-source
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot approve stale"* ]]
}

@test "duplicate anchors fail closed as ID collisions" {
    write_spec collision \
        '- `same` [shape] First.' \
        '- `same` [process] Second.'

    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/collision.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"anchor/id collision"* ]]
    [ ! -e "$(artifact collision)" ]
}

@test "malformed declarations and unknown types fail closed" {
    write_spec malformed '- api [shape] Missing backticks.'
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/malformed.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Plan Obligations declaration"* ]]

    write_spec unknown '- `api` [random] Unknown type.'
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/unknown.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"malformed Plan Obligations declaration"* ]]
}

@test "multiple headings and unterminated template comments fail closed" {
    cat > "${WORK}/specs/duplicate-section.md" <<'SPEC'
# T
## Plan Obligations
- `a` [shape] A.
## X
## Plan Obligations
- `b` [shape] B.
SPEC
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/duplicate-section.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected at most one heading"* ]]

    cat > "${WORK}/specs/comment.md" <<'SPEC'
# T
## Plan Obligations
<!-- never closes
- `a` [shape] A.
SPEC
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/comment.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unterminated HTML comment"* ]]
}

@test "tampered or structurally invalid artifacts fail closed" {
    write_spec demo '- `api` [shape] API.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    file="$(artifact demo)"
    jq '.obligations[0].text = "tampered"' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"

    run "$SCRIPT" check --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stale or does not match"* ]]

    printf '{broken json\n' > "$file"
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid existing plan obligations artifact"* ]]
}

@test "templates and workflow help describe the reviewed obligation contract" {
    run grep -c '^## Plan Obligations$' "${REPO_ROOT}/blueprint/.repomethod/templates/spec.md"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
    grep -Fq 'current extraction revision is reviewed' "${REPO_ROOT}/blueprint/.repomethod/templates/plan.md"

    run "${REPO_ROOT}/blueprint/.repomethod/scripts/feature-workflow.sh" classic
    [ "$status" -eq 0 ]
    [[ "$output" == *"plan-obligations.sh extract"* ]]

    run "${REPO_ROOT}/blueprint/.repomethod/scripts/feature-workflow.sh" graph
    [ "$status" -eq 0 ]
    [[ "$output" == *"obligation extraction/review"* ]]
}

@test "reordering stable anchors does not create a new revision" {
    write_spec demo \
        '- `a` [shape] A.' \
        '- `b` [process] B.'
    "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" >/dev/null
    "$SCRIPT" approve --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null

    write_spec demo \
        '- `b` [process] B.' \
        '- `a` [shape] A.'
    run "$SCRIPT" extract --mode graph --spec "${WORK}/specs/demo.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNCHANGED: plan obligations revision 1 (approved)"* ]]
}

@test "symlinked specs fail closed" {
    write_spec real '- `a` [shape] A.'
    ln -s real.md "${WORK}/specs/link.md"

    run "$SCRIPT" check --mode graph --spec "${WORK}/specs/link.md" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"spec must not be a symlink"* ]]
}

@test "classic uses the same reviewed contract when obligations are declared" {
    write_spec classic '- `api` [shape] API.'
    "$SCRIPT" extract --mode classic --spec "${WORK}/specs/classic.md" --repo "$WORK" >/dev/null

    run "$SCRIPT" check --mode classic --spec "${WORK}/specs/classic.md" --repo "$WORK"
    [ "$status" -eq 1 ]

    "$SCRIPT" approve --mode classic --spec "${WORK}/specs/classic.md" --repo "$WORK" \
        --revision 1 --approval-text approved >/dev/null
    run "$SCRIPT" check --mode classic --spec "${WORK}/specs/classic.md" --repo "$WORK"
    [ "$status" -eq 0 ]
}
