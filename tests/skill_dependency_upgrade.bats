setup() {
    load 'test_helper/common-setup'
    _common_setup
    SKILL_MD="${REPO_ROOT}/blueprint/.repomethod/skills/dependency-upgrade/SKILL.md"
}

@test "SKILL.md has valid frontmatter and required sections" {
    [ -f "$SKILL_MD" ]
    run grep -c '^name: dependency-upgrade$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## When NOT to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "SKILL.md does not depend on this repo's own lib/" {
    run grep -c 'lib/security_scan\.sh' "$SKILL_MD"
    [ "$output" -eq 0 ]
}
