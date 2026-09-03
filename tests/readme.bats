setup() {
    load 'test_helper/common-setup'
    _common_setup
    README="${REPO_ROOT}/README.md"
}

@test "README documents that RepoMethod owns exactly .repomethod/" {
    run grep -F "RepoMethod owns \`.repomethod/\`" "$README"
    [ "$status" -eq 0 ]
}

@test "README does not overclaim the pointer block guarantee" {
    run grep -F "is ever read or touched" "$README"
    [ "$status" -ne 0 ]
    run grep -F "never owns or intentionally modifies content outside its marker block" "$README"
    [ "$status" -eq 0 ]
}

@test "README documents every check the full gate runs" {
    for s in verify.sh verify-scope.sh verify-forbidden.sh intent-lineage.sh plan-obligations.sh \
             verify-acceptance.sh verify-evidence.sh verify-report.sh verify-invariants.sh; do
        run grep -F -- "$s" "$README"
        [ "$status" -eq 0 ]
    done
}

@test "README documents the Plan Obligations migration step" {
    run grep -F "adding the first declaration" "$README"
    [ "$status" -eq 0 ]
    run grep -F "plan-obligations.sh extract" "$README"
    [ "$status" -eq 0 ]
    run grep -F "plan-obligations.sh approve" "$README"
    [ "$status" -eq 0 ]
}

@test "README does not claim a single command surface it does not have" {
    run grep -F "RepoMethod has no second gate" "$README"
    [ "$status" -ne 0 ]
}

@test "README's Installed layout no longer lists a root Makefile or .agent-shared/" {
    run grep -F "Makefile                              verification gates" "$README"
    [ "$status" -ne 0 ]
    run grep -F ".agent-shared" "$README"
    [ "$status" -ne 0 ]
}
