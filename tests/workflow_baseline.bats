setup() {
    load 'test_helper/common-setup'
    _common_setup
    SRC="${REPO_ROOT}/blueprint/.repomethod/scripts"
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/.repomethod/scripts"
    cp "${SRC}"/*.sh "${WORK}/.repomethod/scripts/"
    chmod +x "${WORK}/.repomethod/scripts"/*.sh
    WRAPPER="${WORK}/.repomethod/scripts/feature-workflow.sh"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email t@e.x
    git -C "$WORK" config user.name T
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m init
}

teardown() {
    rm -rf -- "$WORK"
}

@test "quick-mvp aborts when the configured gate is red on a clean tree" {
    printf 'false\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"
    run "$WRAPPER" quick-mvp
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate is red before any change"* ]]
    [[ "$output" != *"Goal, Scope, Test"* ]]
}

@test "quick-mvp proceeds when the configured gate is green" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"
    run "$WRAPPER" quick-mvp
    [ "$status" -eq 0 ]
    [[ "$output" == *"Goal, Scope, Test"* ]]
}

@test "baseline-green runs on a dirty tree and aborts on red" {
    printf 'false\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    echo x > "${WORK}/junk.txt"
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"[baseline] gate is red"* ]]
    [ ! -e "${WORK}/f.json" ]
}

@test "baseline-green on a dirty tree with a green command proceeds" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    echo x > "${WORK}/junk.txt"
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/f.json" ]
}

@test "classic init aborts with the preflight block before jq" {
    # No .repomethod/verify-command -> a hard preflight finding. The preflight
    # block prints and classic init exits with preflight's status before the
    # baseline check or the jq-backed state write.
    echo x > "${WORK}/junk.txt"
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"PREFLIGHT: "* ]]
    [[ "$output" == *"HARD: .repomethod/verify-command missing"* ]]
    [[ "$output" != *"[baseline] gate is red"* ]]
    [ ! -e "${WORK}/f.json" ]
}

@test "graph init runs baseline only after a green preflight" {
    # A verify-command whose runner is absent: preflight fails first, so
    # assert_baseline_green never runs and no state is written.
    printf 'definitely-not-a-real-command --x\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"
    run "$WRAPPER" graph init --feature demo --state "${WORK}/g.json" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"HARD: verify-command program 'definitely-not-a-real-command' not found"* ]]
    [[ "$output" != *"[baseline] gate is red"* ]]
    [ ! -e "${WORK}/g.json" ]

    # With a resolvable runner the preflight goes green and the baseline runs,
    # so init proceeds and writes state.
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd2
    run "$WRAPPER" graph init --feature demo2 --state "${WORK}/g2.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/g2.json" ]
}

@test "classic init aborts when the configured gate is red on a clean tree" {
    printf 'false\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate is red before any change"* ]]
    [ ! -e "${WORK}/f.json" ]
}

@test "init warns when a frontend file is changed but verify-command has no JS check" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git -C "$WORK" add -A
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/f.json" ]
    [[ "$output" == *"WARN: change touches frontend files but verify-command runs no JS check"* ]]
}

@test "classic and graph init emit the shared frontend warning once" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git -C "$WORK" add -A
    cd "$WORK"

    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/f.json" ]
    n=$(printf '%s\n' "$output" | grep -c 'WARN: change touches frontend files but verify-command runs no JS check')
    [ "$n" -eq 1 ]

    run "$WRAPPER" graph init --feature demo2 --state "${WORK}/g.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/g.json" ]
    n=$(printf '%s\n' "$output" | grep -c 'WARN: change touches frontend files but verify-command runs no JS check')
    [ "$n" -eq 1 ]
}

@test "no warning when verify-command has a JS check" {
    printf 'echo pnpm test\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    mkdir -p "${WORK}/src"
    echo 'export const x = 1' > "${WORK}/src/app.tsx"
    git -C "$WORK" add -A
    cd "$WORK"
    run "$WRAPPER" classic init --feature demo --state "${WORK}/f.json" --verify-command true
    [ "$status" -eq 0 ]
    [ -e "${WORK}/f.json" ]
    [[ "$output" != *"WARN: change touches frontend files but verify-command runs no JS check"* ]]
}

@test "graph init aborts when the configured gate is red on a clean tree" {
    printf 'false\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"
    run "$WRAPPER" graph init --feature demo --state "${WORK}/g.json" --verify-command true
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate is red before any change"* ]]
    [ ! -e "${WORK}/g.json" ]
}

@test "classic and graph init persist a state-aware canonical gate command" {
    printf 'true\n' > "${WORK}/.repomethod/verify-command"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m cmd
    cd "$WORK"

    # canonical gate command + explicit --state -> the actual state path is appended
    "$WRAPPER" classic init --feature alpha --state "${WORK}/a.json" \
        --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/alpha.md" >/dev/null
    [ "$(jq -r '.config.verification_command' "${WORK}/a.json")" = \
        ".repomethod/scripts/agent-gate.sh --spec specs/alpha.md --state ${WORK}/a.json" ]

    "$WRAPPER" graph init --feature beta --state "${WORK}/b.json" \
        --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/beta.md" >/dev/null
    [ "$(jq -r '.config.verification_command' "${WORK}/b.json")" = \
        ".repomethod/scripts/agent-gate.sh --spec specs/beta.md --state ${WORK}/b.json" ]

    # no --state -> the default workflow path is what gets recorded
    "$WRAPPER" classic init --feature gamma \
        --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/gamma.md" >/dev/null
    [ "$(jq -r '.config.verification_command' "${WORK}/.repomethod/workflows/gamma.json")" = \
        ".repomethod/scripts/agent-gate.sh --spec specs/gamma.md --state .repomethod/workflows/gamma.json" ]

    # a canonical gate command that already carries --state/--base is refused
    run "$WRAPPER" classic init --feature delta --state "${WORK}/d.json" \
        --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/delta.md --state x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must omit --state and --base; init records the actual state"* ]]
    [ ! -e "${WORK}/d.json" ]

    # a non-gate verify command is stored byte-identical
    "$WRAPPER" classic init --feature epsilon --state "${WORK}/e.json" \
        --verify-command "make test" >/dev/null
    [ "$(jq -r '.config.verification_command' "${WORK}/e.json")" = "make test" ]
}
