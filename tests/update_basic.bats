setup() {
    load 'test_helper/common-setup'
    _common_setup
    TARGET="$(mktemp -d)"
    git -C "$TARGET" init -q
    "${REPO_ROOT}/install.sh" --target "$TARGET" >/dev/null

    NEW_SRC="$(mktemp -d)/blueprint"
    cp -R "${REPO_ROOT}/blueprint" "$(dirname "$NEW_SRC")"
    echo "updated upstream content" >> "${NEW_SRC}/.repomethod/docs/WORKFLOW_GRAPH.md"
}

teardown() {
    rm -rf -- "$TARGET" "$(dirname "$NEW_SRC")"
}

@test "update.sh updates an unmodified file to the new source version" {
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" == *"updated upstream content"* ]]
}

@test "update.sh keeps a locally modified file and adopts it as a local fork" {
    echo "my local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" == *"my local edit"* ]]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" != *"updated upstream content"* ]]
    [[ "$output" == *"CONFLICT (diverged from upstream, kept as a local fork): .repomethod/docs/WORKFLOW_GRAPH.md"* ]]
    [ "$(jq -r '.files[".repomethod/docs/WORKFLOW_GRAPH.md"].source' "${TARGET}/.repomethod/manifest.json")" = "local" ]
}

@test "an adopted local fork is left alone by later updates, not re-reported" {
    echo "my local edit" >> "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md"
    "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC" >/dev/null
    echo "more upstream churn" >> "${NEW_SRC}/.repomethod/docs/WORKFLOW_GRAPH.md"
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$output" != *"CONFLICT"* ]]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" == *"my local edit"* ]]
    [[ "$(cat "${TARGET}/.repomethod/docs/WORKFLOW_GRAPH.md")" != *"more upstream churn"* ]]
}

@test "update.sh preserves a pre-existing local file at a path newly introduced upstream, across repeated updates and uninstall" {
    mkdir -p "${NEW_SRC}/docs"
    echo "upstream content the user never had before" > "${NEW_SRC}/docs/collide.md"
    mkdir -p "${TARGET}/docs"
    echo "my pre-existing local content" > "${TARGET}/docs/collide.md"

    for _ in 1 2 3; do
        run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
        [ "$status" -eq 0 ]
        [ "$(cat "${TARGET}/docs/collide.md")" = "my pre-existing local content" ]
    done

    run jq -r '.files["docs/collide.md"].source' "${TARGET}/.repomethod/manifest.json"
    [ "$output" = "local" ]

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ -f "${TARGET}/docs/collide.md" ]
    [ "$(cat "${TARGET}/docs/collide.md")" = "my pre-existing local content" ]
}

@test "update refuses a --source that does not exist and leaves the manifest byte-identical" {
    before="$(cat "${TARGET}/.repomethod/manifest.json")"
    before_files="$(find "${TARGET}" -type f | LC_ALL=C sort)"
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "${NEW_SRC}-does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--source is not a directory"* ]]
    [ "$(cat "${TARGET}/.repomethod/manifest.json")" = "$before" ]
    [ "$(find "${TARGET}" -type f | LC_ALL=C sort)" = "$before_files" ]
}

@test "update refuses an incomplete --source and leaves the manifest byte-identical" {
    incomplete="$(mktemp -d)"
    mkdir -p "${incomplete}/.repomethod"
    echo "x" > "${incomplete}/README.md"
    before="$(cat "${TARGET}/.repomethod/manifest.json")"
    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$incomplete"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a blueprint directory"* ]]
    [ "$(cat "${TARGET}/.repomethod/manifest.json")" = "$before" ]
    rm -rf -- "$incomplete"
}

@test "update treats a structurally invalid manifest source as unrecorded and keeps the file" {
    managed=".repomethod/docs/WORKFLOW_GRAPH.md"
    h="$(sha256sum "${TARGET}/${managed}" 2>/dev/null || shasum -a 256 "${TARGET}/${managed}")"
    h="${h%% *}"
    jq --arg h "$h" --arg k "$managed" '.files[$k] = {sha256:$h, source:"bogus"}' \
        "${TARGET}/.repomethod/manifest.json" > "${TARGET}/.repomethod/m.new"
    mv "${TARGET}/.repomethod/m.new" "${TARGET}/.repomethod/manifest.json"

    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONFLICT"* ]] || [[ "$output" == *"KEPT"* ]]
    [[ "$output" == *"${managed}"* ]]
    # kept, not overwritten with the upstream edit
    [[ "$(cat "${TARGET}/${managed}")" != *"updated upstream content"* ]]
    [ "$(jq -r --arg k "$managed" '.files[$k].source' "${TARGET}/.repomethod/manifest.json")" = "local" ]
}

@test "update does not overwrite a repository file forged into the manifest" {
    # Build the forgery fully: src/app.ts is added to the custom --source so
    # it IS a source-list path the update loop visits, but it is NOT in the
    # installed package's blueprint inventory, so the forged blueprint entry
    # is rejected and the user's file is kept as local, never overwritten.
    mkdir -p "${NEW_SRC}/src"
    echo "upstream app" > "${NEW_SRC}/src/app.ts"
    mkdir -p "${TARGET}/src"
    echo "my code" > "${TARGET}/src/app.ts"
    h="$(sha256sum "${TARGET}/src/app.ts" 2>/dev/null || shasum -a 256 "${TARGET}/src/app.ts")"
    h="${h%% *}"
    jq --arg h "$h" '.files["src/app.ts"] = {sha256:$h, source:"blueprint"}' \
        "${TARGET}/.repomethod/manifest.json" > "${TARGET}/.repomethod/m.new"
    mv "${TARGET}/.repomethod/m.new" "${TARGET}/.repomethod/manifest.json"

    run "${REPO_ROOT}/update.sh" --target "$TARGET" --source "$NEW_SRC"
    [ "$status" -eq 0 ]
    [ "$(cat "${TARGET}/src/app.ts")" = "my code" ]
    [ "$(jq -r '.files["src/app.ts"].source' "${TARGET}/.repomethod/manifest.json")" = "local" ]
    [[ "$output" == *"CONFLICT"* ]] || [[ "$output" == *"KEPT"* ]]
}

@test "update.sh dies on a non-git target" {
    plain="$(mktemp -d)"
    run "${REPO_ROOT}/update.sh" --target "$plain" --source "$NEW_SRC"
    [ "$status" -eq 1 ]
    rm -rf -- "$plain"
}

# TOCTOU regression, modelled on tests/uninstall_toctou.bats: update.sh's
# per-file loop checks path containment at the top, then forks sha256_file
# (twice) before the refresh `cp`. A concurrent writer that swaps an
# already-checked ancestor directory for a symlink into .git during that
# window used to make the `cp` follow the link and write through into .git.
# The mitigation re-runs require_path_contained immediately before that `cp`
# (nothing but bash builtins between the two), so the swap is caught and the
# process aborts with the victim untouched. The swap is synchronized to the
# `current_hash="$(sha256_file "$dst_file")"` line via a marker file.
#
# The managed file is a real package-blueprint inventory path
# (.repomethod/skills/ship-pr/scripts/preflight.sh) so it passes the Task 10B
# inventory cross-check and the loop still reaches the refresh `cp`; the
# swappable ancestor is its own scripts/ directory.
@test "update.sh survives an ancestor swap timed against the hash computation" {
    t="$(mktemp -d)"
    git -C "$t" init -q

    mkdir -p "${t}/.git/danger"
    echo "original content" > "${t}/.git/danger/file.txt"

    # Managed file, unmodified relative to its recorded hash, under an
    # ancestor directory the attacker can swap.
    managed=".repomethod/skills/ship-pr/scripts/preflight.sh"
    mkdir -p "${t}/.repomethod/skills/ship-pr/scripts"
    echo "original content" > "${t}/${managed}"
    hash="$(sha256sum "${t}/${managed}" 2>/dev/null || shasum -a 256 "${t}/${managed}")"
    hash="${hash%% *}"

    cat > "${t}/.repomethod/manifest.json" <<EOF
{"version":"0.1.0","installed_at":"2026-07-19T00:00:00Z","profiles":["core"],"files":{"${managed}":{"sha256":"${hash}","source":"blueprint"}}}
EOF

    # Minimal blueprint source: only the three files update.sh probes for,
    # plus the one managed file. The managed file is the only entry that
    # reaches the hash-computation anchor, so the marker fires on it.
    src="$(mktemp -d)/blueprint"
    mkdir -p "${src}/.repomethod/scripts" "${src}/.repomethod/skills/ship-pr/scripts"
    echo "stub" > "${src}/AGENTS.md"
    echo "stub" > "${src}/CLAUDE.md"
    echo "stub" > "${src}/.repomethod/scripts/agent-gate.sh"
    echo "updated upstream content" > "${src}/${managed}"

    marker="$(mktemp -u)"
    stderr_log="$(mktemp -u)"

    instrumented="${REPO_ROOT}/.update_toctou_test_instrumented.sh"
    sed "s|current_hash=\"\$(sha256_file \"\$dst_file\")\"|&; touch '${marker}'; sleep 1|" \
        "${REPO_ROOT}/update.sh" > "$instrumented"
    chmod +x "$instrumented"
    grep -q "touch '${marker}'" "$instrumented"

    "$instrumented" --target "$t" --source "$src" >/dev/null 2>"$stderr_log" &
    pid=$!

    for _ in $(seq 1 50); do
        [ -e "$marker" ] && break
        sleep 0.1
    done
    [ -e "$marker" ]

    rm -rf "${t}/.repomethod/skills/ship-pr/scripts"
    ln -s "${t}/.git/danger" "${t}/.repomethod/skills/ship-pr/scripts"

    rc=0
    wait "$pid" || rc=$?

    rm -f "$instrumented" "$marker"

    # The .git victim must be byte-unchanged and the run must have refused
    # rather than written through the swapped-in symlink.
    [ "$(cat "${t}/.git/danger/file.txt")" = "original content" ]
    [ "$rc" -ne 0 ]
    grep -q "refusing to write through an existing symlink" "$stderr_log"

    rm -f "$stderr_log"
    rm -rf -- "$t" "$(dirname "$src")"
}
