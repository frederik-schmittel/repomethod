setup() {
    load 'test_helper/common-setup'
    _common_setup
    SKILL_MD="${REPO_ROOT}/blueprint/.repomethod/skills/compliance-review/SKILL.md"
}

@test "SKILL.md has valid frontmatter and required sections" {
    [ -f "$SKILL_MD" ]
    run grep -c '^name: compliance-review$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## When NOT to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "SKILL.md references the protected-zones file, not a hardcoded zone list" {
    run grep -c 'protected-zones\.txt' "$SKILL_MD"
    [ "$output" -ge 1 ]
}

@test "SKILL.md references the spec template's section names" {
    run grep -c 'Acceptance Criteria' "$SKILL_MD"
    [ "$output" -ge 1 ]
}
