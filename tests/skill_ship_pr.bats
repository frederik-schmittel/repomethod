setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/skills/ship-pr/scripts/preflight.sh"
    SKILL_MD="${REPO_ROOT}/blueprint/.repomethod/skills/ship-pr/SKILL.md"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "SKILL.md has valid frontmatter and required sections" {
    [ -f "$SKILL_MD" ]
    run grep -c '^name: ship-pr$' "$SKILL_MD"
    [ "$output" -eq 1 ]
    run grep -c '^## When NOT to use$' "$SKILL_MD"
    [ "$output" -eq 1 ]
}

@test "SKILL.md requires explicit confirmation before opening a PR" {
    run grep -ci 'confirm' "$SKILL_MD"
    [ "$output" -ge 1 ]
}

@test "preflight.sh reports NOT READY when gate scripts are missing" {
    run "$SCRIPT" "$WORK" "main"
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT READY"* ]]
}

@test "preflight.sh reports READY when gate scripts and a spec exist" {
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/specs"
    touch "${WORK}/.repomethod/scripts/verify-acceptance.sh" "${WORK}/.repomethod/scripts/verify-evidence.sh"
    touch "${WORK}/specs/TEMPLATE.md" "${WORK}/specs/my-task.md"
    run "$SCRIPT" "$WORK" "main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"READY"* ]]
}

@test "preflight.sh reports NOT READY when only the template spec exists" {
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/specs"
    touch "${WORK}/.repomethod/scripts/verify-acceptance.sh" "${WORK}/.repomethod/scripts/verify-evidence.sh"
    touch "${WORK}/specs/TEMPLATE.md"
    run "$SCRIPT" "$WORK" "main"
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT READY"* ]]
}

quick_ship_repo() {
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/.repomethod/evidence"
    touch "${WORK}/.repomethod/scripts/verify-acceptance.sh" "${WORK}/.repomethod/scripts/verify-evidence.sh"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts/verify-scope.sh" "${WORK}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    chmod +x "${WORK}/.repomethod/scripts/verify-scope.sh"
    git -C "$WORK" init -q
    git -C "$WORK" config user.email t@e.x
    git -C "$WORK" config user.name T
}

@test "preflight.sh --quick is READY with an evidence note and no protected zone touched" {
    quick_ship_repo
    printf 'Built X; verified green.\n' > "${WORK}/.repomethod/evidence/report.md"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
    run "$SCRIPT" "$WORK" HEAD --quick
    [ "$status" -eq 0 ]
    [[ "$output" == *"READY"* ]]
}

@test "preflight.sh --quick is NOT READY without an evidence note" {
    quick_ship_repo
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
    run "$SCRIPT" "$WORK" HEAD --quick
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT READY"* ]]
}

@test "preflight.sh --quick is NOT READY when a protected zone was touched" {
    quick_ship_repo
    printf 'Built X; verified green.\n' > "${WORK}/.repomethod/evidence/report.md"
    mkdir -p "${WORK}/infra"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
    echo "x" > "${WORK}/infra/x.tf"
    run "$SCRIPT" "$WORK" HEAD --quick
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT READY"* ]]
}
