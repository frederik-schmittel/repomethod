#!/usr/bin/env bash
# deliver.sh — one close-out command for all three delivery paths.
#
#   deliver.sh --quick                       quick-mvp close-out
#   deliver.sh --spec <spec>                 classic/graph spec gate
#   deliver.sh --spec <spec> --state <file>  stateful classic/graph close-out
#
# A pure facade. It computes no gate, scope, evidence or workflow state of its
# own: it invokes agent-gate.sh (and, for a stateful spec, supervisor.sh),
# captures their combined stdout+stderr, and prints exactly one line
#   DELIVERY: done|blocked|incomplete — <reason>
# to stdout. It never writes stderr and never forwards a sub-command's output.
# Only `done` exits 0.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage_line='DELIVERY: blocked — usage: deliver.sh --quick | --spec <spec> [--state <state>]'
fail_usage() { printf '%s\n' "$usage_line"; exit 1; }

quick=false;  have_quick=false
spec="";      have_spec=false
state="";     have_state=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick)
            [ "$have_quick" = false ] || fail_usage
            have_quick=true; quick=true; shift ;;
        --spec)
            [ "$have_spec" = false ] || fail_usage
            { [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; } || fail_usage
            have_spec=true; spec="$2"; shift 2 ;;
        --state)
            [ "$have_state" = false ] || fail_usage
            { [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; } || fail_usage
            have_state=true; state="$2"; shift 2 ;;
        *) fail_usage ;;
    esac
done

if [ "$have_quick" = true ]; then
    { [ "$have_spec" = false ] && [ "$have_state" = false ]; } || fail_usage
elif [ "$have_spec" = false ]; then
    fail_usage
fi

# --- helpers -------------------------------------------------------------

# Run "$@"; combined stdout+stderr -> $cap, exit status -> $rc.
cap=""; rc=0
run_block() { cap="$("$@" 2>&1)"; rc=$?; }

# Trim outer whitespace (covers CR/LF), then collapse every interior run of
# CR/LF to "; "; the text is otherwise byte-identical.
oneline() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    s="$(printf '%s' "$s" | tr -s $'\r\n' '\n')"
    s="${s//$'\n'/; }"
    printf '%s' "$s"
}

# Last line of $1 with a non-whitespace character (a bare-CR line counts as
# empty), raw and untrimmed.
last_nonempty() {
    printf '%s\n' "$1" | awk '{ p = $0; gsub(/\r/, "", p) } p ~ /[^[:space:]]/ { l = $0 } END { printf "%s", l }'
}

blocked_from_gate() {
    local line
    line="$(last_nonempty "$cap")"
    if [ -z "$line" ]; then
        printf 'DELIVERY: blocked — agent-gate exited %s\n' "$rc"
    else
        printf 'DELIVERY: blocked — %s\n' "$(oneline "$line")"
    fi
    exit 1
}

invalid_supervisor() { printf 'DELIVERY: blocked — invalid supervisor result\n'; exit 1; }

# --- quick -------------------------------------------------------------

if [ "$quick" = true ]; then
    run_block "${here}/agent-gate.sh" --quick
    [ "$rc" -eq 0 ] || blocked_from_gate
    printf 'DELIVERY: done — quick gate passed\n'
    exit 0
fi

# --- spec without state ---------------------------------------------

if [ "$have_state" = false ]; then
    run_block "${here}/agent-gate.sh" --spec "$spec"
    [ "$rc" -eq 0 ] || blocked_from_gate
    printf 'DELIVERY: done — spec gate passed\n'
    exit 0
fi

# --- spec with state ---------------------------------------------

run_block "${here}/agent-gate.sh" --spec "$spec" --state "$state"
[ "$rc" -eq 0 ] || blocked_from_gate

run_block "${here}/supervisor.sh" check --state "$state"
sup_rc="$rc"

meta="$(printf '%s' "$cap" | jq -e -s '
    if length == 1 and (.[0] | type) == "object"
       and (.[0].verdict | type) == "string"
       and (.[0].reason  | type) == "string"
       and (.[0].reason  | length) > 0
    then .[0] else empty end' 2>/dev/null)" || invalid_supervisor

verdict="$(printf '%s' "$meta" | jq -r '.verdict')"
reason="$(printf '%s' "$meta" | jq -r '.reason')"

case "$verdict" in
    done)             want=0  ;;
    continue)         want=10 ;;
    blocked)          want=2  ;;
    needs_human)      want=3  ;;
    evidence-ignored) want=4  ;;
    *)                invalid_supervisor ;;
esac
[ "$sup_rc" -eq "$want" ] || invalid_supervisor

reason="$(oneline "$reason")"
case "$verdict" in
    done)     printf 'DELIVERY: done — %s\n' "$reason";       exit 0 ;;
    continue) printf 'DELIVERY: incomplete — %s\n' "$reason"; exit 1 ;;
    *)        printf 'DELIVERY: blocked — %s\n' "$reason";    exit 1 ;;
esac
