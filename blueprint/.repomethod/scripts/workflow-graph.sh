#!/usr/bin/env bash
# workflow-graph.sh — descope-aware facade over the persistent workflow runner.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core="${here}/workflow-graph-core.sh"
ledger="${here}/descope-ledger.sh"

fail() {
    echo "workflow-graph: $*" >&2
    exit 1
}

resolve_state_arg() {
    local feature="" state="" prev="" arg
    for arg in "$@"; do
        if [ "$prev" = "--feature" ]; then feature="$arg"; prev=""; continue; fi
        if [ "$prev" = "--state" ]; then state="$arg"; prev=""; continue; fi
        case "$arg" in
            --feature|--state) prev="$arg" ;;
        esac
    done
    if [ -n "$state" ]; then
        printf '%s\n' "$state"
    elif [ -n "$feature" ]; then
        printf '.repomethod/workflows/%s.json\n' "$feature"
    else
        return 1
    fi
}

command="${1:-}"
[ -n "$command" ] || exec "$core"
shift

case "$command" in
    init)
        state="$(resolve_state_arg "$@")" || fail "cannot resolve state path for init"
        "$core" init "$@"
        if ! "$ledger" init --state "$state" >/dev/null; then
            rm -f -- "$state"
            fail "failed to initialize descope ledger"
        fi
        ;;

    handoff)
        state="$(resolve_state_arg "$@")" || fail "--state is required"
        descope_state="$($ledger state --state "$state")" \
            || fail "cannot write handoff while descope ledger is invalid"
        feature="$(jq -er '.feature' "$state")" || fail "invalid workflow feature"
        handoff_path="$(dirname "$state")/${feature}.handoff.json"

        output="$($core handoff "$@")"
        tmp="$(mktemp "${handoff_path}.XXXXXX")"
        if ! jq \
            --argjson descopes "$(jq -c '.descopes' <<< "$descope_state")" \
            --argjson open_descope_ids "$(jq -c '.blocking_ids' <<< "$descope_state")" \
            '. + {descopes:$descopes, open_descope_ids:$open_descope_ids}' \
            "$handoff_path" > "$tmp"; then
            rm -f -- "$tmp"
            fail "failed to add descope state to handoff"
        fi
        mv "$tmp" "$handoff_path"
        printf '%s\n' "$output"
        ;;

    *)
        exec "$core" "$command" "$@"
        ;;
esac
