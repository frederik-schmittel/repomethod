#!/usr/bin/env bash
# feature-workflow.sh - select Quick MVP, Classic, or Graph delivery.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-}"

# Run the repository's own verify-command once before a delivery starts. A gate
# that is already red on an untouched baseline makes every later failure
# ambiguous ("my change or the baseline?"), so we fail fast here instead. One
# check, no caching, no persistence. Runs regardless of tree cleanliness —
# verify-command's exit status does not depend on uncommitted changes — and
# skips only when no command is configured (an unconfigured gate is verify.sh's
# own fail-closed problem, later).
assert_baseline_green() {
    local warn_frontend_uncovered="${1:-false}"
    local cmd_file=".repomethod/verify-command"
    local -a verify_args=()
    { [ -f "$cmd_file" ] && grep -Eq '^[[:space:]]*[^[:space:]#]' "$cmd_file"; } || return 0
    if [ "$warn_frontend_uncovered" = true ]; then
        verify_args+=(--warn-frontend-uncovered)
    fi
    if ! "${here}/verify.sh" "${verify_args[@]}" . >/dev/null; then
        echo "[baseline] gate is red before any change — fix the baseline or narrow verify-command" >&2
        exit 1
    fi
}

# The canonical full-gate verify command is
#   .repomethod/scripts/agent-gate.sh --spec <spec-path>
# Consumers read the pinned config.base_ref out of the workflow state, so init
# has to record the ACTUAL state path in that command. Given init's own
# arguments, locate --verify-command: when its value is the canonical gate form
# and carries neither --state nor --base, append
# " --state <shell-quoted-actual-state-path>" (bash printf %q, no hand-rolled
# escaper). Every other verify command (true, make test, a custom wrapper) is
# passed through byte-identical. The rewritten argument list lands in
# NORMALIZED_ARGS.
CANONICAL_GATE_PREFIX='.repomethod/scripts/agent-gate.sh --spec '

normalize_gate_command() {
    NORMALIZED_ARGS=()
    local -a in=("$@")
    local i feature="" state="" vc="" vc_seen=false
    for ((i = 0; i < ${#in[@]}; i++)); do
        case "${in[i]}" in
            --feature) feature="${in[i + 1]:-}" ;;
            --state) state="${in[i + 1]:-}" ;;
            --verify-command) vc="${in[i + 1]:-}"; vc_seen=true ;;
        esac
    done
    if [ "$vc_seen" != true ]; then
        NORMALIZED_ARGS=("$@")
        return 0
    fi
    local actual_state="$state"
    [ -n "$actual_state" ] || actual_state=".repomethod/workflows/${feature}.json"
    local new_vc="$vc"
    case "$vc" in
        "$CANONICAL_GATE_PREFIX"*)
            case "$vc" in
                *" --state"* | *" --base"*)
                    echo "agent-gate verify command must omit --state and --base; init records the actual state" >&2
                    exit 1
                    ;;
            esac
            new_vc="${vc} --state $(printf '%q' "$actual_state")"
            ;;
    esac
    for ((i = 0; i < ${#in[@]}; i++)); do
        if [ "${in[i]}" = "--verify-command" ]; then
            NORMALIZED_ARGS+=(--verify-command "$new_vc")
            i=$((i + 1))
        else
            NORMALIZED_ARGS+=("${in[i]}")
        fi
    done
}

case "$mode" in
    quick-mvp)
        assert_baseline_green false
        cat <<'EOF'
quick-mvp workflow selected (no workflow state is created)
1. Quick Plan: record Goal, Scope, Test in at most three bullets.
2. Implement the smallest testable change in the current agent session using existing skills.
3. Run the targeted test for the changed behavior.
4. If it fails, make one correction and rerun the same targeted test.
5. Return the testable MVP with changed files and the test result.
6. Close out with: .repomethod/scripts/deliver.sh --quick
   (verify-command + no protected zone touched + a free-text note in
   .repomethod/evidence/report.md). No spec file, no four-way aggregate.
No research, graph state, subagents, packetization, or spec in this path.
Stop before changes involving protected paths, architecture, or security decisions.
EOF
        ;;
    classic)
        shift
        if [ "$#" -eq 0 ]; then
            cat <<'EOF'
classic workflow selected
Create a bounded implementation state with:
.repomethod/scripts/feature-workflow.sh classic init --feature <slug> --verify-command ".repomethod/scripts/agent-gate.sh --spec specs/<slug>.md"
Classic runs Implementation -> configured verification command -> Completion.
Verification failures create a bounded Fix -> Verification loop.
EOF
            exit 0
        fi
        if [ "${1:-}" = "init" ]; then
            shift
            "${here}/preflight.sh" >&2 || exit $?
            assert_baseline_green true
            normalize_gate_command --mode classic "$@"
            exec "${here}/workflow-graph.sh" init "${NORMALIZED_ARGS[@]}"
        fi
        exec "${here}/workflow-graph.sh" "$@"
        ;;
    graph)
        shift
        if [ "${1:-}" = "init" ]; then
            shift
            "${here}/preflight.sh" >&2 || exit $?
            assert_baseline_green true
            normalize_gate_command "$@"
            exec "${here}/workflow-graph.sh" init "${NORMALIZED_ARGS[@]}"
        fi
        exec "${here}/workflow-graph.sh" "$@"
        ;;
    *)
        echo "usage: feature-workflow.sh quick-mvp | classic | graph <command>" >&2
        exit 1
        ;;
esac
