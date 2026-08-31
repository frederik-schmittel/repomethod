# tests/lib_skills.bats
setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    source "${REPO_ROOT}/lib/skills.sh"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/.repomethod/skills/foo"
    echo "# foo skill" > "${WORK}/.repomethod/skills/foo/SKILL.md"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "stage_skill_link creates a working relative symlink" {
    run stage_skill_link "$WORK" "foo" ".agents/skills"
    [ "$status" -eq 0 ]
    [ -L "${WORK}/.agents/skills/foo" ]
    [ -f "${WORK}/.agents/skills/foo/SKILL.md" ]
    [[ "$(cat "${WORK}/.agents/skills/foo/SKILL.md")" == "# foo skill" ]]
}

@test "stage_skill_link dies with the exact symlink-required message when ln is unavailable" {
    stub_dir="$(mktemp -d)"
    cat > "${stub_dir}/ln" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_dir}/ln"
    run env PATH="${stub_dir}:${PATH}" bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/skills.sh'
        stage_skill_link '${WORK}' foo .claude/skills
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"symbolic links are required for RepoMethod skill links"* ]]
    [ ! -e "${WORK}/.claude/skills/foo" ]
    rm -rf -- "$stub_dir"
}

@test "stage_skill_link is idempotent when the prior manifest proves ownership" {
    run stage_skill_link "$WORK" "foo" ".agents/skills"
    [ "$status" -eq 0 ]
    first_target="$(readlink "${WORK}/.agents/skills/foo")"

    # A real caller (install.sh, update.sh) always has the manifest from
    # its own prior run to check by the time a link could legitimately
    # already exist — so proving idempotency means passing that evidence,
    # not calling with no manifest context at all.
    prior_manifest="$(manifest_init "0.1.0" "core")"
    prior_manifest="$(manifest_add_file "$prior_manifest" ".agents/skills/foo" "$first_target" "skill-link")"

    run stage_skill_link "$WORK" "foo" ".agents/skills" "$prior_manifest"
    [ "$status" -eq 0 ]
    [ -L "${WORK}/.agents/skills/foo" ]
    [ "$(readlink "${WORK}/.agents/skills/foo")" = "$first_target" ]
}

@test "stage_skill_link refuses a correct-looking symlink when no prior manifest exists at all" {
    mkdir -p "${WORK}/.agents/skills"
    ln -s "../../.repomethod/skills/foo" "${WORK}/.agents/skills/foo"

    run stage_skill_link "$WORK" "foo" ".agents/skills"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ -L "${WORK}/.agents/skills/foo" ]
    [ "$(readlink "${WORK}/.agents/skills/foo")" = "../../.repomethod/skills/foo" ]
}

@test "stage_skill_link refuses a correct-looking symlink the manifest never recorded as ours" {
    mkdir -p "${WORK}/.agents/skills"
    ln -s "../../.repomethod/skills/foo" "${WORK}/.agents/skills/foo"
    prior_manifest="$(manifest_init "0.1.0" "core")"

    run stage_skill_link "$WORK" "foo" ".agents/skills" "$prior_manifest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ -L "${WORK}/.agents/skills/foo" ]
    [ "$(readlink "${WORK}/.agents/skills/foo")" = "../../.repomethod/skills/foo" ]
}

@test "stage_skill_link refuses to overwrite a foreign path never created by repomethod" {
    mkdir -p "${WORK}/.agents/skills/foo"
    echo "not repomethod's, do not touch" > "${WORK}/.agents/skills/foo/stray.txt"

    run stage_skill_link "$WORK" "foo" ".agents/skills"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ ! -L "${WORK}/.agents/skills/foo" ]
    [ -f "${WORK}/.agents/skills/foo/stray.txt" ]
}

@test "stage_skill_link self-heals a stale symlink it previously created" {
    mkdir -p "${WORK}/.agents/skills"
    ln -s "../../.repomethod/skills/some-other-target" "${WORK}/.agents/skills/foo"
    prior_manifest="$(manifest_init "0.1.0" "core")"
    prior_manifest="$(manifest_add_file "$prior_manifest" ".agents/skills/foo" "../../.repomethod/skills/some-other-target" "skill-link")"

    run stage_skill_link "$WORK" "foo" ".agents/skills" "$prior_manifest"
    [ "$status" -eq 0 ]
    [ -L "${WORK}/.agents/skills/foo" ]
    [ -f "${WORK}/.agents/skills/foo/SKILL.md" ]
}

@test "stage_skill_link refuses to overwrite a directory that replaced its previously-managed symlink" {
    # The user removed the repomethod-created symlink and put their own
    # real directory in its place. The manifest still says "skill-link" —
    # that record alone must not be enough to justify rm -rf'ing it; the
    # current on-disk type has to still match what repomethod actually made.
    mkdir -p "${WORK}/.agents/skills/foo"
    echo "my own replacement content" > "${WORK}/.agents/skills/foo/mine.txt"
    prior_manifest="$(manifest_init "0.1.0" "core")"
    prior_manifest="$(manifest_add_file "$prior_manifest" ".agents/skills/foo" "../../.repomethod/skills/foo" "skill-link")"

    run stage_skill_link "$WORK" "foo" ".agents/skills" "$prior_manifest"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ ! -L "${WORK}/.agents/skills/foo" ]
    [ -f "${WORK}/.agents/skills/foo/mine.txt" ]
}

@test "stage_core_skills links every canonical skill into both agent locations and records the manifest" {
    mkdir -p "${WORK}/.repomethod/skills/bar"
    echo "# bar skill" > "${WORK}/.repomethod/skills/bar/SKILL.md"

    manifest="$(manifest_init "0.1.0" "core")"
    manifest="$(stage_core_skills "$WORK" "$manifest")"

    [ -L "${WORK}/.agents/skills/foo" ]
    [ -L "${WORK}/.claude/skills/foo" ]
    [ -L "${WORK}/.agents/skills/bar" ]
    [ -L "${WORK}/.claude/skills/bar" ]

    echo "$manifest" | jq -e '.files[".agents/skills/foo"].source == "skill-link"'
    echo "$manifest" | jq -e '.files[".agents/skills/foo"].sha256 == "../../.repomethod/skills/foo"'
    echo "$manifest" | jq -e '.files[".claude/skills/bar"].source == "skill-link"'
}

@test "stage_core_skills dies with the exact symlink-required message when ln is unavailable" {
    stub_dir="$(mktemp -d)"
    cat > "${stub_dir}/ln" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_dir}/ln"

    manifest="$(manifest_init "0.1.0" "core")"
    run env PATH="${stub_dir}:${PATH}" bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/manifest.sh'
        source '${REPO_ROOT}/lib/skills.sh'
        stage_core_skills '${WORK}' '${manifest}'
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"symbolic links are required for RepoMethod skill links"* ]]
    [ ! -e "${WORK}/.agents/skills/foo" ]

    rm -rf -- "$stub_dir"
}

@test "stage_core_skills is a no-op on a repo with no .repomethod/skills directory" {
    empty="$(mktemp -d)"
    manifest="$(manifest_init "0.1.0" "core")"
    result="$(stage_core_skills "$empty" "$manifest")"
    [ "$result" = "$manifest" ]
    rm -rf -- "$empty"
}

@test "stage_core_skills keeps persistently disabled skills inactive" {
    mkdir -p "${WORK}/.repomethod"
    echo "foo" > "${WORK}/.repomethod/disabled-skills.txt"

    manifest="$(manifest_init "0.1.0" "core")"
    manifest="$(stage_core_skills "$WORK" "$manifest")"

    [ ! -e "${WORK}/.agents/skills/foo" ]
    [ ! -e "${WORK}/.claude/skills/foo" ]
    echo "$manifest" | jq -e '.files | length == 0'
}

