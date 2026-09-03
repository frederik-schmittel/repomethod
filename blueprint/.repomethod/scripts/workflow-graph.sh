#!/usr/bin/env bash
# workflow-graph.sh — public Classic/Graph runner with mandatory Graph plan conformance.
# The stable engine remains in workflow-graph-engine.sh; this facade adds the
# Graph-only conformance boundary without changing Classic semantics.
# shellcheck disable=SC2016 # jq programs are intentionally single-quoted.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/workflow-graph-engine.sh"
conformance="${here}/plan-conformance.sh"

die() { echo "workflow-graph: $*" >&2; exit 1; }

require_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for $1"
}

atomic_jq() {
    local state="$1" filter="$2" tmp
    shift 2
    tmp="$(mktemp "${state}.tmp.XXXXXX")"
    jq "$@" "$filter" "$state" > "$tmp" || { rm -f "$tmp"; die "state update failed"; }
    mv "$tmp" "$state"
}

find_state_arg() {
    local prev="" arg
    for arg in "$@"; do
        if [ "$prev" = "--state" ]; then printf '%s\n' "$arg"; return 0; fi
        prev="$arg"
    done
    return 1
}

find_option() {
    local name="$1"; shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$name" ]; then require_value "$@"; printf '%s\n' "$2"; return 0; fi
        shift
    done
    return 1
}

discover_single_proposal() {
    local candidate
    local -a proposals=()
    if [ -d ".repomethod/workflows" ]; then
        while IFS= read -r candidate; do
            if jq -e '.mode == "graph" and .status == "awaiting_approval"' "$candidate" >/dev/null 2>&1; then
                proposals+=("$candidate")
            fi
        done < <(find .repomethod/workflows -maxdepth 1 -type f -name '*.json' -print | LC_ALL=C sort)
    fi
    case "${#proposals[@]}" in
        0) die "no graph awaiting approval found; pass the displayed --state" ;;
        1) printf '%s\n' "${proposals[0]}" ;;
        *) die "multiple graphs awaiting approval found; pass the displayed --state" ;;
    esac
}

dispatch_graph() {
    "$engine" dispatch --state "$1" | jq '
        .runnable |= map(if .type == "plan-conformance" then .fresh_context_required = true else . end)
    '
}

patch_graph_init() {
    local state="$1" goal="$2"
    atomic_jq "$state" '
        .conformance_retry_count = 0
        | .nodes += [{
            id:"plan-conformance", type:"plan-conformance", status:"pending",
            goal:$goal, role:"Plan Reviewer", dependencies:["verification"], inputs:["verification"],
            outputs:[], evidence:[], human_gate:false, outcome:null, attempt:0, order:55
          }]
        | .nodes |= map(if .id == "completion" then .dependencies=["plan-conformance"] | .inputs=["plan-conformance"] else . end)
    ' --arg goal "$goal"
}

validate_required_graph() {
    local state="$1"
    jq -e '
        .nodes as $nodes
        | def depends_on($id; $target):
            if $id == $target then true
            else any(($nodes[] | select(.id == $id) | .dependencies[]); depends_on(.; $target))
            end;
        ([.nodes[] | select(.id == "plan-conformance" and .type == "plan-conformance")] | length) == 1
        and ([.nodes[] | select(.id == "completion" and .type == "completion")] | length) == 1
        and ([.nodes[] | select(.type == "verification")] | length) > 0
        and ([.nodes[] | select(.id == "plan-conformance")][0].dependencies) as $pc_deps
        | all($nodes[] | select(.type == "verification"); .id as $id | ($pc_deps | index($id)) != null)
        and depends_on("completion"; "plan-conformance")
    ' "$state" >/dev/null || die "graph invalid: every Verification must feed plan-conformance, and Completion must depend on plan-conformance"
}

capture_approved_plan() {
    local state="$1" evidence_json at
    evidence_json="$(jq -c '[.events[] | select(.action == "graph_approved")] | last.evidence // []' "$state")"
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    atomic_jq "$state" '
        .approved_plan = {
            revision:.design_revision,
            approved_at:$at,
            approval_evidence:$evidence,
            plan:([.nodes[] | select(.id == "plan")][0] | {id,goal,outputs,evidence,outcome}),
            nodes:[.nodes[] | {id,type,role,goal,dependencies,human_gate,order}]
        }
    ' --arg at "$at" --argjson evidence "$evidence_json"
}

conformance_status() {
    "$conformance" status --state "$1"
}

require_current_conformance() {
    local state="$1" result
    result="$(conformance_status "$state")" || die "cannot determine plan conformance"
    [ "$(jq -r '.status' <<< "$result")" = "passed" ] \
        || die "plan conformance $(jq -r '.status + ": " + .reason' <<< "$result")"
}

augment_handoff() {
    local state="$1" feature handoff result tmp
    feature="$(jq -r '.feature' "$state")"
    handoff="$(dirname "$state")/${feature}.handoff.json"
    [ -f "$handoff" ] || die "handoff was not written"
    result="$(conformance_status "$state")"
    tmp="$(mktemp "${handoff}.tmp.XXXXXX")"
    jq --argjson conformance "$result" '.plan_conformance=$conformance' "$handoff" > "$tmp" \
        || { rm -f "$tmp"; die "cannot add plan-conformance status to handoff"; }
    mv "$tmp" "$handoff"
}

record_conformance_result() {
    local state="$1" node="$2" verdict="$3" normalized overall result_rel context_rel diff_rel at
    normalized="$("$conformance" record --state "$state" --node "$node" --verdict "$verdict")"
    overall="$(jq -r '.overall' <<< "$normalized")"
    result_rel="$(jq -r '.feature + "-" + .node_id' <<< "$normalized")"
    result_rel=".repomethod/evidence/${result_rel}-verdict.json"
    context_rel="$(jq -r '.context' <<< "$normalized")"
    diff_rel="$(jq -r '.diff' <<< "$normalized")"
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$overall" = "pass" ]; then
        atomic_jq "$state" '
            (.events | length + 1) as $seq
            | .nodes |= map(if .id == $id then
                .status="completed" | .outcome="passed"
                | .outputs=[$verdict] | .evidence=[$context,$diff,$verdict]
                | .conformance={snapshot:$snapshot,verdict_path:$verdict,blockers:$blockers}
              else . end)
            | .updated_at=$at
            | .events += [{seq:$seq,at:$at,action:"plan_conformance_passed",node_id:$id,detail:"full feature diff conforms to the approved plan",evidence:[$context,$diff,$verdict]}]
        ' --arg id "$node" --arg at "$at" --arg verdict "$result_rel" --arg context "$context_rel" --arg diff "$diff_rel" \
          --argjson snapshot "$(jq -c '.snapshot' <<< "$normalized")" --argjson blockers "$(jq -c '.blockers' <<< "$normalized")"
        cat <<< "$normalized"
        return 0
    fi

    local retries max_retries retry fix_id verify_id conformance_id fix_order verify_order conform_order
    retries="$(jq -r '.conformance_retry_count // 0' "$state")"
    max_retries="$(jq -r '.max_retries' "$state")"
    if [ "$retries" -lt "$max_retries" ]; then
        retry=$((retries + 1))
        fix_id="conformance-fix-${retry}"
        verify_id="conformance-verification-${retry}"
        conformance_id="plan-conformance-${retry}"
        fix_order=$((60 + retry * 3))
        verify_order=$((fix_order + 1))
        conform_order=$((fix_order + 2))
        atomic_jq "$state" '
            (.events | length + 1) as $seq
            | .nodes |= map(if .id == $id then
                .status="completed" | .outcome="failed"
                | .outputs=[$verdict] | .evidence=[$context,$diff,$verdict]
                | .conformance={snapshot:$snapshot,verdict_path:$verdict,blockers:$blockers}
              else . end)
            | .nodes += [
                {id:$fix_id,type:"fix",status:"pending",goal:"Correct blockers from plan-conformance review",role:"Implementer",dependencies:[$id],inputs:[$verdict],outputs:[],evidence:[],human_gate:false,outcome:null,attempt:0,order:$fix_order},
                {id:$verify_id,type:"verification",status:"pending",goal:"Re-run the configured verification command after conformance fixes",role:"Verifier",dependencies:[$fix_id],inputs:[$fix_id],outputs:[],evidence:[],human_gate:false,outcome:null,attempt:0,order:$verify_order},
                {id:$conformance_id,type:"plan-conformance",status:"pending",goal:"Re-review the full feature diff against the approved plan",role:"Plan Reviewer",dependencies:[$verify_id],inputs:[$verify_id],outputs:[],evidence:[],human_gate:false,outcome:null,attempt:0,order:$conform_order}
              ]
            | .nodes |= map(
                if .id != $fix_id and .id != $verify_id and .id != $conformance_id and (.dependencies | index($id)) != null
                then .dependencies |= map(if . == $id then $conformance_id else . end)
                else . end)
            | .conformance_retry_count=$retry
            | .updated_at=$at
            | .events += [{seq:$seq,at:$at,action:"plan_conformance_failed",node_id:$id,detail:("blockers require retry " + ($retry|tostring)),evidence:[$context,$diff,$verdict]}]
        ' --arg id "$node" --arg at "$at" --arg verdict "$result_rel" --arg context "$context_rel" --arg diff "$diff_rel" \
          --arg fix_id "$fix_id" --arg verify_id "$verify_id" --arg conformance_id "$conformance_id" \
          --argjson retry "$retry" --argjson fix_order "$fix_order" --argjson verify_order "$verify_order" --argjson conform_order "$conform_order" \
          --argjson snapshot "$(jq -c '.snapshot' <<< "$normalized")" --argjson blockers "$(jq -c '.blockers' <<< "$normalized")"
    else
        atomic_jq "$state" '
            (.events | length + 1) as $seq
            | .nodes |= map(
                if .id == $id then .status="completed" | .outcome="failed"
                  | .outputs=[$verdict] | .evidence=[$context,$diff,$verdict]
                  | .conformance={snapshot:$snapshot,verdict_path:$verdict,blockers:$blockers}
                elif .id == "completion" then .status="blocked" | .outcome="conformance_retry_limit"
                else . end)
            | .status="blocked" | .updated_at=$at
            | .events += [{seq:$seq,at:$at,action:"plan_conformance_retry_limit_reached",node_id:$id,detail:"plan-conformance blockers remain after the retry limit",evidence:[$context,$diff,$verdict]}]
        ' --arg id "$node" --arg at "$at" --arg verdict "$result_rel" --arg context "$context_rel" --arg diff "$diff_rel" \
          --argjson snapshot "$(jq -c '.snapshot' <<< "$normalized")" --argjson blockers "$(jq -c '.blockers' <<< "$normalized")"
    fi
    cat <<< "$normalized"
    return 2
}

command="${1:-}"
[ -n "$command" ] || exec "$engine" "$@"
shift
original_args=("$command" "$@")

if [ "$command" = "init" ]; then
    mode="$(find_option --mode "$@" || true)"; [ -n "$mode" ] || mode="graph"
    if [ "$mode" = "classic" ]; then exec "$engine" "${original_args[@]}"; fi
    feature="$(find_option --feature "$@" || true)"; [ -n "$feature" ] || die "--feature is required"
    state="$(find_option --state "$@" || true)"; [ -n "$state" ] || state=".repomethod/workflows/${feature}.json"
    pc_goal="Review the full feature diff against the approved plan with the fixed conformance rubric"
    filtered=(init)
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--node-goal" ]; then
            [ "$#" -ge 3 ] || die "--node-goal requires <id> <text>"
            if [ "$2" = "plan-conformance" ]; then pc_goal="$3"; shift 3; continue; fi
            filtered+=("$1" "$2" "$3"); shift 3; continue
        fi
        filtered+=("$1"); shift
    done
    "$engine" "${filtered[@]}" >/dev/null
    patch_graph_init "$state" "$pc_goal"
    dispatch_graph "$state"
    exit 0
fi

state="$(find_state_arg "$@" || true)"
if [ "$command" = "approve-and-dispatch" ] && [ -z "$state" ]; then state="$(discover_single_proposal)"; fi
if [ -n "$state" ] && [ -f "$state" ] && [ "$(jq -r '.mode // empty' "$state")" = "classic" ]; then
    exec "$engine" "${original_args[@]}"
fi

case "$command" in
    help|-h|--help)
        "$engine" "$command"
        echo '  workflow-graph.sh conform --state <file> --node <plan-conformance-id> --verdict <verdict.json>'
        ;;
    dispatch)
        [ -n "$state" ] || die "--state is required"
        dispatch_graph "$state"
        ;;
    approve-graph|approve-and-dispatch)
        [ -n "$state" ] || die "--state is required"
        validate_required_graph "$state"
        if [ "$command" = "approve-and-dispatch" ]; then
            args=(approve-and-dispatch --state "$state")
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--state" ]; then shift 2; continue; fi
                args+=("$1"); shift
            done
            "$engine" "${args[@]}" >/dev/null
            capture_approved_plan "$state"
            dispatch_graph "$state"
        else
            "$engine" "${original_args[@]}"
            capture_approved_plan "$state"
        fi
        ;;
    remove-node)
        node="$(find_option --node "$@" || true)"
        [ "$node" != "plan-conformance" ] || die "cannot remove required node: plan-conformance"
        exec "$engine" "${original_args[@]}"
        ;;
    add-node)
        type="$(find_option --type "$@" || true)"
        [ "$type" != "plan-conformance" ] || die "plan-conformance is a reserved required node type"
        exec "$engine" "${original_args[@]}"
        ;;
    edit-node)
        node="$(find_option --node "$@" || true)"
        if [ "$node" = "plan-conformance" ]; then
            if printf '%s\n' "$@" | grep -Eq '^--(type|depends)$'; then
                die "cannot change required boundary node type or dependencies: plan-conformance"
            fi
        fi
        exec "$engine" "${original_args[@]}"
        ;;
    start)
        [ -n "$state" ] || die "--state is required"
        node="$(find_option --node "$@" || true)"; [ -n "$node" ] || die "--node is required"
        type="$(jq -r --arg id "$node" '[.nodes[]|select(.id==$id)|.type][0] // empty' "$state")"
        if [ "$type" != "plan-conformance" ]; then exec "$engine" "${original_args[@]}"; fi
        prep="$("$conformance" prepare --state "$state" --node "$node")"
        "$engine" start --state "$state" --node "$node"
        atomic_jq "$state" '(.nodes[] | select(.id==$id) | .inputs)=$inputs' \
            --arg id "$node" --argjson inputs "$(jq -c '.inputs' <<< "$prep")"
        printf '%s\n' "$prep"
        ;;
    complete)
        [ -n "$state" ] || die "--state is required"
        node="$(find_option --node "$@" || true)"; [ -n "$node" ] || die "--node is required"
        type="$(jq -r --arg id "$node" '[.nodes[]|select(.id==$id)|.type][0] // empty' "$state")"
        [ "$type" != "plan-conformance" ] || die "plan-conformance cannot be completed manually; use conform"
        if [ "$type" = "completion" ]; then require_current_conformance "$state"; fi
        exec "$engine" "${original_args[@]}"
        ;;
    approve)
        [ -n "$state" ] || die "--state is required"
        node="$(find_option --node "$@" || true)"; [ -n "$node" ] || die "--node is required"
        type="$(jq -r --arg id "$node" '[.nodes[]|select(.id==$id)|.type][0] // empty' "$state")"
        if [ "$type" = "completion" ]; then require_current_conformance "$state"; fi
        exec "$engine" "${original_args[@]}"
        ;;
    conform)
        [ -n "$state" ] || die "--state is required"
        node="$(find_option --node "$@" || true)"; [ -n "$node" ] || die "--node is required"
        verdict="$(find_option --verdict "$@" || true)"; [ -n "$verdict" ] || die "--verdict is required"
        status="$(jq -r --arg id "$node" '[.nodes[]|select(.id==$id)|.status][0] // empty' "$state")"
        if [ "$status" = "pending" ]; then
            prep="$("$conformance" prepare --state "$state" --node "$node")"
            "$engine" start --state "$state" --node "$node"
            atomic_jq "$state" '(.nodes[] | select(.id==$id) | .inputs)=$inputs' --arg id "$node" --argjson inputs "$(jq -c '.inputs' <<< "$prep")"
        elif [ "$status" != "in_progress" ]; then
            die "plan-conformance node is not runnable or in progress: $node"
        fi
        record_conformance_result "$state" "$node" "$verdict"
        ;;
    handoff)
        [ -n "$state" ] || die "--state is required"
        "$engine" "${original_args[@]}"
        augment_handoff "$state"
        ;;
    preview)
        "$engine" "${original_args[@]}"
        echo 'plan conformance: Graph requires Verification -> Plan Conformance -> Completion; conformance dispatch requires fresh context'
        ;;
    *)
        exec "$engine" "${original_args[@]}"
        ;;
esac
