setup() {
    load 'test_helper/common-setup'
    _common_setup
}

# Regression test for a real TOCTOU race found during Phase 1 review:
# uninstall.sh's containment check (device:inode ancestor walk) correctly
# refuses to remove a manifest path when an ancestor directory IS a symlink
# into .git at the time the check runs. But the check used to run, then
# sha256_file() forked an external process to hash the file, and only THEN
# did the script rm it. That gap was wide enough (dominated by the
# sha256sum/shasum fork+exec) for a concurrent writer to swap a
# still-legitimate ancestor directory for a symlink into .git after the
# check passed but before the rm — deleting a real file inside .git.
#
# This test proves the fix (hashing before the check, so the check is the
# last thing before rm) by re-running the exact attack with the swap
# deterministically synchronized (via a marker file, not a fixed sleep — a
# fixed sleep made this flaky under system load) to land immediately after
# the hash computation — the worst case for the CURRENT code ordering. If a
# future change moves the hash computation back to after the check
# (reintroducing the original bug), the injected marker+sleep land right
# before rm instead, the swap succeeds, and this test fails.
@test "uninstall.sh survives an ancestor-directory-symlink swap timed against the hash computation" {
    target="$(mktemp -d)"
    git -C "$target" init -q

    # The managed file is a real package-blueprint inventory path so it
    # passes the Task 10B inventory cross-check and the loop still reaches the
    # containment ascent / rm; its own scripts/ directory is the swappable
    # ancestor. After the swap, dst_file
    # (.repomethod/skills/ship-pr/scripts/preflight.sh) resolves to
    # .git/danger/preflight.sh, so THAT is the file a regressed uninstall.sh
    # (hash computed after the ascent) would rm — plant a real victim there
    # with content matching the recorded hash so the regressed rm actually
    # fires.
    managed=".repomethod/skills/ship-pr/scripts/preflight.sh"
    mkdir -p "${target}/.git/danger"
    echo "original content" > "${target}/.git/danger/preflight.sh"

    mkdir -p "${target}/.repomethod/skills/ship-pr/scripts"
    echo "original content" > "${target}/${managed}"
    hash="$(sha256sum "${target}/${managed}" 2>/dev/null || shasum -a 256 "${target}/${managed}")"
    hash="${hash%% *}"

    cat > "${target}/.repomethod/manifest.json" <<EOF
{"version":"0.1.0","installed_at":"2026-07-19T00:00:00Z","profiles":["core"],"files":{"${managed}":{"sha256":"${hash}","source":"blueprint"}}}
EOF

    marker="$(mktemp -u)"
    stderr_log="$(mktemp -u)"

    # Instrumented copy: touch a marker and sleep immediately after the hash
    # computation line (the anchor), so the test can deterministically wait
    # for the script to reach that exact point before racing it, instead of
    # guessing a fixed delay.
    instrumented="${REPO_ROOT}/.uninstall_toctou_test_instrumented.sh"
    sed "s|current_hash=\"\$(sha256_file \"\$dst_file\")\"|current_hash=\"\$(sha256_file \"\$dst_file\")\"; touch '${marker}'; sleep 1|" \
        "${REPO_ROOT}/uninstall.sh" > "$instrumented"
    chmod +x "$instrumented"
    # Sanity: the anchor must actually have matched, or this test would
    # pass vacuously (no delay injected, nothing raced).
    grep -q "touch '${marker}'" "$instrumented"

    "$instrumented" --target "$target" >/dev/null 2>"$stderr_log" &
    pid=$!

    for _ in $(seq 1 50); do
        [ -e "$marker" ] && break
        sleep 0.1
    done
    [ -e "$marker" ]

    rm -rf "${target}/.repomethod/skills/ship-pr/scripts"
    ln -s "${target}/.git/danger" "${target}/.repomethod/skills/ship-pr/scripts"

    wait "$pid" || true

    rm -f "$instrumented" "$marker"

    # Victim inside .git byte-unchanged, AND the containment ascent must have
    # positively refused — without this grep a regressed sink (hash after the
    # ascent) that rm'd a non-existent path would still pass vacuously.
    [ -f "${target}/.git/danger/preflight.sh" ]
    [ "$(cat "${target}/.git/danger/preflight.sh")" = "original content" ]
    grep -qF -- "refusing to remove unsafe manifest path (inside .git)" "$stderr_log"

    rm -f "$stderr_log"
    rm -rf -- "$target"
}

# Companion to the test above, for the SECOND fork that used to sit in the
# check -> rm gap: uninstall.sh reads the manifest `source` field with jq.
# Before the mitigation that jq ran AFTER the containment ascent, so a swap
# synchronized to it landed between the ascent and the rm and a real file
# inside .git was deleted. The mitigation hoists the `source` lookup above
# the ascent, so the ascent is once again the last thing before rm; a swap
# timed to the jq now lands before the ascent, which then refuses. If a
# future change moves the `source` lookup back below the ascent, the
# injected marker+sleep land in the gap again and this test fails.
@test "uninstall.sh survives an ancestor-directory-symlink swap timed against the manifest source lookup" {
    target="$(mktemp -d)"
    git -C "$target" init -q

    # The managed file is a real package-blueprint inventory path so it
    # passes the Task 10B inventory cross-check and the loop still reaches the
    # containment ascent / rm; its own scripts/ directory is the swappable
    # ancestor. After the swap dst_file
    # (.repomethod/skills/ship-pr/scripts/preflight.sh) resolves to
    # .git/danger/preflight.sh — plant a real victim there with content whose
    # hash matches the recorded manifest hash so a regressed sink (source
    # lookup below the ascent) genuinely rm's it, not a no-op absent path.
    managed=".repomethod/skills/ship-pr/scripts/preflight.sh"
    mkdir -p "${target}/.git/danger"
    echo "original content" > "${target}/.git/danger/preflight.sh"

    mkdir -p "${target}/.repomethod/skills/ship-pr/scripts"
    echo "original content" > "${target}/${managed}"
    hash="$(sha256sum "${target}/${managed}" 2>/dev/null || shasum -a 256 "${target}/${managed}")"
    hash="${hash%% *}"

    cat > "${target}/.repomethod/manifest.json" <<EOF
{"version":"0.1.0","installed_at":"2026-07-19T00:00:00Z","profiles":["core"],"files":{"${managed}":{"sha256":"${hash}","source":"blueprint"}}}
EOF

    marker="$(mktemp -u)"
    stderr_log="$(mktemp -u)"

    # Anchor on the `recorded_source="$(jq ...)"` line, wherever it sits.
    instrumented="${REPO_ROOT}/.uninstall_toctou_source_test_instrumented.sh"
    sed "s|\(recorded_source=\"\$(jq -r --arg path \"\$rel_path\".*\)|\1; touch '${marker}'; sleep 1|" \
        "${REPO_ROOT}/uninstall.sh" > "$instrumented"
    chmod +x "$instrumented"
    # Sanity: the anchor must actually have matched, or this test would pass
    # vacuously.
    grep -q "touch '${marker}'" "$instrumented"

    "$instrumented" --target "$target" >/dev/null 2>"$stderr_log" &
    pid=$!

    for _ in $(seq 1 50); do
        [ -e "$marker" ] && break
        sleep 0.1
    done
    [ -e "$marker" ]

    rm -rf "${target}/.repomethod/skills/ship-pr/scripts"
    ln -s "${target}/.git/danger" "${target}/.repomethod/skills/ship-pr/scripts"

    wait "$pid" || true

    rm -f "$instrumented" "$marker"

    # Victim inside .git byte-unchanged, AND the containment ascent must have
    # positively refused — without this grep a regressed sink that rm'd a
    # non-existent path would still pass vacuously.
    [ -f "${target}/.git/danger/preflight.sh" ]
    [ "$(cat "${target}/.git/danger/preflight.sh")" = "original content" ]
    grep -qF -- "refusing to remove unsafe manifest path (inside .git)" "$stderr_log"

    rm -f "$stderr_log"
    rm -rf -- "$target"
}
