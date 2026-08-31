setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    source "${REPO_ROOT}/lib/blueprint.sh"
    source "${REPO_ROOT}/lib/pointer.sh"
    register_cleanup_trap
    TARGET="$(mktemp -d)"
    git -C "$TARGET" init -q
}

@test "blueprint_source_dir points at this repo's blueprint directory" {
    run blueprint_source_dir
    [ "$status" -eq 0 ]
    [ -f "${output}/AGENTS.md" ]
}

@test "blueprint_list_files lists AGENTS.md and CLAUDE.md" {
    src="$(blueprint_source_dir)"
    run blueprint_list_files "$src"
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"CLAUDE.md"* ]]
    [[ "$output" == *".repomethod/templates/plan.md"* ]]
    [[ "$output" == *".repomethod/templates/spec-packet.md"* ]]
    [[ "$output" == *".repomethod/skills/quick-mvp/SKILL.md"* ]]
    [[ "$output" == *".repomethod/skills/classic-loop/SKILL.md"* ]]
    [[ "$output" == *".repomethod/skills/scoped-delivery/SKILL.md"* ]]
    [[ "$output" == *".repomethod/skills/graph-delivery/SKILL.md"* ]]
    [[ "$output" == *".repomethod/scripts/workflow-graph.sh"* ]]
    [[ "$output" == *".repomethod/docs/WORKFLOW_GRAPH.md"* ]]
}

@test "blueprint_list_files excludes .DS_Store, editor swap files, and backups" {
    src="$(mktemp -d)"
    touch "${src}/normal.txt"
    touch "${src}/.DS_Store"
    touch "${src}/notes.txt.swp"
    touch "${src}/.notes.txt.swp"
    touch "${src}/file~"
    touch "${src}/file.bak"
    touch "${src}/file.orig"
    touch "${src}/Thumbs.db"
    run blueprint_list_files "$src"
    [[ "$output" == *"normal.txt"* ]]
    [[ "$output" != *"DS_Store"* ]]
    [[ "$output" != *".swp"* ]]
    [[ "$output" != *"file~"* ]]
    [[ "$output" != *".bak"* ]]
    [[ "$output" != *".orig"* ]]
    [[ "$output" != *"Thumbs.db"* ]]
    rm -rf -- "$src"
}

@test "blueprint_list_files does NOT exclude an intentionally managed dotfile" {
    src="$(mktemp -d)"
    mkdir -p "${src}/.repomethod"
    echo "infra/**" > "${src}/.repomethod/protected-zones.txt"
    touch "${src}/.gitignore"
    run blueprint_list_files "$src"
    [[ "$output" == *".repomethod/protected-zones.txt"* ]]
    [[ "$output" == *".gitignore"* ]]
    rm -rf -- "$src"
}

@test "blueprint_list_files works from a plain extracted directory with no .git (release-tarball scenario)" {
    src="$(mktemp -d)"
    touch "${src}/AGENTS.md" "${src}/.DS_Store"
    # No git init here at all — simulates a release tarball extraction,
    # confirming the filter has no dependency on git ls-files.
    run blueprint_list_files "$src"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" != *"DS_Store"* ]]
    rm -rf -- "$src"
}

@test "blueprint_list_files fails loudly when find cannot read a subdirectory" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "running as root: chmod 000 does not block traversal"
    fi
    src="$(mktemp -d)"
    touch "${src}/AGENTS.md" "${src}/CLAUDE.md"
    mkdir -p "${src}/.repomethod/scripts"
    touch "${src}/.repomethod/scripts/agent-gate.sh"
    mkdir "${src}/locked"
    touch "${src}/locked/hidden.txt"
    chmod 000 "${src}/locked"

    run blueprint_list_files "$src"

    chmod -R u+rwx "$src"
    rm -rf -- "$src"

    [ "$status" -ne 0 ]
    [[ "$output" == *"$src"* ]]
}

@test "stage_blueprint never adds excluded cruft to the manifest from the real blueprint source" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    run jq -r '.files | keys[]' "${TARGET}/.repomethod/manifest.json"
    [[ "$output" != *"DS_Store"* ]]
    [[ "$output" != *".swp"* ]]
}

@test "stage_blueprint in strict mode copies files into an empty target" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    [ -f "${TARGET}/AGENTS.md" ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
    [ -f "${TARGET}/.repomethod/templates/plan.md" ]
    [ -f "${TARGET}/.repomethod/templates/spec-packet.md" ]
    [ -f "${TARGET}/.repomethod/skills/quick-mvp/SKILL.md" ]
    [ -f "${TARGET}/.repomethod/skills/classic-loop/SKILL.md" ]
    [ -f "${TARGET}/.repomethod/skills/scoped-delivery/SKILL.md" ]
    [ -f "${TARGET}/.repomethod/skills/graph-delivery/SKILL.md" ]
    [ -f "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md" ]
    [ -x "${TARGET}/.repomethod/scripts/feature-workflow.sh" ]
    [ -x "${TARGET}/.repomethod/scripts/manage-skills.sh" ]
    [ -x "${TARGET}/.repomethod/scripts/workflow-graph.sh" ]
    jq -e '.files["AGENTS.md"].sha256 | length > 0' "${TARGET}/.repomethod/manifest.json"
}

@test "stage_blueprint installs RepoMethod's own tooling under .repomethod/, not host-generic paths" {
    stage_blueprint "$TARGET" "strict" "0.0.1" "core"
    [ -x "${TARGET}/.repomethod/scripts/agent-gate.sh" ]
    [ -x "${TARGET}/.repomethod/scripts/verify.sh" ]
    [ -f "${TARGET}/.repomethod/templates/spec.md" ]
    [ -f "${TARGET}/.repomethod/templates/spec-packet.md" ]
    [ -f "${TARGET}/.repomethod/templates/plan.md" ]
    [ -f "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md" ]
    [ -f "${TARGET}/.repomethod/.gitignore" ]
    [ ! -e "${TARGET}/scripts" ]
    [ ! -e "${TARGET}/docs" ]
    [ ! -e "${TARGET}/plans" ]
    [ ! -f "${TARGET}/.gitignore" ]
    [ ! -e "${TARGET}/Makefile" ]
    [ -f "${TARGET}/.github/workflows/repomethod-verify.yml" ]
    [ ! -e "${TARGET}/.github/workflows/verify.yml" ]
}

@test "specs/ and plans/ directories are never created by a fresh install" {
    stage_blueprint "$TARGET" "strict" "0.0.1" "core"
    [ ! -d "${TARGET}/specs" ]
    [ ! -d "${TARGET}/plans" ]
}

@test "stage_blueprint installs canonical skills under .repomethod/skills/, not .agent-shared/" {
    stage_blueprint "$TARGET" "strict" "0.0.1" "core"
    [ -f "${TARGET}/.repomethod/skills/quick-mvp/SKILL.md" ]
    [ ! -e "${TARGET}/.agent-shared" ]
}

@test "core-profile install links .agents/skills/<name> to .repomethod/skills/<name>" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    [ "$(readlink "${TARGET}/.agents/skills/quick-mvp")" = "../../.repomethod/skills/quick-mvp" ]
    [ "$(readlink "${TARGET}/.claude/skills/quick-mvp")" = "../../.repomethod/skills/quick-mvp" ]
}

@test "install.sh inserts only a pointer block into a pre-existing AGENTS.md, never overwrites it, mode unchanged" {
    printf '# Our Project\n\nOur own house rules.\n' > "${TARGET}/AGENTS.md"
    before_mode="$(stat -c '%a' "${TARGET}/AGENTS.md" 2>/dev/null || stat -f '%Lp' "${TARGET}/AGENTS.md")"
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    run grep -F "Our own house rules." "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/AGENTS.md" "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.repomethod/AGENTS.md" ]
    run grep -F "## Delivery Modes" "${TARGET}/.repomethod/AGENTS.md"
    [ "$status" -eq 0 ]
    after_mode="$(stat -c '%a' "${TARGET}/AGENTS.md" 2>/dev/null || stat -f '%Lp' "${TARGET}/AGENTS.md")"
    [ "$before_mode" = "$after_mode" ]
}

@test "install.sh creates a minimal AGENTS.md with just header + pointer block when none exists" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/AGENTS.md" "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
}

@test "install.sh's pointer preflight refuses a malformed AGENTS.md before writing any other blueprint file" {
    printf '%s\nstray content\n%s\n' \
        '<!-- repomethod:end -->' '<!-- repomethod:begin -->' > "${TARGET}/AGENTS.md"
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ ! -e "${TARGET}/.repomethod/scripts" ]
    [ ! -e "${TARGET}/.repomethod/skills" ]
    [ ! -L "${TARGET}/.agents/skills/quick-mvp" ]
}

@test "uninstall.sh deletes a self-created, still-untouched AGENTS.md entirely" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -e "${TARGET}/AGENTS.md" ]
}

@test "uninstall.sh removes only the pointer block from a pre-existing AGENTS.md, keeps the rest and its mode" {
    printf '# Our Project\n\nOur own house rules.\n' > "${TARGET}/AGENTS.md"
    before_mode="$(stat -c '%a' "${TARGET}/AGENTS.md" 2>/dev/null || stat -f '%Lp' "${TARGET}/AGENTS.md")"
    "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/AGENTS.md" ]
    run grep -F "Our own house rules." "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/AGENTS.md" "${TARGET}/AGENTS.md"
    [ "$status" -ne 0 ]
    after_mode="$(stat -c '%a' "${TARGET}/AGENTS.md" 2>/dev/null || stat -f '%Lp' "${TARGET}/AGENTS.md")"
    [ "$before_mode" = "$after_mode" ]
}

@test "staged agent instructions define cloud execution boundaries" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    run grep -F "Cloud tasks must be reproducible from a clean remote checkout." "${TARGET}/.repomethod/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "GitHub Actions Secrets" "${TARGET}/.repomethod/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "Platform and Console are separate repositories." "${TARGET}/.repomethod/AGENTS.md"
    [ "$status" -ne 0 ]
}

@test "staged target CI uses the current checkout action" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    run grep -F "uses: actions/checkout@v5" "${TARGET}/.github/workflows/repomethod-verify.yml"
    [ "$status" -eq 0 ]
}

@test "stage_blueprint is idempotent when re-run in strict mode" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    prior="$(cat "${TARGET}/.repomethod/manifest.json")"
    run stage_blueprint "$TARGET" "strict" "0.1.0" "core" "$prior"
    [ "$status" -eq 0 ]
}

@test "stage_blueprint in strict mode dies on conflicting local content" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
}

@test "stage_blueprint refuses to read through a symlinked target file before hashing or diffing it" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    OUTSIDE="$(mktemp -d)"
    echo "UNIQUE-SECRET-MARKER-93f7c2" > "${OUTSIDE}/secret.txt"
    rm -f "${TARGET}/AGENTS.md"
    ln -s "${OUTSIDE}/secret.txt" "${TARGET}/AGENTS.md"

    run stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [[ "$output" != *"UNIQUE-SECRET-MARKER-93f7c2"* ]]
    [ "$(cat "${OUTSIDE}/secret.txt")" = "UNIQUE-SECRET-MARKER-93f7c2" ]

    rm -rf -- "$OUTSIDE"
}

@test "stage_blueprint rejects a symlinked ancestor before writing any blueprint file" {
    # Pass 1 is supposed to be pure detection — no writes until it fully
    # clears. A not-yet-existing leaf under a symlinked ancestor (.repomethod/
    # here) used to slip past pass 1's "doesn't exist, skip" check
    # entirely, since it never called require_path_contained for that
    # file. Pass 2 still caught it before writing INTO the symlink, but by
    # then unrelated files that sort earlier (e.g. AGENTS.md) could
    # already have been written to target_dir.
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod"

    run stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    [ "$status" -ne 0 ]
    [ ! -e "${TARGET}/AGENTS.md" ]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "stage_blueprint in merge mode preserves local changes" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    prior="$(cat "${TARGET}/.repomethod/manifest.json")"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run stage_blueprint "$TARGET" "preserve" "0.1.0" "core" "$prior"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" == *"local edit"* ]]
}

@test "stage_blueprint in merge mode marks the kept file as local, not blueprint-owned" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    prior="$(cat "${TARGET}/.repomethod/manifest.json")"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    stage_blueprint "$TARGET" "preserve" "0.1.0" "core" "$prior"
    jq -e '.files[".repomethod/docs/WORKFLOW_GRAPH.md"].source == "local"' "${TARGET}/.repomethod/manifest.json"
}

@test "stage_blueprint in backup mode overwrites and keeps a backup copy" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    prior="$(cat "${TARGET}/.repomethod/manifest.json")"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run stage_blueprint "$TARGET" "backup" "0.1.0" "core" "$prior"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" != *"local edit"* ]]
    backup_count="$(find "${TARGET}/.repomethod/backups" -name WORKFLOW_GRAPH.md | wc -l | tr -d ' ')"
    [ "$backup_count" -eq 1 ]
}

@test "stage_blueprint in force mode overwrites without backup" {
    stage_blueprint "$TARGET" "strict" "0.1.0" "core"
    prior="$(cat "${TARGET}/.repomethod/manifest.json")"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run stage_blueprint "$TARGET" "force" "0.1.0" "core" "$prior"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" != *"local edit"* ]]
    [ ! -d "${TARGET}/.repomethod/backups" ]
}

@test "install.sh --dry-run makes no changes" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "${TARGET}/AGENTS.md" ]
    [ ! -d "${TARGET}/.repomethod" ]
    [[ "$output" == *"AGENTS.md"* ]]
}

@test "install.sh dies on a non-git target" {
    plain="$(mktemp -d)"
    run "${REPO_ROOT}/install.sh" --target "$plain"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a git repository"* ]]
    rm -rf -- "$plain"
}

@test "install.sh installs into an empty target repo with default (bare) arguments" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/AGENTS.md" ]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
}

@test "install.sh with default arguments is idempotent" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    run "${REPO_ROOT}/install.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
}

@test "install.sh with default arguments refuses to overwrite a conflicting file" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    echo "local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run "${REPO_ROOT}/install.sh" --target "$TARGET"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
}

@test "install.sh never creates a nested .git directory in the target" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    # -mindepth 2: TARGET's own top-level .git (from `git init` in setup) is
    # expected and legitimate; this test only cares about a .git directory
    # nested inside a subdirectory, which would indicate install.sh copied
    # or created an unwanted embedded repository.
    count="$(find "$TARGET" -mindepth 2 -name .git | wc -l | tr -d ' ')"
    [ "$count" -eq 0 ]
}

@test "core-profile install links every canonical skill into .agents/skills and .claude/skills" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET"
    [ "$status" -eq 0 ]

    for name in repo-onboarding security-review dependency-upgrade docs-sync compliance-review ship-pr scoped-delivery; do
        [ -L "${TARGET}/.agents/skills/${name}" ]
        [ -L "${TARGET}/.claude/skills/${name}" ]
        [ -f "${TARGET}/.agents/skills/${name}/SKILL.md" ]
        [ -f "${TARGET}/.claude/skills/${name}/SKILL.md" ]
    done
}

@test "core-profile install records skill-link provenance in the manifest" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    manifest="$(jq '.' "${TARGET}/.repomethod/manifest.json")"
    echo "$manifest" | jq -e '.files[".agents/skills/repo-onboarding"].source == "skill-link"'
    echo "$manifest" | jq -e '.files[".claude/skills/ship-pr"].source == "skill-link"'
}

@test "re-running a core install is idempotent: links stay symlinks" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    before="$(readlink "${TARGET}/.agents/skills/repo-onboarding")"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --force
    [ "$status" -eq 0 ]
    [ -L "${TARGET}/.agents/skills/repo-onboarding" ]
    [ "$(readlink "${TARGET}/.agents/skills/repo-onboarding")" = "$before" ]
}

@test "update.sh re-syncs skill links without spurious orphan warnings" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" != *"no longer tracked upstream"*".agents/skills"* ]]
    [ -L "${TARGET}/.agents/skills/repo-onboarding" ]
}

@test "uninstall.sh removes unmodified skill links without touching the canonical skill directory prematurely" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -e "${TARGET}/.agents/skills/repo-onboarding" ]
    [ ! -L "${TARGET}/.agents/skills/repo-onboarding" ]
}

@test "uninstall.sh keeps a skill link the user repointed locally" {
    "${REPO_ROOT}/install.sh" --target "$TARGET"
    rm "${TARGET}/.agents/skills/repo-onboarding"
    ln -s /tmp "${TARGET}/.agents/skills/repo-onboarding"

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEPT (locally modified): .agents/skills/repo-onboarding"* ]]
    [ -L "${TARGET}/.agents/skills/repo-onboarding" ]
    [ "$(readlink "${TARGET}/.agents/skills/repo-onboarding")" = "/tmp" ]
}

@test "default core profile installs offline with first-party skills only" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline

    [ "$status" -eq 0 ]
    [ -L "${TARGET}/.agents/skills/quick-mvp" ]
    [ -L "${TARGET}/.claude/skills/graph-delivery" ]
    [ ! -e "${TARGET}/.repomethod/skills/skill-creator" ]
    [ ! -e "${TARGET}/.repomethod/skills/brainstorming" ]
    [ ! -e "${TARGET}/.repomethod/external-tools.md" ]
    jq -e '.profiles == ["core"]' "${TARGET}/.repomethod/manifest.json"
}

@test "install.sh --preserve keeps a pre-existing file, and update.sh never overwrites it afterward" {
    mkdir -p "${TARGET}/.repomethod/docs"
    echo "my own docs, never repomethod's" > "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline --preserve
    [ "$status" -eq 0 ]
    [ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" = "my own docs, never repomethod's" ]
    jq -e '.files[".repomethod/docs/WORKFLOW_GRAPH.md"].source == "local"' "${TARGET}/.repomethod/manifest.json"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" = "my own docs, never repomethod's" ]
}

@test "install.sh --preserve keeps a pre-existing file, and uninstall.sh never deletes it afterward" {
    mkdir -p "${TARGET}/.repomethod/docs"
    echo "my own docs, never repomethod's" > "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline --preserve
    [ "$status" -eq 0 ]

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md" ]
    [ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" = "my own docs, never repomethod's" ]
}

@test "install.sh aborts on a foreign skill folder and leaves its content untouched" {
    mkdir -p "${TARGET}/.agents/skills/quick-mvp"
    echo "not repomethod's" > "${TARGET}/.agents/skills/quick-mvp/NOT_MINE.txt"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ -f "${TARGET}/.agents/skills/quick-mvp/NOT_MINE.txt" ]
    [ ! -L "${TARGET}/.agents/skills/quick-mvp" ]
}

@test "install.sh's skill-link preflight refuses a foreign collision before writing any blueprint file" {
    mkdir -p "${TARGET}/.claude/skills/quick-mvp"
    echo "not repomethod's" > "${TARGET}/.claude/skills/quick-mvp/NOT_MINE.txt"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ ! -e "${TARGET}/AGENTS.md" ]
    [ ! -d "${TARGET}/.repomethod" ]
    [ -f "${TARGET}/.claude/skills/quick-mvp/NOT_MINE.txt" ]
}

@test "install.sh refuses to write through a symlinked directory that escapes the target repository" {
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "install.sh refuses a symlinked .agents parent before creating any skill link outside the repository" {
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${TARGET}/.agents"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "install.sh refuses a symlinked .claude parent before creating any skill link outside the repository" {
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${TARGET}/.claude"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "install.sh --backup refuses a symlinked .repomethod before creating a backups directory outside the repository" {
    OUTSIDE="$(mktemp -d)"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline --backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -z "$(ls -A "$OUTSIDE")" ]

    rm -rf -- "$OUTSIDE"
}

@test "update.sh refuses a symlinked .repomethod before reading or writing the manifest outside the repository" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]

    OUTSIDE="$(mktemp -d)"
    cp "${TARGET}/.repomethod/manifest.json" "${OUTSIDE}/manifest.json"
    before_hash="$(sha256_file "${OUTSIDE}/manifest.json")"
    rm -rf "${TARGET}/.repomethod"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ "$(sha256_file "${OUTSIDE}/manifest.json")" = "$before_hash" ]

    rm -rf -- "$OUTSIDE"
}

@test "uninstall.sh refuses a symlinked .repomethod rather than deleting the manifest it points to" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]

    OUTSIDE="$(mktemp -d)"
    cp "${TARGET}/.repomethod/manifest.json" "${OUTSIDE}/manifest.json"
    rm -rf "${TARGET}/.repomethod"
    ln -s "$OUTSIDE" "${TARGET}/.repomethod"

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -f "${OUTSIDE}/manifest.json" ]

    rm -rf -- "$OUTSIDE"
}

@test "install.sh refuses to write into .git even via a symlinked path component" {
    # Regression test: an ancestor symlink whose target lies INSIDE the
    # target repo (unlike the "escapes the target repository" case above,
    # which points fully outside) used to defeat the identity-based ".."
    # ascent in require_path_contained — appending "/.." to a path through
    # a symlink dereferences it first and ascends from the resolved
    # location's parent, landing back at target_id without the walk ever
    # comparing against git_id.
    ln -s "${TARGET}/.git" "${TARGET}/.repomethod"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing symlink"* ]]
    [ -d "${TARGET}/.git/objects" ]
}

@test "update.sh refuses to write through a symlinked managed file that escapes the target repository" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]

    OUTSIDE_FILE="$(mktemp -d)/AGENTS.md"
    echo "outside content, must never be touched" > "$OUTSIDE_FILE"
    rm -f "${TARGET}/AGENTS.md"
    ln -s "$OUTSIDE_FILE" "${TARGET}/AGENTS.md"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [ "$(cat "$OUTSIDE_FILE")" = "outside content, must never be touched" ]

    rm -rf -- "$(dirname "$OUTSIDE_FILE")"
}

@test "install.sh hard-fails with no copy fallback when ln is unavailable" {
    stub_dir="$(mktemp -d)"
    cat > "${stub_dir}/ln" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_dir}/ln"

    run env PATH="${stub_dir}:${PATH}" "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -ne 0 ]
    [[ "$output" == *"symbolic links are required for RepoMethod skill links"* ]]
    [ ! -e "${TARGET}/.agents/skills/quick-mvp" ]

    rm -rf -- "$stub_dir"
}

@test "install.sh's fresh-install preflight refuses a foreign correct-looking skill symlink, untouched" {
    # A symlink whose readlink output already matches what repomethod would
    # create is not, on its own, proof repomethod created it — this must be
    # refused exactly like any other unrecorded foreign path, on the very
    # first install where no manifest.json has ever existed yet.
    mkdir -p "${TARGET}/.agents/skills"
    ln -s "../../.repomethod/skills/quick-mvp" "${TARGET}/.agents/skills/quick-mvp"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [ -L "${TARGET}/.agents/skills/quick-mvp" ]
    [ "$(readlink "${TARGET}/.agents/skills/quick-mvp")" = "../../.repomethod/skills/quick-mvp" ]
    [ ! -e "${TARGET}/AGENTS.md" ]
    [ ! -e "${TARGET}/.repomethod/manifest.json" ]
}

@test "update.sh refuses to link through a foreign directory occupying a skill's managed path, without deleting it" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]

    # A real directory sitting where a skill symlink belongs, with no
    # manifest record proving repomethod put it there — e.g. leftover
    # content from an incompatible install mechanism, or something the
    # user created by hand. Under the current model this is simply an
    # unrecorded foreign path; no special legacy handling is involved.
    rm -rf "${TARGET}/.agents/skills/quick-mvp"
    cp -R "${TARGET}/.repomethod/skills/quick-mvp" "${TARGET}/.agents/skills/quick-mvp"
    manifest="${TARGET}/.repomethod/manifest.json"
    jq 'del(.files[".agents/skills/quick-mvp"])' \
        "$manifest" > "${manifest}.tmp"
    mv "${manifest}.tmp" "$manifest"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [[ "$output" == *"conflict"* ]]
    [ -d "${TARGET}/.agents/skills/quick-mvp" ]
    [ -f "${TARGET}/.agents/skills/quick-mvp/SKILL.md" ]
    [ ! -L "${TARGET}/.agents/skills/quick-mvp" ]
}

@test "update.sh preserves a locally modified file across repeated updates" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    echo "my local edit, must survive repeated updates" >> "${TARGET}/AGENTS.md"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/AGENTS.md")" == *"my local edit, must survive repeated updates"* ]]

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/AGENTS.md")" == *"my local edit, must survive repeated updates"* ]]

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/AGENTS.md")" == *"my local edit, must survive repeated updates"* ]]
}

@test "update.sh refuses a manifest recording a legacy non-core profile" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    manifest="${TARGET}/.repomethod/manifest.json"
    jq '.profiles = ["core","extended"]' "$manifest" > "${manifest}.tmp" && mv "${manifest}.tmp" "$manifest"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 1 ]
    [[ "$output" == *"legacy external profiles"* ]]
    [[ "$output" == *"uninstall.sh"* ]]
}

@test "update.sh leaves an existing repomethod-owned skill symlink untouched and idempotent" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    before="$(readlink "${TARGET}/.agents/skills/quick-mvp")"

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -L "${TARGET}/.agents/skills/quick-mvp" ]
    [ "$(readlink "${TARGET}/.agents/skills/quick-mvp")" = "$before" ]
}

@test "install/update/uninstall coexist with a Speckit-shaped repository: bytes and modes untouched" {
    mkdir -p "${TARGET}/.specify/memory" "${TARGET}/.agents/skills/speckit-specify" \
        "${TARGET}/.claude/skills/speckit-specify"
    echo "# Constitution" > "${TARGET}/.specify/memory/constitution.md"
    echo "speckit skill" > "${TARGET}/.agents/skills/speckit-specify/SKILL.md"
    echo "speckit skill" > "${TARGET}/.claude/skills/speckit-specify/SKILL.md"

    cat > "${TARGET}/Makefile" <<'EOF'
frontend-check:
	pnpm test
EOF
    printf '.venv/\nnode_modules/\n' > "${TARGET}/.gitignore"
    printf '# Our Project\n\nOur own house rules.\n' > "${TARGET}/AGENTS.md"
    printf '# Claude notes\n\nOur own Claude-specific notes.\n' > "${TARGET}/CLAUDE.md"
    chmod 644 "${TARGET}/Makefile" "${TARGET}/.gitignore" "${TARGET}/AGENTS.md" "${TARGET}/CLAUDE.md"

    _mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
    makefile_before="$(sha256_file "${TARGET}/Makefile")"
    gitignore_before="$(sha256_file "${TARGET}/.gitignore")"
    agents_mode_before="$(_mode "${TARGET}/AGENTS.md")"

    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]

    [ "$(sha256_file "${TARGET}/Makefile")" = "$makefile_before" ]
    [ "$(sha256_file "${TARGET}/.gitignore")" = "$gitignore_before" ]
    [ "$(_mode "${TARGET}/AGENTS.md")" = "$agents_mode_before" ]
    run grep -F "Our own house rules." "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F "Our own Claude-specific notes." "${TARGET}/CLAUDE.md"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/.specify/memory/constitution.md" ]
    [ -f "${TARGET}/.agents/skills/speckit-specify/SKILL.md" ]
    [ "$(readlink "${TARGET}/.agents/skills/quick-mvp")" = "../../.repomethod/skills/quick-mvp" ]

    run "${REPO_ROOT}/update.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(sha256_file "${TARGET}/Makefile")" = "$makefile_before" ]
    [ "$(sha256_file "${TARGET}/.gitignore")" = "$gitignore_before" ]
    [ "$(_mode "${TARGET}/AGENTS.md")" = "$agents_mode_before" ]
    run grep -F "Our own house rules." "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(sha256_file "${TARGET}/Makefile")" = "$makefile_before" ]
    [ "$(sha256_file "${TARGET}/.gitignore")" = "$gitignore_before" ]
    [ "$(_mode "${TARGET}/AGENTS.md")" = "$agents_mode_before" ]
    run grep -F "Our own house rules." "${TARGET}/AGENTS.md"
    [ "$status" -eq 0 ]
    run grep -F ".repomethod/AGENTS.md" "${TARGET}/AGENTS.md"
    [ "$status" -ne 0 ]
    [ -f "${TARGET}/.specify/memory/constitution.md" ]
    [ -f "${TARGET}/.agents/skills/speckit-specify/SKILL.md" ]
    [ ! -e "${TARGET}/.agents/skills/quick-mvp" ]
}

@test "installed gitignore ignores evidence scratch files" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    mkdir -p "${TARGET}/.repomethod/evidence"
    touch "${TARGET}/.repomethod/evidence/x.scratch"
    git -C "$TARGET" check-ignore -q .repomethod/evidence/x.scratch
}

@test "installed .repomethod/.gitignore ignores transient state and nothing managed" {
    run "${REPO_ROOT}/install.sh" --target "$TARGET" --offline
    [ "$status" -eq 0 ]
    mkdir -p "${TARGET}/.repomethod/workflows" "${TARGET}/.repomethod/backups/run1"
    touch "${TARGET}/.repomethod/manifest.json.tmp.abc123" \
          "${TARGET}/.repomethod/disabled-skills.txt.tmp.def456" \
          "${TARGET}/.repomethod/workflows/feat.json.tmp.xyz789" \
          "${TARGET}/.repomethod/workflows/feat.json.lock" \
          "${TARGET}/.repomethod/workflows/feat.supervisor.json" \
          "${TARGET}/.repomethod/workflows/feat.dispatch.md" \
          "${TARGET}/.repomethod/workflows/feat.json" \
          "${TARGET}/.repomethod/workflows/feat.handoff.json" \
          "${TARGET}/.repomethod/backups/run1/AGENTS.md"

    git -C "$TARGET" check-ignore -q .repomethod/manifest.json.tmp.abc123
    git -C "$TARGET" check-ignore -q .repomethod/disabled-skills.txt.tmp.def456
    git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.json.tmp.xyz789
    git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.json.lock
    git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.supervisor.json
    git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.dispatch.md
    git -C "$TARGET" check-ignore -q .repomethod/backups/run1/AGENTS.md

    # the workflow state and the agent handoff stay committable
    run git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.json
    [ "$status" -ne 0 ]
    run git -C "$TARGET" check-ignore -q .repomethod/workflows/feat.handoff.json
    [ "$status" -ne 0 ]
    run git -C "$TARGET" check-ignore -q .repomethod/scripts/verify.sh
    [ "$status" -ne 0 ]
    run git -C "$TARGET" check-ignore -q .repomethod/AGENTS.md
    [ "$status" -ne 0 ]
    run git -C "$TARGET" check-ignore -q .repomethod/verify-command
    [ "$status" -ne 0 ]
}
