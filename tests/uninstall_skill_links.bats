setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/manifest.sh"
    TARGET="$(mktemp -d)"
    git -C "$TARGET" init -q
    mkdir -p "${TARGET}/.agents/skills"
    ln -s "../../.repomethod/skills/demo" "${TARGET}/.agents/skills/demo"
    # Task 10B: manifest_entry_trusted only trusts a skill-link entry whose
    # canonical .repomethod/skills/<name> directory is present. Create it so
    # the entry is verifiable; the first test removes it again to exercise
    # the now-CONFLICT path.
    mkdir -p "${TARGET}/.repomethod/skills/demo"

    manifest="$(manifest_init "0.1.0" "core")"
    manifest="$(manifest_add_file "$manifest" ".agents/skills/demo" \
        "../../.repomethod/skills/demo" "skill-link")"
    manifest_write "$manifest" "${TARGET}/.repomethod/manifest.json"
}

teardown() {
    [ -n "${STAT_STUB_BIN:-}" ] && [ -d "$STAT_STUB_BIN" ] && rm -rf -- "$STAT_STUB_BIN"
    rm -rf -- "$TARGET"
}

@test "uninstall removes a managed skill link whose canonical skill dir is present" {
    [ -L "${TARGET}/.agents/skills/demo" ]

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -L "${TARGET}/.agents/skills/demo" ]
}

# Task 10B behaviour change: a skill-link manifest entry can only be trusted
# while its canonical .repomethod/skills/<name> directory is present (a
# manage-skills.sh-added skill is not in the package blueprint inventory, so
# the canonical directory is the only independent evidence available). If it
# is gone, the link is preserved on disk and reported as a CONFLICT rather
# than removed, and uninstall exits non-zero keeping the manifest whole.
@test "uninstall reports a managed skill link as CONFLICT when its canonical skill dir is absent" {
    rm -rf -- "${TARGET}/.repomethod/skills/demo"
    [ -L "${TARGET}/.agents/skills/demo" ]
    [ ! -e "${TARGET}/.agents/skills/demo" ]

    run "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -ne 0 ]
    [ -L "${TARGET}/.agents/skills/demo" ]
    [[ "$output" == *"CONFLICT"* ]]
    [ -f "${TARGET}/.repomethod/manifest.json" ]
}

@test "uninstall uses GNU file identity output instead of filesystem reports" {
    STAT_STUB_BIN="$(mktemp -d)"
    cat > "${STAT_STUB_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    exit 0
fi
if [ "$1" = "-c" ]; then
    python3 -c 'import os, sys; value = os.stat(sys.argv[1]); print(f"{value.st_dev}:{value.st_ino}")' "$3"
    exit $?
fi
if [ "$1" = "-f" ]; then
    if [ "$3" = "$STAT_TARGET" ]; then
        printf 'filesystem-report:target\n'
    else
        printf 'filesystem-report:outside\n'
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "${STAT_STUB_BIN}/stat"

    run env PATH="${STAT_STUB_BIN}:${PATH}" STAT_TARGET="$TARGET" "${REPO_ROOT}/uninstall.sh" --target "$TARGET"
    [ "$status" -eq 0 ]
    [ ! -L "${TARGET}/.agents/skills/demo" ]
}
