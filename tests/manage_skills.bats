# tests/manage_skills.bats
setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    source "${REPO_ROOT}/lib/blueprint.sh"
    source "${REPO_ROOT}/lib/pointer.sh"
    TARGET="$(mktemp -d)"
    SOURCE_SKILL="$(mktemp -d)"
    git -C "$TARGET" init -q
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    mkdir -p "${TARGET}/.agents/skills" "${TARGET}/.claude/skills"
    ln -s "../../.repomethod/skills/repo-onboarding" "${TARGET}/.agents/skills/repo-onboarding"
    ln -s "../../.repomethod/skills/repo-onboarding" "${TARGET}/.claude/skills/repo-onboarding"
    manifest="$(cat "${TARGET}/.repomethod/manifest.json")"
    manifest="$(manifest_add_file "$manifest" ".agents/skills/repo-onboarding" "../../.repomethod/skills/repo-onboarding" "skill-link")"
    manifest="$(manifest_add_file "$manifest" ".claude/skills/repo-onboarding" "../../.repomethod/skills/repo-onboarding" "skill-link")"
    manifest_write "$manifest" "${TARGET}/.repomethod/manifest.json"
    cat > "${SOURCE_SKILL}/SKILL.md" <<'EOF'
---
name: local-demo
description: Test skill
---
EOF
}

teardown() {
    rm -rf -- "$TARGET" "$SOURCE_SKILL"
}

@test "add copies a local skill and exposes it to both agent hosts" {
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.repomethod/skills/local-demo/SKILL.md" ]
    [ -f "${TARGET}/.agents/skills/local-demo/SKILL.md" ]
    [ -f "${TARGET}/.claude/skills/local-demo/SKILL.md" ]

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" list
    [ "$status" -eq 0 ]
    [[ "$output" == *$'local-demo\tenabled\tlocal'* ]]
}

@test "add always reads the name from SKILL.md" {
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL" --name another-name
    [ "$status" -ne 0 ]
    [[ "$output" == *"reads the name from SKILL.md"* ]]
    [ ! -e "${TARGET}/.repomethod/skills/local-demo" ]
}

@test "add rejects non-portable symlinks inside a skill" {
    echo "outside" > "${SOURCE_SKILL}/outside.txt"
    ln -s "outside.txt" "${SOURCE_SKILL}/linked.txt"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not contain symlinks"* ]]
    [ ! -e "${TARGET}/.repomethod/skills/local-demo" ]
}

@test "add refuses a SKILL.md whose declared name is not a valid skill name" {
    cat > "${SOURCE_SKILL}/SKILL.md" <<'EOF'
---
name: Not A Name
description: Test skill
---
EOF
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid skill name"* ]]
}

@test "add rejects an invalid skill source and never creates a partial skill" {
    rm -f -- "${SOURCE_SKILL}/SKILL.md"
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL" --name broken
    [ "$status" -ne 0 ]
    [ ! -e "${TARGET}/.repomethod/skills/broken" ]
}

@test "add refuses to overwrite an existing skill" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    echo "changed source" >> "${SOURCE_SKILL}/SKILL.md"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -ne 0 ]
    [[ "$(cat "${TARGET}/.repomethod/skills/local-demo/SKILL.md")" != *"changed source"* ]]
}

@test "remove deletes a local skill and its derived links" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name local-demo
    [ "$status" -eq 0 ]
    [ ! -e "${TARGET}/.repomethod/skills/local-demo" ]
    [ ! -e "${TARGET}/.agents/skills/local-demo" ]
    [ ! -e "${TARGET}/.claude/skills/local-demo" ]
}

@test "remove disables a managed skill without deleting its canonical files" {
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name repo-onboarding
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.repomethod/skills/repo-onboarding/SKILL.md" ]
    [ ! -e "${TARGET}/.agents/skills/repo-onboarding" ]
    [ ! -e "${TARGET}/.claude/skills/repo-onboarding" ]
    grep -Fqx "repo-onboarding" "${TARGET}/.repomethod/disabled-skills.txt"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" list
    [[ "$output" == *$'repo-onboarding\tdisabled\tmanaged'* ]]
}

@test "enable restores a disabled managed skill" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name repo-onboarding

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" enable --name repo-onboarding
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.agents/skills/repo-onboarding/SKILL.md" ]
    [ -f "${TARGET}/.claude/skills/repo-onboarding/SKILL.md" ]
    [ ! -f "${TARGET}/.repomethod/disabled-skills.txt" ]
}

@test "remove refuses to touch a foreign agent skill path" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    rm -f -- "${TARGET}/.agents/skills/local-demo"
    mkdir -p "${TARGET}/.agents/skills/local-demo"
    echo "user content" > "${TARGET}/.agents/skills/local-demo/notes.txt"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name local-demo
    [ "$status" -ne 0 ]
    [ -f "${TARGET}/.agents/skills/local-demo/notes.txt" ]
    [ -f "${TARGET}/.repomethod/skills/local-demo/SKILL.md" ]
}

@test "enable refuses a foreign correct-looking symlink without manifest ownership" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name repo-onboarding
    ln -s "../../.repomethod/skills/repo-onboarding" "${TARGET}/.agents/skills/repo-onboarding"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" enable --name repo-onboarding
    [ "$status" -ne 0 ]
    [[ "$output" == *"not managed"* ]]
    [ -L "${TARGET}/.agents/skills/repo-onboarding" ]
    [ "$(readlink "${TARGET}/.agents/skills/repo-onboarding")" = "../../.repomethod/skills/repo-onboarding" ]
    grep -Fqx "repo-onboarding" "${TARGET}/.repomethod/disabled-skills.txt"
}

@test "remove never deletes a correct-looking symlink whose ownership record is missing" {
    "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"

    manifest="${TARGET}/.repomethod/manifest.json"
    tmp="${manifest}.tmp"
    jq 'del(.files[".agents/skills/local-demo"])' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" remove --name local-demo
    [ "$status" -ne 0 ]
    [[ "$output" == *"foreign symlink"* ]]
    [ -L "${TARGET}/.agents/skills/local-demo" ]
    [ -f "${TARGET}/.repomethod/skills/local-demo/SKILL.md" ]
}

@test "add refuses a symlinked .agents parent before creating anything outside the repository" {
    OUTSIDE="$(mktemp -d)"
    rm -rf "${TARGET}/.agents"
    ln -s "$OUTSIDE" "${TARGET}/.agents"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlinked managed directory"* ]]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "add leaves nothing behind when the second host link conflicts" {
    mkdir -p "${TARGET}/.claude/skills/local-demo"
    manifest_before="$(cat "${TARGET}/.repomethod/manifest.json")"
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" add --source "$SOURCE_SKILL"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists and is not managed"* ]] || \
        [[ "$output" == *"already exists"* ]]
    [ ! -e "${TARGET}/.repomethod/skills/local-demo" ]
    [ ! -e "${TARGET}/.agents/skills/local-demo" ]
    [ -d "${TARGET}/.claude/skills/local-demo" ]
    [ "$(cat "${TARGET}/.repomethod/manifest.json")" = "$manifest_before" ]
    [ -z "$(find "${TARGET}/.repomethod/skills" -maxdepth 1 -name '.*.tmp.*' -print -quit)" ]
}

@test "enable leaves nothing behind when the second host link conflicts" {
    mkdir -p "${TARGET}/.repomethod/skills/local-demo"
    cp "${SOURCE_SKILL}/SKILL.md" "${TARGET}/.repomethod/skills/local-demo/"
    mkdir -p "${TARGET}/.claude/skills/local-demo"
    manifest_before="$(cat "${TARGET}/.repomethod/manifest.json")"
    run "${TARGET}/.repomethod/scripts/manage-skills.sh" enable --name local-demo
    [ "$status" -ne 0 ]
    [ ! -e "${TARGET}/.agents/skills/local-demo" ]
    [ "$(cat "${TARGET}/.repomethod/manifest.json")" = "$manifest_before" ]
}

@test "any command refuses a symlinked managed skills directory before reading the manifest" {
    OUTSIDE="$(mktemp -d)"
    rm -rf "${TARGET}/.repomethod/skills"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod/skills"

    run "${TARGET}/.repomethod/scripts/manage-skills.sh" list
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlinked managed directory"* ]]

    rm -rf -- "$OUTSIDE"
}
