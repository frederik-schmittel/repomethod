#!/usr/bin/env bash
# supervisor.sh — public supervisor with Graph plan-conformance awareness.
# Classic execution delegates byte-for-byte behavior to supervisor-engine.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/supervisor-engine.sh"
conformance="${here}/plan-conformance.sh"
descope_ledger="${here}/descope-ledger.sh"
graph="${here}/workflow-graph.sh"

die() { echo "supervisor: $*" >&2; exit 1; }

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'
    fi
}

find_option() {
    local name="$1"; shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$name" ]; then
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$name requires a value"
            printf '%s\n' "$2"; return 0
        fi
        shift
    done
    return 1
}

state_mode() {
    jq -r '.mode // empty' "$1" 2>/dev/null || true
}

resolve_repo_root() {
    local state="$1" state_dir root
    state_dir="$(cd "$(dirname "$state")" && pwd -P)"
    root="$(git -C "$state_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || root="$(jq -r '.repo_root // empty' "$state")"
    [ -d "$root" ] || die "cannot locate repository for workflow state"
    (cd "$root" && pwd -P)
}

authority_fingerprint() {
    local state="$1" feature repo_root artifact artifact_hash descopes conformance_proj verdict_hashes approved_plan
    feature="$(jq -r '.feature' "$state")"
    repo_root="$(resolve_repo_root "$state")"
    artifact="${repo_root}/.repomethod/workflows/${feature}.plan-obligations.json"
    if [ -f "$artifact" ]; then artifact_hash="$(sha256_stream < "$artifact")"; else artifact_hash="missing"; fi
    descopes="$("$descope_ledger" state --state "$state" 2>/dev/null | jq -S . 2>/dev/null || printf 'invalid')"
    conformance_proj="$(jq -S '{
        conformance_retry_count:(.conformance_retry_count // 0),
        nodes:[.nodes[] | select(.type == "plan-conformance") | {id,status,outcome,attempt,conformance:(.conformance // null)}]
      }' "$state")"
    approved_plan="$(jq -S '.approved_plan // null' "$state")"
    verdict_hashes="$(
        cd "$repo_root"
        find .repomethod/evidence -type f -name "${feature}-plan-conformance*-verdict.json" -print 2>/dev/null \
            | LC_ALL=C sort \
            | while IFS= read -r file; do printf '%s\t%s\n' "$file" "$(sha256_stream < "$file")"; done
    )"
    printf '%s\n--\n%s\n--\n%s\n--\n%s\n--\n%s\n' \
        "$artifact_hash" "$descopes" "$approved_plan" "$conformance_proj" "$verdict_hashes" | sha256_stream
}

patch_sidecar_authority() {
    local sidecar="$1" fp="$2" reset_idle="$3" verdict="$4" tmp
    [ -f "$sidecar" ] || return 0
    tmp="$(mktemp "${sidecar}.tmp.XXXXXX")"
    jq --arg fp "$fp" --arg verdict "$verdict" --argjson reset "$reset_idle" '
        .authority_fingerprint=$fp
        | if $reset then .idle_runs=0 | .last_verdict=$verdict else . end
    ' "$sidecar" > "$tmp" || { rm -f "$tmp"; die "cannot persist supervisor authority fingerprint"; }
    mv "$tmp" "$sidecar"
}

check_graph() {
    local state="$1"; shift
    local feature state_dir sidecar previous authority changed=false out rc result verdict reason pc pc_status
    feature="$(jq -r '.feature' "$state")"
    state_dir="$(cd "$(dirname "$state")" && pwd -P)"
    state="${state_dir}/$(basename "$state")"
    sidecar="${state_dir}/${feature}.supervisor.json"
    previous=""
    [ -f "$sidecar" ] && previous="$(jq -r '.authority_fingerprint // empty' "$sidecar" 2>/dev/null || true)"
    authority="$(authority_fingerprint "$state")"
    [ -z "$previous" ] || [ "$previous" = "$authority" ] || changed=true

    set +e
    out="$("$engine" check --state "$state" "$@")"
    rc=$?
    set -e
    result="$(printf '%s' "$out" | jq -e -c 'if type=="object" and (.verdict|type=="string") then . else empty end' 2>/dev/null)" \
        || { printf '%s\n' "$out"; return "$rc"; }

    pc="$("$conformance" status --state "$state" 2>/dev/null || jq -n '{required:true,status:"blocked",reason:"cannot validate current plan-conformance authorities"}')"
    pc_status="$(jq -r '.status' <<< "$pc")"
    verdict="$(jq -r '.verdict' <<< "$result")"
    reason="$(jq -r '.reason' <<< "$result")"

    if [ "$changed" = true ]; then
        result="$(jq '.progress=true | .idle_runs=0' <<< "$result")"
        if [ "$verdict" = "blocked" ]; then
            verdict="continue"
            reason="review authority progressed; workflow requires another check"
            rc=10
        fi
    fi

    if [ "$verdict" = "done" ] && [ "$pc_status" != "passed" ]; then
        verdict="continue"
        reason="plan conformance ${pc_status}: $(jq -r '.reason' <<< "$pc")"
        rc=10
    fi

    result="$(jq --arg verdict "$verdict" --arg reason "$reason" --argjson pc "$pc" \
        '.verdict=$verdict | .reason=$reason | .plan_conformance=$pc' <<< "$result")"
    patch_sidecar_authority "$sidecar" "$authority" "$changed" "$verdict"
    printf '%s\n' "$result"

    case "$verdict" in
        done) return 0 ;;
        continue) return 10 ;;
        blocked) return 2 ;;
        needs_human) return 3 ;;
        evidence-ignored) return 4 ;;
        *) return "$rc" ;;
    esac
}

render_dispatch() {
    local verdict_json="$1" state="$2" feature="$3"
    local state_dir dispatch_path gate_log reason runnable handoff_path
    state_dir="$(dirname "$state")"
    dispatch_path="${state_dir}/${feature}.dispatch.md"
    handoff_path="${state_dir}/${feature}.handoff.json"
    gate_log="$(jq -r '.gate_log' <<< "$verdict_json")"
    reason="$(jq -r '.reason' <<< "$verdict_json")"
    runnable="$(jq -r '.next_dispatch.runnable | join(", ")' <<< "$verdict_json")"
    {
        printf '# Dispatch: %s\n\n' "$feature"
        printf 'Generated %s by supervisor.sh — hand this to a fresh agent.\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf -- '- State: %s\n' "$state"
        printf -- '- Spec: specs/%s.md\n' "$feature"
        printf -- '- Gate log: %s\n' "$gate_log"
        printf -- '- Reason: %s\n' "$reason"
        printf -- '- Runnable nodes: %s\n\n' "$runnable"
        if [ -f "$handoff_path" ]; then
            printf '## Previous handoff\n\n```json\n'
            cat "$handoff_path"
            printf '\n```\n\n'
        fi
        if jq -e '.next_dispatch.runnable | length > 0' <<< "$verdict_json" >/dev/null \
            && jq -e '.next_dispatch.runnable[] | select(test("^plan-conformance(-[0-9]+)?$"))' <<< "$verdict_json" >/dev/null; then
            printf 'The plan-conformance node requires a fresh reviewer context. Read its generated context bundle and fixed rubric before recording a verdict.\n\n'
        fi
        printf 'Resume from the runnable node(s). Before you stop, write a handoff with\n'
        printf 'workflow-graph.sh handoff (node, next step, changed files, blocker or claim).\n'
    } > "$dispatch_path"
    printf '%s\n' "$dispatch_path"
}

subcommand="${1:-}"
[ -n "$subcommand" ] || exec "$engine" "$@"
shift
state="$(find_option --state "$@" || true)"
if [ -z "$state" ] || [ ! -f "$state" ] || [ "$(state_mode "$state")" != "graph" ]; then
    exec "$engine" "$subcommand" "$@"
fi

case "$subcommand" in
    check)
        args=()
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--state" ]; then shift 2; continue; fi
            args+=("$1"); shift
        done
        check_graph "$state" "${args[@]}"
        ;;
    run)
        agent_command="$(find_option --agent-command "$@" || true)"
        if [ -z "$agent_command" ]; then
            args=()
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--state" ]; then shift 2; continue; fi
                args+=("$1"); shift
            done
            check_graph "$state" "${args[@]}"
            exit $?
        fi
        max_runs="$(find_option --max-runs "$@" || true)"; [ -n "$max_runs" ] || max_runs=10
        max_idle="$(find_option --max-idle-runs "$@" || true)"; [ -n "$max_idle" ] || max_idle=2
        base="$(find_option --base "$@" || true)"
        feature="$(jq -r '.feature' "$state")"
        repo_root="$(resolve_repo_root "$state")"
        state_dir="$(cd "$(dirname "$state")" && pwd -P)"; state="${state_dir}/$(basename "$state")"
        handoff_path="${state_dir}/${feature}.handoff.json"
        run_count=0
        while :; do
            check_args=(--max-idle-runs "$max_idle")
            [ -z "$base" ] || check_args+=(--base "$base")
            set +e
            out="$(check_graph "$state" "${check_args[@]}")"; rc=$?
            set -e
            printf '%s\n' "$out"
            verdict="$(jq -r '.verdict' <<< "$out")"
            case "$verdict" in
                done) exit 0 ;;
                needs_human) exit 3 ;;
                evidence-ignored) exit 4 ;;
                blocked)
                    node="$(jq -r '.next_dispatch.runnable[0] // "completion"' <<< "$out")"
                    "$graph" block --state "$state" --node "$node" --reason "supervisor: $(jq -r '.reason' <<< "$out")" || true
                    exit 2
                    ;;
                continue)
                    run_count=$((run_count + 1))
                    [ "$run_count" -le "$max_runs" ] || die "reached --max-runs ${max_runs} without a terminal verdict"
                    dispatch_path="$(render_dispatch "$out" "$state" "$feature")"
                    agent_rc=0
                    RM_STATE="$state" RM_SPEC="${repo_root}/specs/${feature}.md" \
                        RM_HANDOFF="$handoff_path" \
                        RM_GATE_LOG="${repo_root}/$(jq -r '.gate_log' <<< "$out")" \
                        RM_DISPATCH="$dispatch_path" \
                        bash -c "$agent_command" || agent_rc=$?
                    [ "$agent_rc" -eq 0 ] || echo "supervisor: agent command exited ${agent_rc}" >&2
                    ;;
                *) exit "$rc" ;;
            esac
        done
        ;;
    *)
        exec "$engine" "$subcommand" "$@"
        ;;
esac
