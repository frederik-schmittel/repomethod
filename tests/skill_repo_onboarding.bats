setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/skills/repo-onboarding/scripts/generate-project-map.sh"
    SKILL_MD="${REPO_ROOT}/blueprint/.repomethod/skills/repo-onboarding/SKILL.md"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/scripts" "${WORK}/.repomethod"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "SKILL.md has valid frontmatter with name and description" {
    [ -f "$SKILL_MD" ]
    [ "$(head -1 "$SKILL_MD")" = "---" ]
    run grep -c '^name: repo-onboarding$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^description:' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "SKILL.md has the required sections" {
    run grep -c '^## When to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## When NOT to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## What it does$' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "generate-project-map.sh writes make targets and protected zones" {
    cat > "${WORK}/Makefile" <<'EOF'
verify:
	echo verify
agent-gate:
	echo gate
EOF
    "$SCRIPT" "$WORK"
    [ -f "${WORK}/.repomethod/project-map.md" ]
    run grep -c '^- verify$' "${WORK}/.repomethod/project-map.md"
    [ "$output" -eq 1 ]
    run grep -c '^- infra/\*$' "${WORK}/.repomethod/project-map.md"
    [ "$output" -eq 1 ]
    run grep -c '^- #' "${WORK}/.repomethod/project-map.md"
    [ "$output" -eq 0 ]
}

@test "a repository with more make targets than the line cap still produces a map" {
    for i in $(seq 1 500); do printf 'target-%s:\n\t@true\n' "$i"; done > "${WORK}/Makefile"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
    [ -f "${WORK}/.repomethod/project-map.md" ]
    # make targets and protected zones are never dropped, even when they alone
    # exceed the cap; only the structure section is truncated
    run grep -F "## Protected zones" "${WORK}/.repomethod/project-map.md"
    [ "$status" -eq 0 ]
    run grep -F -- "- infra/*" "${WORK}/.repomethod/project-map.md"
    [ "$status" -eq 0 ]
    run grep -F -- "- target-500" "${WORK}/.repomethod/project-map.md"
    [ "$status" -eq 0 ]
    run grep -F "(truncated:" "${WORK}/.repomethod/project-map.md"
    [ "$status" -eq 0 ]
}

@test "a small repository's map keeps the full structure with no truncation note" {
    mkdir -p "${WORK}/src" "${WORK}/docs"
    run "$SCRIPT" "$WORK"
    [ "$status" -eq 0 ]
    run grep -F "## Structure (depth 2)" "${WORK}/.repomethod/project-map.md"
    [ "$status" -eq 0 ]
    run grep -F "(truncated:" "${WORK}/.repomethod/project-map.md"
    [ "$status" -ne 0 ]
}

@test "generate-project-map.sh caps output at 400 lines even with a huge directory tree" {
    for i in $(seq 1 500); do
        mkdir -p "${WORK}/dir-${i}"
    done
    "$SCRIPT" "$WORK"
    lines="$(wc -l < "${WORK}/.repomethod/project-map.md" | tr -d ' ')"
    [ "$lines" -le 400 ]
}
