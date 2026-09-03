#!/usr/bin/env bash
# plan-conformance.sh — deterministic context and verdict validation for Graph plan conformance.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
descope_ledger="${here}/descope-ledger.sh"
plan_obligations="${here}/plan-obligations.sh"
verify_provenance="${here}/verify-provenance.sh"

fail() {
    echo "PLAN-CONFORMANCE-ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
usage:
  plan-conformance.sh prepare --state <workflow-state> --node <plan-conformance-id>
  plan-conformance.sh template --state <workflow-state> --node <plan-conformance-id>
  plan-conformance.sh record --state <workflow-state> --node <plan-conformance-id> --verdict <verdict.json>
  plan-conformance.sh check --state <workflow-state>
  plan-conformance.sh status --state <workflow-state>
USAGE
}

require_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || fail "missing value for $1"
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

sha256_file() {
    [ -f "$1" ] || fail "required file is missing: $1"
    sha256_stream < "$1"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

state=""
node=""
verdict=""
command="${1:-}"
[ -n "$command" ] || { usage; exit 1; }
shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --state) require_value "$@"; state="$2"; shift 2 ;;
        --node) require_value "$@"; node="$2"; shift 2 ;;
        --verdict) require_value "$@"; verdict="$2"; shift 2 ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ -n "$state" ] || fail "--state is required"
[ -f "$state" ] || fail "workflow state not found: $state"
[ ! -L "$state" ] || fail "workflow state must not be a symlink"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

state_dir="$(cd "$(dirname "$state")" && pwd -P)"
state="${state_dir}/$(basename "$state")"
feature="$(jq -r '.feature // empty' "$state" 2>/dev/null)" || fail "cannot read workflow state"
[[ "$feature" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "invalid feature slug in workflow state: $feature"
mode="$(jq -r '.mode // empty' "$state")"
case "$mode" in graph|classic) ;; *) fail "invalid workflow mode: $mode" ;; esac

repo_root="$(git -C "$state_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || repo_root="$(jq -r '.repo_root // empty' "$state")"
[ -d "$repo_root" ] || fail "cannot locate repository for workflow state"
repo_root="$(cd "$repo_root" && pwd -P)"

base_ref="$(jq -r '.config.base_ref? // empty' "$state")"
if [ "$mode" = "graph" ]; then
    [[ "$base_ref" =~ ^[0-9a-f]{40}$ ]] || fail "Graph workflow is missing a pinned 40-character config.base_ref"
    git -C "$repo_root" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null \
        || fail "pinned base_ref does not resolve in this repository: $base_ref"
fi

spec_rel="specs/${feature}.md"
spec_path="${repo_root}/${spec_rel}"
artifact_rel=".repomethod/workflows/${feature}.plan-obligations.json"
artifact_path="${repo_root}/${artifact_rel}"
rubric_rel=".repomethod/templates/plan-conformance-rubric.md"
rubric_path="${repo_root}/${rubric_rel}"
evidence_dir="${repo_root}/.repomethod/evidence"

repo_rel() {
    case "$1" in
        "$repo_root"/*) printf '%s\n' "${1#"$repo_root"/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

validate_graph_authorities() {
    [ "$mode" = "graph" ] || return 0
    [ -f "$spec_path" ] || fail "feature spec is missing: $spec_rel"
    [ -f "$artifact_path" ] || fail "approved plan-obligations artifact is missing: $artifact_rel"
    [ -f "$rubric_path" ] || fail "plan-conformance rubric is missing: $rubric_rel"
    [ -x "$plan_obligations" ] || fail "plan-obligations.sh is missing or not executable"
    [ -x "$verify_provenance" ] || fail "verify-provenance.sh is missing or not executable"
    [ -x "$descope_ledger" ] || fail "descope-ledger.sh is missing or not executable"

    "$plan_obligations" check --mode graph --spec "$spec_path" --repo "$repo_root" >/dev/null 2>&1 \
        || fail "plan obligations are missing, stale, invalid, or unapproved"
    "$verify_provenance" --spec "$spec_path" --state "$state" --repo "$repo_root" >/dev/null 2>&1 \
        || fail "plan provenance is invalid or has untreated orphan obligations"

    jq -e --arg feature "$feature" '
        .schema_version == 1
        and .feature == $feature
        and .mode == "graph"
        and .review.status == "approved"
        and (.obligations | type == "array" and length > 0)
        and all(.obligations[];
            (.id | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$"))
            and (.type == "shape" or .type == "behaviour" or .type == "prohibition" or .type == "process")
            and .review_status == "approved")
    ' "$artifact_path" >/dev/null 2>&1 || fail "invalid or unapproved plan-obligations artifact"

    jq -e '
        (.approved_plan | type == "object")
        and (.approved_plan.revision == .design_revision)
        and (.approved_plan.nodes | type == "array")
        and (.approved_plan.plan | type == "object")
        and (.approved_plan.approval_evidence | type == "array" and length > 0)
    ' "$state" >/dev/null 2>&1 || fail "workflow has no approved-plan snapshot for the current graph revision"
}

render_full_diff() {
    local output="$1" rel
    : > "$output"
    (
        cd "$repo_root"
        git diff --binary --full-index "$base_ref" -- . \
            ':(exclude).repomethod/**' > "$output"
        while IFS= read -r -d '' rel; do
            case "$rel" in
                .repomethod/*) continue ;;
            esac
            printf '\n' >> "$output"
            git diff --no-index --binary -- /dev/null "$rel" >> "$output" 2>/dev/null || true
        done < <(git ls-files --others --exclude-standard -z)
    )
}

canonical_descope_state() {
    "$descope_ledger" state --state "$state" 2>/dev/null | jq -S . \
        || fail "cannot read canonical descope state"
}

snapshot_json() {
    local diff_file="$1" descopes_json approved_plan_json
    local diff_sha obligations_sha descopes_sha approved_plan_sha rubric_sha digest
    validate_graph_authorities
    render_full_diff "$diff_file"
    descopes_json="$(canonical_descope_state)"
    approved_plan_json="$(jq -S '.approved_plan' "$state")"
    diff_sha="$(sha256_file "$diff_file")"
    obligations_sha="$(sha256_file "$artifact_path")"
    descopes_sha="$(printf '%s' "$descopes_json" | sha256_stream)"
    approved_plan_sha="$(printf '%s' "$approved_plan_json" | sha256_stream)"
    rubric_sha="$(sha256_file "$rubric_path")"
    digest="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$base_ref" "$diff_sha" "$approved_plan_sha" "$obligations_sha" "$descopes_sha" "$rubric_sha" \
        | sha256_stream)"
    jq -n \
        --arg base_ref "$base_ref" --arg diff_sha "$diff_sha" \
        --arg approved_plan_sha "$approved_plan_sha" --arg obligations_sha "$obligations_sha" \
        --arg descopes_sha "$descopes_sha" --arg rubric_sha "$rubric_sha" --arg digest "$digest" \
        '{base_ref:$base_ref,diff_sha256:$diff_sha,approved_plan_sha256:$approved_plan_sha,plan_obligations_sha256:$obligations_sha,descopes_sha256:$descopes_sha,rubric_sha256:$rubric_sha,digest:$digest}'
}

require_conformance_node() {
    [ -n "$node" ] || fail "--node is required"
    [[ "$node" =~ ^plan-conformance(-[0-9]+)?$ ]] || fail "invalid plan-conformance node id: $node"
    jq -e --arg id "$node" 'any(.nodes[]; .id == $id and .type == "plan-conformance")' "$state" >/dev/null \
        || fail "unknown plan-conformance node: $node"
}

context_path_for_node() { printf '%s/%s-%s-context.json\n' "$evidence_dir" "$feature" "$1"; }
diff_path_for_node() { printf '%s/%s-%s-diff.patch\n' "$evidence_dir" "$feature" "$1"; }
verdict_path_for_node() { printf '%s/%s-%s-verdict.json\n' "$evidence_dir" "$feature" "$1"; }

# Emit a verdict skeleton with one table row per approved obligation so the
# reviewer fills in status + rationale instead of hand-typing nested JSON.
# overall/status are intentionally blank: `record` rejects it until completed.
template_verdict() {
    require_conformance_node
    [ "$mode" = "graph" ] || fail "plan conformance applies only to Graph workflows"
    [ -f "$artifact_path" ] || fail "approved plan-obligations artifact is missing: $artifact_rel"
    jq -e '.review.status == "approved"' "$artifact_path" >/dev/null 2>&1 \
        || fail "plan-obligations artifact is not approved"
    jq '{
        schema_version: 1,
        overall: "",
        table: [.obligations[] | {plan_ref: .id, type: .type, status: "", rationale: ""}],
        blockers: []
    }' "$artifact_path"
}

prepare_context() {
    require_conformance_node
    [ "$mode" = "graph" ] || fail "plan conformance applies only to Graph workflows"
    mkdir -p "$evidence_dir"
    local context_path diff_path tmp snapshot descopes_json
    context_path="$(context_path_for_node "$node")"
    diff_path="$(diff_path_for_node "$node")"
    tmp="$(mktemp "${context_path}.tmp.XXXXXX")"
    snapshot="$(snapshot_json "$diff_path")"
    descopes_json="$(canonical_descope_state)"

    jq -n \
        --arg feature "$feature" --arg node_id "$node" --arg generated_at "$(now_utc)" \
        --arg spec "$spec_rel" --arg state_rel "$(repo_rel "$state")" \
        --arg obligations "$artifact_rel" --arg diff_rel "$(repo_rel "$diff_path")" \
        --arg rubric "$rubric_rel" --arg context_rel "$(repo_rel "$context_path")" \
        --argjson snapshot "$snapshot" --argjson approved_plan "$(jq -c '.approved_plan' "$state")" \
        --argjson plan_obligations "$(jq -c '.' "$artifact_path")" \
        --argjson descopes "$descopes_json" '
        {
          schema_version:1,
          feature:$feature,
          node_id:$node_id,
          generated_at:$generated_at,
          authorities:{
            spec:$spec,
            workflow_state:$state_rel,
            plan_obligations:$obligations,
            full_feature_diff:$diff_rel,
            rubric:$rubric
          },
          snapshot:$snapshot,
          approved_plan:$approved_plan,
          plan_obligations:$plan_obligations,
          descopes:$descopes,
          review_contract:{
            required_row_statuses:["pass","fail","accepted_descope","orphan"],
            blocker_categories:["shape","behaviour","prohibition","process","descope","orphan","scope"],
            rule:"one verdict-table row per approved obligation; overall pass requires no blockers, no untreated orphans, and no unreviewed/rejected descopes"
          }
        }
    ' > "$tmp" || { rm -f "$tmp"; fail "cannot render conformance context"; }
    mv "$tmp" "$context_path"
    git -C "$repo_root" add -f -- "$context_path" "$diff_path" 2>/dev/null || true
    jq -n --arg context "$(repo_rel "$context_path")" --arg diff "$(repo_rel "$diff_path")" \
        --arg rubric "$rubric_rel" --arg obligations "$artifact_rel" --arg spec "$spec_rel" \
        --argjson snapshot "$snapshot" \
        '{context:$context,diff:$diff,rubric:$rubric,plan_obligations:$obligations,spec:$spec,snapshot:$snapshot,inputs:[$context,$diff,$rubric,$obligations,$spec]}'
}

validate_verdict_schema() {
    local file="$1"
    jq -e '
        .schema_version == 1
        and (.overall == "pass" or .overall == "blocked")
        and (.table | type == "array")
        and (.blockers | type == "array")
        and all(.table[];
            (.plan_ref | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$"))
            and (.type == "shape" or .type == "behaviour" or .type == "prohibition" or .type == "process")
            and (.status == "pass" or .status == "fail" or .status == "accepted_descope" or .status == "orphan")
            and (.rationale | type == "string" and length > 0))
        and (([.table[].plan_ref] | length) == ([.table[].plan_ref] | unique | length))
        and all(.blockers[];
            (.id | type == "string" and length > 0)
            and (.category == "shape" or .category == "behaviour" or .category == "prohibition" or .category == "process" or .category == "descope" or .category == "orphan" or .category == "scope")
            and ((.plan_ref == null) or (.plan_ref | type == "string" and test("^obl\\.[a-z0-9][a-z0-9._-]*$")))
            and (.message | type == "string" and length > 0))
        and (([.blockers[].id] | length) == ([.blockers[].id] | unique | length))
    ' "$file" >/dev/null 2>&1 || fail "invalid conformance verdict schema: $file"
}

record_verdict() {
    require_conformance_node
    [ "$mode" = "graph" ] || fail "plan conformance applies only to Graph workflows"
    [ -n "$verdict" ] || fail "--verdict is required"
    [ -f "$verdict" ] || fail "verdict file not found: $verdict"
    [ ! -L "$verdict" ] || fail "verdict file must not be a symlink"
    validate_verdict_schema "$verdict"

    local context_path diff_path result_path current_diff snapshot current_snapshot descopes_json accepted_refs
    context_path="$(context_path_for_node "$node")"
    diff_path="$(diff_path_for_node "$node")"
    result_path="$(verdict_path_for_node "$node")"
    [ -f "$context_path" ] || fail "conformance context is missing; start/prepare the node first"
    snapshot="$(jq -c '.snapshot' "$context_path")"
    current_diff="$(mktemp "${TMPDIR:-/tmp}/repomethod-conformance-diff.XXXXXX")"
    current_snapshot="$(snapshot_json "$current_diff")"
    rm -f -- "$current_diff"
    [ "$(jq -r '.digest' <<< "$snapshot")" = "$(jq -r '.digest' <<< "$current_snapshot")" ] \
        || fail "conformance context is stale; repository or review authorities changed after prepare"

    jq -e --slurpfile verdict "$verdict" '
        (.obligations | map({id,type}) | sort_by(.id))
        == ($verdict[0].table | map({id:.plan_ref,type}) | sort_by(.id))
    ' "$artifact_path" >/dev/null 2>&1 || fail "verdict table must cover every approved obligation exactly once with the matching type"

    descopes_json="$(canonical_descope_state)"
    accepted_refs="$(jq -c '[.descopes[] | select(.status == "accepted") | .plan_ref] | unique' <<< "$descopes_json")"

    jq -e --argjson accepted "$accepted_refs" '
        all(.table[]; . as $row
            | if ($accepted | index($row.plan_ref)) != null then $row.status == "accepted_descope"
              else $row.status != "accepted_descope" end)
    ' "$verdict" >/dev/null 2>&1 || fail "accepted_descope rows must match the canonical accepted-descope state exactly"

    blocking_descopes="$(jq -r '.blocking_ids | length' <<< "$descopes_json")"
    if [ "$blocking_descopes" -gt 0 ] && [ "$(jq -r '.overall' "$verdict")" = "pass" ]; then
        fail "unreviewed or rejected descopes prevent a passing conformance verdict"
    fi

    if jq -e '.overall == "pass"' "$verdict" >/dev/null; then
        jq -e '(.blockers | length) == 0 and all(.table[]; .status == "pass" or .status == "accepted_descope")' "$verdict" >/dev/null \
            || fail "overall pass requires an empty blocker list and only pass/accepted_descope rows"
    else
        jq -e '(.blockers | length) > 0 or any(.table[]; .status == "fail" or .status == "orphan")' "$verdict" >/dev/null \
            || fail "overall blocked requires at least one blocker or failing/orphan row"
    fi

    tmp="$(mktemp "${result_path}.tmp.XXXXXX")"
    jq -n \
        --arg feature "$feature" --arg node_id "$node" --arg recorded_at "$(now_utc)" \
        --arg context "$(repo_rel "$context_path")" --arg diff "$(repo_rel "$diff_path")" \
        --arg verdict_source "$(repo_rel "$(cd "$(dirname "$verdict")" && pwd -P)/$(basename "$verdict")")" \
        --argjson snapshot "$snapshot" --slurpfile verdict "$verdict" '
        {
          schema_version:1,
          feature:$feature,
          node_id:$node_id,
          recorded_at:$recorded_at,
          context:$context,
          diff:$diff,
          verdict_source:$verdict_source,
          snapshot:$snapshot,
          overall:$verdict[0].overall,
          table:$verdict[0].table,
          blockers:$verdict[0].blockers
        }
    ' > "$tmp" || { rm -f "$tmp"; fail "cannot normalize conformance verdict"; }
    mv "$tmp" "$result_path"
    git -C "$repo_root" add -f -- "$result_path" 2>/dev/null || true
    cat "$result_path"
}

status_json() {
    if [ "$mode" != "graph" ]; then
        jq -n '{required:false,status:"not_applicable",reason:"Classic workflows do not require plan conformance"}'
        return 0
    fi

    local latest latest_id current_diff current_snapshot saved_digest reason status result_path
    latest="$(jq -c '[.nodes[] | select(.type == "plan-conformance" and .status == "completed" and .outcome == "passed" and (.conformance | type == "object"))] | sort_by(.order, .id) | last // empty' "$state")"
    if [ -z "$latest" ]; then
        if jq -e 'any(.nodes[]; .type == "plan-conformance" and .outcome == "failed")' "$state" >/dev/null; then
            status="blocked"; reason="latest plan-conformance attempt failed and no passing retry exists"
        else
            status="missing"; reason="no successful plan-conformance verdict is recorded"
        fi
        jq -n --arg status "$status" --arg reason "$reason" '{required:true,status:$status,reason:$reason}'
        return 0
    fi

    latest_id="$(jq -r '.id' <<< "$latest")"
    saved_digest="$(jq -r '.conformance.snapshot.digest // empty' <<< "$latest")"
    result_path="$(jq -r '.conformance.verdict_path // empty' <<< "$latest")"
    if [ -z "$saved_digest" ] || [ -z "$result_path" ]; then
        jq -n --arg node_id "$latest_id" '{required:true,status:"missing",reason:"successful node is missing conformance snapshot metadata",node_id:$node_id}'
        return 0
    fi
    if [ ! -f "${repo_root}/${result_path}" ]; then
        jq -n --arg node_id "$latest_id" --arg verdict "$result_path" '{required:true,status:"missing",reason:"conformance verdict artifact is missing",node_id:$node_id,verdict_path:$verdict}'
        return 0
    fi

    current_diff="$(mktemp "${TMPDIR:-/tmp}/repomethod-conformance-check.XXXXXX")"
    set +e
    current_snapshot="$(snapshot_json "$current_diff" 2>/dev/null)"
    snapshot_rc=$?
    set -e
    rm -f -- "$current_diff"
    if [ "$snapshot_rc" -ne 0 ]; then
        jq -n --arg node_id "$latest_id" '{required:true,status:"blocked",reason:"current conformance authorities are invalid or blocked",node_id:$node_id}'
        return 0
    fi
    if [ "$saved_digest" != "$(jq -r '.digest' <<< "$current_snapshot")" ]; then
        jq -n --arg node_id "$latest_id" --arg saved "$saved_digest" --arg current "$(jq -r '.digest' <<< "$current_snapshot")" \
            --arg verdict "$result_path" '{required:true,status:"stale",reason:"repository or review authorities changed after the conformance verdict",node_id:$node_id,snapshot_digest:$saved,current_snapshot_digest:$current,verdict_path:$verdict}'
        return 0
    fi

    if ! jq -e '.overall == "pass" and (.blockers | length) == 0' "${repo_root}/${result_path}" >/dev/null 2>&1; then
        jq -n --arg node_id "$latest_id" --arg verdict "$result_path" '{required:true,status:"blocked",reason:"recorded conformance verdict contains blockers",node_id:$node_id,verdict_path:$verdict}'
        return 0
    fi

    jq -n --arg node_id "$latest_id" --arg digest "$saved_digest" --arg verdict "$result_path" \
        '{required:true,status:"passed",reason:"successful plan-conformance verdict is current",node_id:$node_id,snapshot_digest:$digest,verdict_path:$verdict}'
}

case "$command" in
    prepare)
        prepare_context
        ;;
    template)
        template_verdict
        ;;
    record)
        record_verdict
        ;;
    status)
        status_json
        ;;
    check)
        result="$(status_json)"
        if [ "$(jq -r '.required' <<< "$result")" = "false" ]; then
            echo "NOT_APPLICABLE: Classic workflow"
            exit 0
        fi
        if [ "$(jq -r '.status' <<< "$result")" = "passed" ]; then
            echo "OK: plan conformance $(jq -r '.node_id' <<< "$result") is current"
            exit 0
        fi
        fail "$(jq -r '.status + ": " + .reason' <<< "$result")"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        fail "unknown command: $command"
        ;;
esac
