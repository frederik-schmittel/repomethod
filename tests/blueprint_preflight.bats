setup() {
    load 'test_helper/common-setup'
    _common_setup
    PREFLIGHT="${REPO_ROOT}/blueprint/.repomethod/scripts/preflight.sh"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/.repomethod"
    cd "$WORK"
    git init -q -b main
    git config user.email t@e.x
    git config user.name T
    git commit -q --allow-empty -m init
}

teardown() {
    rm -rf -- "$WORK"
}

@test "preflight reports jq and verify-command failures together" {
    # A PATH that carries every standard program preflight uses, minus jq, and a
    # fixture with no .repomethod/verify-command. Exactly two hard findings must
    # result (jq + missing verify-command); finding 5 never runs because there
    # is no active line, and a missing standard program must not add a finding.
    bindir="${WORK}/bin"
    mkdir -p "$bindir"
    for prog in bash sh git grep find sort head sed cat tr cut env; do
        p="$(command -v "$prog" || true)"
        [ -n "$p" ] && ln -s "$p" "${bindir}/${prog}"
    done

    run env -u VIRTUAL_ENV PATH="$bindir" "$PREFLIGHT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PREFLIGHT: 2 problem(s)"* ]]
    [[ "$output" == *"HARD: jq not found | FIX: install jq and put it on PATH"* ]]
    [[ "$output" == *"HARD: .repomethod/verify-command missing | FIX: create it with one verification command per active line"* ]]
    hard_count="$(printf '%s\n' "$output" | grep -c '^HARD: ' || true)"
    warn_count="$(printf '%s\n' "$output" | grep -c '^WARN: ' || true)"
    [ "$hard_count" -eq 2 ]
    [ "$warn_count" -eq 0 ]
    [[ "$output" != *"verify-command program"* ]]
}

@test "preflight succeeds with a complete environment" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    run env -u VIRTUAL_ENV "$PREFLIGHT"
    [ "$status" -eq 0 ]
    [ "$output" = "PREFLIGHT: 0 problem(s)" ]
}

@test "preflight warnings keep exit zero" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git checkout -q --detach
    run env -u VIRTUAL_ENV "$PREFLIGHT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PREFLIGHT: 1 problem(s)"* ]]
    [[ "$output" == *"WARN: HEAD is detached | FIX: check out the intended branch before starting a workflow"* ]]
}

@test "preflight quiet suppresses warnings and green output" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git checkout -q --detach
    run env -u VIRTUAL_ENV "$PREFLIGHT" --quiet
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "preflight reports every missing direct verify runner once" {
    cat > "${WORK}/.repomethod/verify-command" <<'EOF'
# a comment line is not active
   nope-one --with-flags
nope-two
nope-one again
true
EOF
    run env -u VIRTUAL_ENV "$PREFLIGHT"
    [ "$status" -eq 1 ]
    one="$(printf '%s\n' "$output" | grep -c "HARD: verify-command program 'nope-one' not found" || true)"
    two="$(printf '%s\n' "$output" | grep -c "HARD: verify-command program 'nope-two' not found" || true)"
    [ "$one" -eq 1 ]
    [ "$two" -eq 1 ]
    [[ "$output" != *"program 'true'"* ]]
    [[ "$output" != *"program 'again'"* ]]
    [[ "$output" != *"program '#'"* ]]
}

@test "preflight rejects unknown arguments with usage exit two" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"

    run "$PREFLIGHT" --bogus
    [ "$status" -eq 2 ]
    [ "$output" = "usage: preflight.sh [--quiet]" ]

    run "$PREFLIGHT" positional
    [ "$status" -eq 2 ]

    run "$PREFLIGHT" --quiet extra
    [ "$status" -eq 2 ]

    run "$PREFLIGHT" --quiet --quiet
    [ "$status" -eq 2 ]
}

@test "preflight source file is executable" {
    [ -x "${REPO_ROOT}/blueprint/.repomethod/scripts/preflight.sh" ]
}
