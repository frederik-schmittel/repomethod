setup() {
    bats_require_minimum_version 1.5.0
    load 'test_helper/common-setup'
    _common_setup
    SRC="${REPO_ROOT}/blueprint/.repomethod/scripts"
    WORK="$(mktemp -d)"
    BIN="${WORK}/scripts"
    mkdir -p "$BIN"

    # The real facade under test, next to deterministic fixture building blocks.
    # (During RED the source does not exist yet; the copy is best-effort so the
    # real-path assertions below still fail for the intended reason.)
    cp "${SRC}/deliver.sh" "${BIN}/deliver.sh" 2>/dev/null || true
    chmod +x "${BIN}/deliver.sh" 2>/dev/null || true

    cat > "${BIN}/agent-gate.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/gate.argv"
[ -n "${GATE_OUT:-}" ] && printf '%s\n' "$GATE_OUT"
[ -n "${GATE_ERR:-}" ] && printf '%s\n' "$GATE_ERR" >&2
exit "${GATE_EXIT:-0}"
EOF
    cat > "${BIN}/descope-ledger.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":1,"feature":"fixture","ledger":"fixture.descopes.jsonl","checkpoint":{"event_count":0,"tail_hash":"0000000000000000000000000000000000000000"},"descopes":[],"blocking_ids":[],"accepted_ids":[]}'
EOF
    cat > "${BIN}/supervisor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/sup.argv"
[ -n "${SUP_MARKER:-}" ] && : > "$SUP_MARKER"
[ -n "${SUP_OUT:-}" ] && printf '%s' "$SUP_OUT"
exit "${SUP_EXIT:-0}"
EOF
    chmod +x "${BIN}/agent-gate.sh" "${BIN}/descope-ledger.sh" "${BIN}/supervisor.sh"
    DELIVER="${BIN}/deliver.sh"
    USAGE="DELIVERY: blocked — usage: deliver.sh --quick | --spec <spec> [--state <state>]"
}

teardown() {
    rm -rf -- "$WORK"
}

# Build a real repo with the shipped blueprint scripts and an active
# .repomethod/verify-command so T4's preflight does not mask the T5 path.
real_repo() {
    local w="$1"
    mkdir -p "${w}/.repomethod/scripts" "${w}/.repomethod/evidence" "${w}/specs" "${w}/src"
    cp "${SRC}"/*.sh "${w}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${w}/.repomethod/"
    chmod +x "${w}/.repomethod/scripts/"*.sh
    printf 'true\n' > "${w}/.repomethod/verify-command"
    git -C "$w" init -q -b main
    git -C "$w" config user.email t@e.x
    git -C "$w" config user.name T
}

@test "deliver prints one normalized line for quick and classic" {
    # --- real quick happy path -------------------------------------------
    q="${WORK}/q"
    real_repo "$q"
    printf 'Built the facade. Verified: bats (green).\n' > "${q}/.repomethod/evidence/report.md"
    git -C "$q" add -A && git -C "$q" commit -q -m init
    run --separate-stderr bash -c "cd '$q' && .repomethod/scripts/deliver.sh --quick"
    [ "$status" -eq 0 ]
    [ "$output" = "DELIVERY: done — quick gate passed" ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 1 ]

    # --- real classic (spec) happy path --------------------------------
    c="${WORK}/c"
    real_repo "$c"
    cat > "${c}/specs/feat.md" <<'EOF'
# Task: deliver facade smoke

## Scope

- `src/**`

## Acceptance Criteria

1. it works

## Expected Evidence

- `.repomethod/evidence/proof.txt`
EOF
    cat > "${c}/.repomethod/evidence/report.md" <<'EOF'
Report for feat.md
- [x] 1. done
EOF
    printf 'evidence\n' > "${c}/.repomethod/evidence/proof.txt"
    git -C "$c" add -A && git -C "$c" commit -q -m init
    run --separate-stderr bash -c "cd '$c' && .repomethod/scripts/deliver.sh --spec specs/feat.md"
    [ "$status" -eq 0 ]
    [ "$output" = "DELIVERY: done — spec gate passed" ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "deliver maps an incomplete classic workflow to exit one" {
    run --separate-stderr env GATE_EXIT=0 SUP_EXIT=10 \
        SUP_OUT='{"verdict":"continue","reason":"next_dispatch: implementation, verification"}' \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: incomplete — next_dispatch: implementation, verification" ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "deliver maps every terminal supervisor verdict" {
    row() { # verdict required-exit expected-line deliver-exit
        rm -f "${BIN}/gate.argv" "${BIN}/sup.argv"
        run --separate-stderr env GATE_EXIT=0 SUP_EXIT="$2" \
            SUP_OUT="{\"verdict\":\"$1\",\"reason\":\"R for $1\"}" \
            "$DELIVER" --spec s.md --state st.json
        [ "$status" -eq "$4" ]
        [ "$output" = "$3" ]
        [ -z "$stderr" ]
        # the façade forwards the exact building-block argv
        [ "$(cat "${BIN}/gate.argv")" = "--spec s.md --state st.json" ]
        [ "$(cat "${BIN}/sup.argv")" = "check --state st.json" ]
    }
    row done             0  "DELIVERY: done — R for done"             0
    row continue         10 "DELIVERY: incomplete — R for continue"   1
    row blocked          2  "DELIVERY: blocked — R for blocked"       1
    row needs_human      3  "DELIVERY: blocked — R for needs_human"   1
    row evidence-ignored 4  "DELIVERY: blocked — R for evidence-ignored" 1

    # rule 9: CR/LF sequences in the reason collapse to "; "
    run --separate-stderr env GATE_EXIT=0 SUP_EXIT=2 \
        SUP_OUT='{"verdict":"blocked","reason":"line one\r\nline two\nline three"}' \
        "$DELIVER" --spec s.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — line one; line two; line three" ]
    [ -z "$stderr" ]
}

@test "deliver blocks on a red gate without calling supervisor" {
    marker="${WORK}/sup_called"

    run --separate-stderr env GATE_EXIT=1 SUP_MARKER="$marker" \
        GATE_OUT=$'preamble line\nVIOLATION: src/app.txt is outside scope' \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — VIOLATION: src/app.txt is outside scope" ]
    [ -z "$stderr" ]
    [ ! -e "$marker" ]

    # no non-empty line in the captured gate output -> synthetic reason
    run --separate-stderr env GATE_EXIT=7 SUP_MARKER="$marker" GATE_OUT="" \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — agent-gate exited 7" ]
    [ -z "$stderr" ]
    [ ! -e "$marker" ]

    # gate output that is only blank CRLF lines is still "no non-empty line"
    run --separate-stderr env GATE_EXIT=1 SUP_MARKER="$marker" GATE_OUT=$'\r\n\r\n \r' \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — agent-gate exited 1" ]
    [ -z "$stderr" ]
    [ ! -e "$marker" ]

    # multiple bare CR characters are whitespace-only too
    run --separate-stderr env GATE_EXIT=9 SUP_MARKER="$marker" GATE_OUT=$'\r\r\r' \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — agent-gate exited 9" ]
    [ -z "$stderr" ]
    [ ! -e "$marker" ]

    # a trailing CR on the reason line is trimmed, not turned into "; "
    run --separate-stderr env GATE_EXIT=1 SUP_MARKER="$marker" GATE_OUT=$'ok detail\r' \
        "$DELIVER" --spec specs/x.md --state st.json
    [ "$status" -eq 1 ]
    [ "$output" = "DELIVERY: blocked — ok detail" ]
    [ -z "$stderr" ]
    [ ! -e "$marker" ]
}

@test "deliver rejects invalid flag combinations with one line" {
    bad() {
        run --separate-stderr "$DELIVER" "$@"
        [ "$status" -eq 1 ]
        [ "$output" = "$USAGE" ]
        [ -z "$stderr" ]
        [ "${#lines[@]}" -eq 1 ]
    }
    bad                              # no mode
    bad --quick --spec s.md          # --quick with another flag
    bad --quick --state st.json      # --quick with another flag
    bad --spec a --spec b            # duplicate --spec
    bad --state a --state b --spec s # duplicate --state
    bad --quick --quick              # duplicate --quick
    bad --state st.json              # --state without --spec
    bad --spec                       # missing value
    bad --spec ''                    # empty value
    bad --spec -x                    # value that looks like a flag
    bad --spec s.md --state          # missing value
    bad --spec s.md --state ''       # empty value
    bad --bogus                      # unknown flag
    bad --spec s.md leftover         # stray argument
}

@test "deliver rejects malformed or inconsistent supervisor output" {
    mal() { # supervisor-output supervisor-exit
        run --separate-stderr env GATE_EXIT=0 SUP_EXIT="$2" SUP_OUT="$1" \
            "$DELIVER" --spec s.md --state st.json
        [ "$status" -eq 1 ]
        [ "$output" = "DELIVERY: blocked — invalid supervisor result" ]
        [ -z "$stderr" ]
    }
    mal 'not json at all' 0
    mal '' 0
    mal '{"verdict":"done","reason":"a"} {"verdict":"done","reason":"b"}' 0
    mal '{"verdict":"done"}' 0
    mal '{"verdict":"done","reason":""}' 0
    mal '{"verdict":"done","reason":5}' 0
    mal '{"verdict":42,"reason":"ok"}' 0
    mal '{"verdict":"mystery","reason":"ok"}' 0
    mal '{"verdict":"done","reason":"ok"}' 10
    mal '{"verdict":"continue","reason":"ok"}' 0
}

@test "delivery skills use deliver only for close-out" {
    skills="${REPO_ROOT}/blueprint/.repomethod/skills"
    agents="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    workflow="${REPO_ROOT}/blueprint/.repomethod/scripts/feature-workflow.sh"

    grep -qF '.repomethod/scripts/deliver.sh --quick' "${skills}/quick-mvp/SKILL.md"
    ! grep -qF 'agent-gate.sh' "${skills}/quick-mvp/SKILL.md"
    ! grep -qF 'supervisor.sh' "${skills}/quick-mvp/SKILL.md"

    for s in classic-loop graph-delivery; do
        f="${skills}/${s}/SKILL.md"
        grep -qF '.repomethod/scripts/deliver.sh --spec <spec> --state <file>' "$f"
        # agent-gate.sh may appear only inside the init-stored --verify-command
        ! (grep -n 'agent-gate.sh' "$f" | grep -qv 'verify-command')
        # supervisor.sh may still be named, but never as the confirmed close-out step
        ! grep -qF 'confirmed by `.repomethod/scripts/supervisor.sh' "$f"
        ! grep -qF 'confirmed by `.repomethod/scripts/agent-gate.sh' "$f"
    done

    # AGENTS.md keeps the building blocks but routes close-out through deliver.sh
    grep -qF '.repomethod/scripts/supervisor.sh check --state <file>' "$agents"
    grep -qF 'agent-gate.sh --quick' "$agents"
    grep -qF '.repomethod/scripts/deliver.sh --quick' "$agents"
    grep -qF 'deliver.sh --spec <spec> --state <file>' "$agents"
    grep 'It is delivered when' "$agents" | grep -qF 'deliver.sh'
    grep 'before declaring delivery complete' "$agents" | grep -qF 'deliver.sh'
    ! grep -Eq 'agent-gate\.sh --quick.*quick-mvp close-out' "$agents"

    grep -qF 'Close out with: .repomethod/scripts/deliver.sh --quick' "$workflow"
    ! grep -qF 'Close out with: .repomethod/scripts/agent-gate.sh --quick' "$workflow"
}

@test "deliver source file is executable" {
    [ -x "${REPO_ROOT}/blueprint/.repomethod/scripts/deliver.sh" ]
}