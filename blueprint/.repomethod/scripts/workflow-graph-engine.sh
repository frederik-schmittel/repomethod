#!/usr/bin/env bash
# workflow-graph.sh - persistent Classic and Graph workflow runner.
# shellcheck disable=SC2016 # jq programs are intentionally single-quoted.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
descope_ledger="${here}/descope-ledger.sh"

die() {
    echo "workflow-graph: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage:
  workflow-graph.sh init --feature <slug> --verify-command <command> [--mode <graph|classic>] [--state <file>] [--base <ref>] [--research <single|parallel>] [--max-parallel <n>] [--max-retries <n>] [--sequential-fallback <allow|block>] [--node-goal <id> <text>]...
  workflow-graph.sh preview --state <file>
  workflow-graph.sh add-node --state <file> --id <id> --type <type> --role <role> --goal <text> --order <n> [--depends <csv>] [--human-gate <true|false>]
  workflow-graph.sh edit-node --state <file> --node <id> [--type <type>] [--role <role>] [--goal <text>] [--order <n>] [--depends <csv>] [--human-gate <true|false>]   (--type and --depends are refused for the verification and completion nodes)
  workflow-graph.sh remove-node --state <file> --node <id>
  workflow-graph.sh set-retries --state <file> --max-retries <n>
  workflow-graph.sh approve-graph --state <file> --revision <n> --evidence <csv>
  workflow-graph.sh approve-and-dispatch [--state <file>] --revision <n> --approval-text <text>
  workflow-graph.sh dispatch --state <file>
  workflow-graph.sh next --state <file>
  workflow-graph.sh status --state <file>
  workflow-graph.sh start --state <file> --node <id>
  workflow-graph.sh complete --state <file> --node <id> --output <csv> --evidence <csv>
  workflow-graph.sh verify --state <file> --node <verification-id> [--evidence <file>]   (--evidence defaults to <repo-root>/.repomethod/evidence/<feature>-<node>.txt)
  workflow-graph.sh reverify --state <file> --node <verification-id> [--evidence <file>]   (re-runs the command on an already passed verification node; no state transition; same --evidence default)
  workflow-graph.sh fail --state <file> --node <verification-id> --reason <text> --evidence <csv>
  workflow-graph.sh block --state <file> --node <id> --reason <text>
  workflow-graph.sh approve --state <file> --node <id> --evidence <csv>
  workflow-graph.sh reject --state <file> --node <id> --reason <text>
  workflow-graph.sh add-task --state <file> --id <id> --goal <text> [--depends <csv>]   (the first add-task replaces the default implementation node)
  workflow-graph.sh handoff --state <file> --node <id> --next <text> [--changed <csv>] [--blocker <text>] [--claim <complete|needs_human>]
EOF
}

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        die "missing value for $1"
    fi
}

validate_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || die "invalid ${2:-id} '$1' (use lowercase letters, digits, dot, underscore, or hyphen)"
}

# Finding 5 / KORREKTUR 2: the workflow state file is a committed, editable
# artifact and every runner derives write paths from its directory
# (<state_dir>/<feature>.handoff.json, and in supervisor.sh three more paths
# plus a gate-log name). Refuse the state if the state file itself, or any path
# segment up to its repository root, is a symlink — a symlink there redirects
# those writes outside the workflow directory. This must run BEFORE any
# `cd ... && pwd`, which resolves the symlink away.
# ponytail: ceiling is the repo root located by a lexical `.git` search; outside
# a git repo only the state file and its own directory are checked (that is the
# only shape both standalone blueprint scripts can establish without cd/pwd).
refuse_symlinked_state() {
    local sp="$1" p root=""
    p="$(dirname "$sp")"
    while :; do
        if [ -e "$p/.git" ]; then root="$p"; break; fi
        case "$p" in /|.) break ;; esac
        p="$(dirname "$p")"
    done
    [ -L "$sp" ] && die "refusing a workflow state reached through a symlink: $sp"
    p="$(dirname "$sp")"
    while :; do
        [ -L "$p" ] && die "refusing a workflow state reached through a symlinked directory: $p"
        [ -n "$root" ] || break
        [ "$p" = "$root" ] && break
        p="$(dirname "$p")"
    done
}

validate_design_id() {
    validate_id "$1"
    [[ ! "$1" =~ ^(fix|verification)-[0-9]+$ ]] \
        || die "node id is reserved for generated fix loops: $1"
}

validate_non_negative_integer() {
    case "$2" in
        ''|*[!0-9]*) die "$1 must be a non-negative integer" ;;
    esac
}

csv_json() {
    printf '%s\n' "$1" | jq -R 'split(",") | map(select(length > 0))'
}

validate_evidence() {
    local csv="$1" item
    local -a items
    IFS=',' read -r -a items <<< "$csv"
    [ "${#items[@]}" -gt 0 ] || die "at least one evidence file is required"
    for item in "${items[@]}"; do
        [ -s "$item" ] || die "evidence file is missing or empty: $item"
    done
}

now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

release_state_lock() {
    [ -n "${lock_dir:-}" ] || return 0
    rm -f "${lock_dir}/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}

acquire_state_lock() {
    local attempt=0 owner=""
    lock_dir="${state}.lock"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [ -f "${lock_dir}/pid" ]; then
            IFS= read -r owner < "${lock_dir}/pid" || true
            if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
                rm -f "${lock_dir}/pid"
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || die "state is locked by another writer: $state"
        sleep 0.1
    done
    printf '%s\n' "$$" > "${lock_dir}/pid"
    trap release_state_lock EXIT INT TERM
}

validate_state_file() {
    local file="$1"
    jq -e '
        .schema_version == 2
        and (.mode == "graph" or .mode == "classic")
        and (.feature | type == "string" and length > 0)
        and (.repo_root | type == "string" and length > 0)
        and (.config | type == "object")
        and (.config.research == "single" or .config.research == "parallel")
        and (.config.max_parallel | type == "number" and . >= 1)
        and (.config.sequential_fallback == "allow" or .config.sequential_fallback == "block")
        and (.config.verification_command | type == "string" and length > 0)
        and (.design_revision | type == "number")
        and (.max_retries | type == "number" and . >= 0)
        and (.retry_count | type == "number" and . >= 0)
        and (.nodes | type == "array")
        and (([.nodes[].id] | length) == ([.nodes[].id] | unique | length))
        and (
          .nodes as $nodes
          | all($nodes[];
              (.id | type == "string")
              and (.type | type == "string")
              and (.status | type == "string")
              and (.goal | type == "string")
              and (.role | type == "string")
              and (.dependencies | type == "array")
              and (.inputs | type == "array")
              and (.outputs | type == "array")
              and (.evidence | type == "array")
              and (.human_gate | type == "boolean")
              and (.order | type == "number")
              and (.attempt | type == "number")
              and all(.dependencies[]; . as $dependency | any($nodes[]; .id == $dependency))
            )
        )
        and (
          .nodes as $nodes
          | def acyclic($id; $seen):
              if ($seen | index($id)) != null then false
              else all(
                ($nodes[] | select(.id == $id) | .dependencies[]);
                acyclic(.; $seen + [$id])
              )
              end;
          all($nodes[]; acyclic(.id; []))
        )
    ' "$file" >/dev/null
}

load_state() {
    [ -n "${state:-}" ] || die "--state is required"
    [ -f "$state" ] || die "state not found: $state"
    validate_state_file "$state" || die "invalid workflow state: $state"
    # init validates --feature as a slug, but the state file is a committed,
    # contributor-editable artifact and validate_state_file only asserts
    # "non-empty string". A slug contains no "/" and cannot be "..", which
    # confines every derived path to its own directory by construction.
    refuse_symlinked_state "$state"
    validate_id "$(jq -r '.feature' "$state")" "feature slug in ${state}:"
}

update_state() {
    local filter="$1" tmp
    shift
    tmp="$(mktemp "${state}.tmp.XXXXXX")"
    if jq "$@" "$filter" "$state" > "$tmp"; then
        if ! validate_state_file "$tmp"; then
            rm -f "$tmp"
            die "state update would create an invalid or cyclic graph"
        fi
        mv "$tmp" "$state"
    else
        rm -f "$tmp"
        die "state update failed"
    fi
}

discover_single_proposal() {
    local candidate
    local -a proposals=()
    if [ -d ".repomethod/workflows" ]; then
        while IFS= read -r candidate; do
            if jq -e '.mode == "graph" and .status == "awaiting_approval"' "$candidate" >/dev/null 2>&1; then
                proposals+=("$candidate")
            fi
        done < <(find ".repomethod/workflows" -maxdepth 1 -type f -name '*.json' -print | sort)
    fi
    case "${#proposals[@]}" in
        0) die "no graph awaiting approval found; pass the displayed --state" ;;
        1) printf '%s\n' "${proposals[0]}" ;;
        *) die "multiple graphs awaiting approval found; pass the displayed --state" ;;
    esac
}

runnable_ids() {
    jq -r '
        select(.status == "active" or (.mode == "graph" and .status == "discovering"))
        | .nodes as $nodes
        | [
            $nodes[]
            | select(.status == "pending")
            | select(
                .dependencies as $deps
                | all($deps[]; . as $dependency
                    | any($nodes[]; .id == $dependency and .status == "completed"))
              )
            | {id, order}
          ]
        | sort_by(.order, .id)
        | .[].id
    ' "$state"
}

dispatch_json() {
    jq '
        .nodes as $nodes
        | def resolved_node:
            . as $node
            | {
                node_id: $node.id,
                type: $node.type,
                role: $node.role,
                goal: $node.goal,
                next_attempt: ($node.attempt + 1),
                human_gate: $node.human_gate,
                declared_inputs: $node.inputs,
                dependencies: [
                  $node.dependencies[] as $dependency
                  | $nodes[]
                  | select(.id == $dependency)
                  | {node_id:.id, outcome, outputs, evidence}
                ],
                fresh_context_required: ($node.type == "verification"),
                _order: $node.order
              };
        ([
          $nodes[]
          | select(.status == "pending")
          | select(
              .dependencies as $deps
              | all($deps[]; . as $dependency
                  | any($nodes[]; .id == $dependency and .status == "completed"))
            )
          | resolved_node
        ] | sort_by(._order, .node_id) | map(del(._order))) as $ready
        | ([$nodes[] | select(.status == "in_progress")] | length) as $running
        | ([0, (.config.max_parallel - $running)] | max) as $slots
        | {
            schema_version,
            feature,
            mode,
            config,
            workflow_status: .status,
            runnable: (
              if (.status == "active" or (.mode == "graph" and .status == "discovering"))
              then $ready[0:$slots]
              else []
              end
            )
          }
    ' "$state"
}

preview_workflow() {
    jq -r --arg state_path "$state" '
        "state=\($state_path) feature=\(.feature) mode=\(.mode) status=\(.status) revision=\(.design_revision) retries=\(.retry_count)/\(.max_retries)",
        "config: research=\(.config.research) max_parallel=\(.config.max_parallel) sequential_fallback=\(.config.sequential_fallback) verify=\(.config.verification_command)",
        "ID\tTYPE\tROLE\tDEPENDS ON\tHUMAN GATE\tGOAL",
        (.nodes
          | sort_by(.order, .id)[]
          | [.id, .type, .role, (.dependencies | join(",")), (.human_gate | tostring), .goal]
          | @tsv),
        "bounded feedback loop: verification command pass -> completion; failure -> fix-N -> verification-N (maximum \(.max_retries) retries)"
    ' "$state"
}

validate_graph_approval_request() {
    local requested_revision="$1" workflow_status current_revision
    [ "$(jq -r '.mode' "$state")" = "graph" ] || die "only graph workflows require graph approval"
    workflow_status="$(jq -r '.status' "$state")"
    [ "$workflow_status" = "awaiting_approval" ] \
        || die "graph is not awaiting approval: $workflow_status"
    validate_non_negative_integer "--revision" "$requested_revision"
    current_revision="$(jq -r '.design_revision' "$state")"
    [ "$requested_revision" = "$current_revision" ] \
        || die "displayed revision $requested_revision is stale; current revision is $current_revision"
    jq -e '
        .nodes as $nodes
        | def depends_on($id; $target):
            if $id == $target then true
            else any(($nodes[] | select(.id == $id) | .dependencies[]); depends_on(.; $target))
            end;
        any($nodes[]; .id == "plan" and .status == "completed")
        and any($nodes[]; .id == "completion" and .type == "completion")
        and any($nodes[]; .type == "verification")
        and any($nodes[]; .type == "implementation")
        and all($nodes[] | select(.type == "verification");
          .id as $verification
          | any($nodes[] | select(.type == "implementation"); depends_on($verification; .id)))
        and all($nodes[] | select(.type == "implementation"); depends_on(.id; "plan"))
        and all($nodes[] | select(.type == "implementation");
          .id as $implementation
          | any($nodes[] | select(.type == "verification"); depends_on(.id; $implementation)))
        and all($nodes[] | select(.type == "verification");
          depends_on("completion"; .id))
    ' "$state" >/dev/null \
        || die "graph invalid: completion must depend on Plan, Implementation, and every Verification node"
}

record_graph_approval() {
    local requested_revision="$1" evidence_csv="$2" evidence_json at
    evidence_json="$(csv_json "$evidence_csv")"
    at="$(now_utc)"
    update_state '
        (.events | length + 1) as $seq
        | .status = "active"
        | .updated_at = $at
        | .events += [{seq:$seq, at:$at, action:"graph_approved", node_id:"plan", detail:("developer approved displayed revision " + ($revision | tostring)), evidence:$evidence}]
    ' --arg at "$at" --argjson revision "$requested_revision" --argjson evidence "$evidence_json"
}

create_approval_evidence() {
    local requested_revision="$1" approval_text="$2"
    local feature state_dir evidence_dir evidence_path approved_at
    feature="$(jq -r '.feature' "$state")"
    state_dir="$(dirname "$state")"
    if [ "$(basename "$state_dir")" = "workflows" ]; then
        evidence_dir="$(dirname "$state_dir")/evidence"
    else
        evidence_dir="${state_dir}/evidence"
    fi
    mkdir -p "$evidence_dir"
    evidence_path="$(mktemp "${evidence_dir}/graph-approval-${feature}-r${requested_revision}.XXXXXX")"
    approved_at="$(now_utc)"
    {
        printf '# Graph Approval\n\n'
        printf 'State: %s\n' "$state"
        printf 'Revision: %s\n' "$requested_revision"
        printf 'Approval: %s\n' "$approval_text"
        printf 'Recorded at: %s\n' "$approved_at"
    } > "$evidence_path"
    printf '%s\n' "$evidence_path"
}

require_proposal_phase() {
    [ "$(jq -r '.mode' "$state")" = "graph" ] \
        || die "graph structure is available only in graph mode"
    [ "$(jq -r '.status' "$state")" = "awaiting_approval" ] \
        || die "graph structure can be changed only while awaiting approval"
}

start_node() {
    local node_id="$1" at running max_parallel
    runnable_ids | grep -Fxq "$node_id" || die "node is not runnable: $node_id"
    running="$(jq '[.nodes[] | select(.status == "in_progress")] | length' "$state")"
    max_parallel="$(jq -r '.config.max_parallel' "$state")"
    [ "$running" -lt "$max_parallel" ] \
        || die "parallel limit reached: ${running}/${max_parallel} workers"
    at="$(now_utc)"
    update_state '
        (.events | length + 1) as $seq
        | .nodes |= map(if .id == $id then .status = "in_progress" | .attempt += 1 else . end)
        | .updated_at = $at
        | .events += [{seq:$seq, at:$at, action:"started", node_id:$id, detail:"node work started"}]
    ' --arg id "$node_id" --arg at "$at"
}

verification_failure() {
    local node_id="$1" reason_text="$2" evidence_csv="$3"
    local retries max_retries retry fix_id verify_id verify_order fix_order at evidence_json
    retries="$(jq -r '.retry_count' "$state")"
    max_retries="$(jq -r '.max_retries' "$state")"
    evidence_json="$(csv_json "$evidence_csv")"
    at="$(now_utc)"
    if [ "$retries" -lt "$max_retries" ]; then
        retry=$((retries + 1))
        fix_id="fix-${retry}"
        verify_id="verification-${retry}"
        verify_order=$((50 + retry * 2))
        fix_order=$((verify_order - 1))
        update_state '
            (.events | length + 1) as $seq
            | .nodes |= map(if .id == $id then .status = "completed" | .outcome = "failed" | .evidence = $evidence else . end)
            | .nodes += [
                {id:$fix_id, type:"fix", status:"pending", goal:("Correct verification failure: " + $reason), role:"Implementer", dependencies:[$id], inputs:$evidence, outputs:[], evidence:[], human_gate:false, outcome:null, attempt:0, order:$fix_order},
                {id:$verify_id, type:"verification", status:"pending", goal:"Run the configured verification command after the correction", role:"Verifier", dependencies:[$fix_id], inputs:[$fix_id], outputs:[], evidence:[], human_gate:false, outcome:null, attempt:0, order:$verify_order}
              ]
            | .nodes |= map(
                if .id != $fix_id and .id != $verify_id and (.dependencies | index($id)) != null then
                  .dependencies |= map(if . == $id then $verify_id else . end)
                else . end
              )
            | .retry_count = $retry
            | .updated_at = $at
            | .events += [{seq:$seq, at:$at, action:"verification_failed", node_id:$id, detail:$reason, evidence:$evidence}]
        ' --arg id "$node_id" --arg reason "$reason_text" --arg fix_id "$fix_id" \
            --arg verify_id "$verify_id" --arg at "$at" --argjson retry "$retry" \
            --argjson fix_order "$fix_order" --argjson verify_order "$verify_order" \
            --argjson evidence "$evidence_json"
    else
        update_state '
            (.events | length + 1) as $seq
            | .nodes |= map(
                if .id == $id then .status = "completed" | .outcome = "failed" | .evidence = $evidence
                elif .id == "completion" then .status = "blocked" | .outcome = "retry_limit"
                else . end
              )
            | .status = "blocked"
            | .updated_at = $at
            | .events += [{seq:$seq, at:$at, action:"retry_limit_reached", node_id:$id, detail:$reason, evidence:$evidence}]
        ' --arg id "$node_id" --arg reason "$reason_text" --arg at "$at" \
            --argjson evidence "$evidence_json"
    fi
}

# Shared body of `verify` and `reverify`: run the configured verification
# command into "$evidence" and stage it. Derives the real repo root from where
# the state file lives (a committed workflow may run from a fresh clone at a
# different path). Echoes the command's exit status; the caller owns the
# state-machine transition.
_run_verification_into_evidence() {
    local node_id="$1" evidence_path="$2"
    local verification_command state_dir repo_root started_at verify_status
    verification_command="$(jq -r '.config.verification_command' "$state")"
    state_dir="$(cd "$(dirname "$state")" && pwd)"
    repo_root="$(git -C "$state_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$repo_root" ] || repo_root="$(jq -r '.repo_root' "$state")"
    [ -d "$repo_root" ] || die "cannot locate the repository for ${state} (recorded repo_root: $(jq -r '.repo_root' "$state"))"
    mkdir -p "$(dirname "$evidence_path")"
    started_at="$(now_utc)"
    {
        printf 'command=%s\n' "$verification_command"
        printf 'started_at=%s\n' "$started_at"
    } > "$evidence_path"
    set +e
    (cd "$repo_root" && bash -c "$verification_command") >> "$evidence_path" 2>&1
    verify_status=$?
    set -e
    printf 'exit_code=%s\n' "$verify_status" >> "$evidence_path"
    validate_evidence "$evidence_path"
    # The evidence path is known; force-stage it so a stray *.log / *.tmp.*
    # .gitignore rule can no longer make it un-committable. Best-effort: a
    # non-git target or a path outside the repo must not fail the run.
    git -C "$repo_root" add -f -- "$evidence_path" 2>/dev/null || true
    printf '%s\n' "$verify_status"
}

command="${1:-}"
[ -n "$command" ] || { usage; exit 1; }
shift

command -v jq >/dev/null 2>&1 || die "jq is required"

case "$command" in
    init)
        feature=""
        state=""
        mode="graph"
        research="single"
        max_parallel="2"
        max_retries="2"
        sequential_fallback="allow"
        verification_command=""
        base_ref_arg=""
        base_ref_set=false
        node_goal_ids=()
        node_goal_values=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --feature) require_value "$@"; feature="$2"; shift 2 ;;
                --state) require_value "$@"; state="$2"; shift 2 ;;
                --mode) require_value "$@"; mode="$2"; shift 2 ;;
                --research) require_value "$@"; research="$2"; shift 2 ;;
                --max-parallel) require_value "$@"; max_parallel="$2"; shift 2 ;;
                --max-retries) require_value "$@"; max_retries="$2"; shift 2 ;;
                --sequential-fallback) require_value "$@"; sequential_fallback="$2"; shift 2 ;;
                --verify-command) require_value "$@"; verification_command="$2"; shift 2 ;;
                --base)
                    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                        die "--base requires a value"
                    fi
                    base_ref_arg="$2"; base_ref_set=true; shift 2
                    ;;
                --node-goal)
                    if [ "$#" -lt 3 ] || [ -z "$2" ] || [ -z "$3" ]; then
                        die "--node-goal requires <id> <text>"
                    fi
                    node_goal_ids+=("$2")
                    node_goal_values+=("$3")
                    shift 3
                    ;;
                *) die "unknown init option: $1" ;;
            esac
        done
        [ -n "$feature" ] || die "--feature is required"
        validate_id "$feature"
        case "$mode" in graph|classic) ;; *) die "--mode must be graph or classic" ;; esac
        case "$research" in single|parallel) ;; *) die "--research must be single or parallel" ;; esac
        case "$sequential_fallback" in allow|block) ;; *) die "--sequential-fallback must be allow or block" ;; esac
        validate_non_negative_integer "--max-parallel" "$max_parallel"
        [ "$max_parallel" -gt 0 ] || die "--max-parallel must be greater than zero"
        validate_non_negative_integer "--max-retries" "$max_retries"
        [ -n "$verification_command" ] \
            || die "--verify-command is required (e.g. --verify-command '.repomethod/scripts/agent-gate.sh --spec specs/<feature>.md')"
        case "$verification_command" in
            *"<"*|*">"*)
                die "--verify-command still contains an angle-bracket placeholder: ${verification_command} — substitute the real spec path"
                ;;
        esac
        if [ "$mode" = "classic" ]; then
            research="single"
        fi

        node_goals_json='[]'
        for index in "${!node_goal_ids[@]}"; do
            node_goal_id="${node_goal_ids[$index]}"
            validate_design_id "$node_goal_id"
            for ((previous = 0; previous < index; previous++)); do
                [ "${node_goal_ids[$previous]}" != "$node_goal_id" ] \
                    || die "duplicate node goal: $node_goal_id"
            done
            node_goals_json="$(jq -c --arg id "$node_goal_id" --arg goal "${node_goal_values[$index]}" \
                '. + [{id:$id, goal:$goal}]' <<< "$node_goals_json")"
        done

        [ -n "$state" ] || state=".repomethod/workflows/${feature}.json"
        [ ! -e "$state" ] || die "state already exists: $state"
        mkdir -p "$(dirname "$state")"
        created_at="$(now_utc)"
        repo_root="$(pwd -P)"
        spec_path="specs/${feature}.md"

        # Base authority: init is the ONLY place a stateful workflow's fork point
        # is chosen. Pin it once as a 40-character lowercase SHA so no later
        # consumer re-guesses while a valid state value exists. Priority:
        # explicit --base, else a foreign @{upstream}, else origin/HEAD's target,
        # else main. An auto candidate whose merge-base is unresolvable is skipped.
        if [ "$base_ref_set" = true ]; then
            base_sha="$(git merge-base HEAD "$base_ref_arg" 2>/dev/null || true)"
            case "$base_sha" in
                *[!0-9a-f]*|'') die "cannot resolve explicit base ref: $base_ref_arg" ;;
            esac
        else
            base_sha=""
            base_up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
            base_cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            if [ -n "$base_up" ] && [ "${base_up#*/}" != "$base_cur" ]; then
                base_sha="$(git merge-base HEAD "$base_up" 2>/dev/null || true)"
            fi
            if [ -z "$base_sha" ]; then
                base_oh="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
                [ -n "$base_oh" ] && base_sha="$(git merge-base HEAD "$base_oh" 2>/dev/null || true)"
            fi
            [ -n "$base_sha" ] || base_sha="$(git merge-base HEAD main 2>/dev/null || true)"
            [ -n "$base_sha" ] || die "cannot resolve a base ref — pass --base <ref>"
        fi
        case "$base_sha" in
            *[!0-9a-f]*|'') die "base ref did not resolve to a 40-character commit SHA" ;;
        esac
        [ "${#base_sha}" -eq 40 ] || die "base ref did not resolve to a 40-character commit SHA"

        jq -n \
            --arg feature "$feature" --arg mode "$mode" --arg research "$research" \
            --arg fallback "$sequential_fallback" --arg verify "$verification_command" \
            --arg created_at "$created_at" --arg repo_root "$repo_root" --arg spec "$spec_path" \
            --arg base_ref "$base_sha" \
            --argjson max_parallel "$max_parallel" --argjson max_retries "$max_retries" \
            --argjson node_goals "$node_goals_json" '
            def node($id; $type; $goal; $role; $dependencies; $order):
              {id:$id, type:$type, status:"pending", goal:$goal, role:$role,
               dependencies:$dependencies, inputs:$dependencies, outputs:[], evidence:[],
               human_gate:false, outcome:null, attempt:0, order:$order};
            def apply_goals($nodes):
              reduce $node_goals[] as $custom
                ($nodes; if any(.[]; .id == $custom.id)
                         then map(if .id == $custom.id then .goal = $custom.goal else . end)
                         else error("unknown node goal: " + $custom.id) end);
            (if $mode == "classic" then
              [
                node("implementation"; "implementation"; "Implement the specified feature"; "Implementer"; []; 40),
                node("verification"; "verification"; "Run the configured verification command"; "Verifier"; ["implementation"]; 50),
                node("completion"; "completion"; "Record completion and handoff"; "Orchestrator"; ["verification"]; 60)
              ]
            elif $research == "parallel" then
              [
                node("research-architecture"; "research"; "Research repository architecture and constraints"; "Researcher"; []; 10),
                node("research-tests"; "research"; "Research tests, gates, and failure modes"; "Researcher"; []; 11),
                node("research-risks"; "research"; "Research risks, scope, and integration boundaries"; "Researcher"; []; 12),
                node("plan"; "plan"; "Propose the execution graph from research evidence"; "Planner"; ["research-architecture", "research-tests", "research-risks"]; 20),
                node("implementation"; "implementation"; "Implement the approved graph"; "Implementer"; ["plan"]; 40),
                node("verification"; "verification"; "Run the configured verification command"; "Verifier"; ["implementation"]; 50),
                node("completion"; "completion"; "Record completion and handoff"; "Orchestrator"; ["verification"]; 60)
              ]
            else
              [
                node("research"; "research"; "Research repository facts and constraints"; "Researcher"; []; 10),
                node("plan"; "plan"; "Propose the execution graph from research evidence"; "Planner"; ["research"]; 20),
                node("implementation"; "implementation"; "Implement the approved graph"; "Implementer"; ["plan"]; 40),
                node("verification"; "verification"; "Run the configured verification command"; "Verifier"; ["implementation"]; 50),
                node("completion"; "completion"; "Record completion and handoff"; "Orchestrator"; ["verification"]; 60)
              ]
            end) as $nodes
            | {
                schema_version:2,
                feature:$feature,
                mode:$mode,
                repo_root:$repo_root,
                status:(if $mode == "classic" then "active" else "discovering" end),
                design_revision:1,
                config:{research:$research, max_parallel:$max_parallel, sequential_fallback:$fallback, verification_command:$verify, base_ref:$base_ref},
                max_retries:$max_retries,
                retry_count:0,
                created_at:$created_at,
                updated_at:$created_at,
                nodes:apply_goals($nodes),
                events:[{seq:1, at:$created_at, action:"initialized", node_id:null, detail:(if $mode == "classic" then "classic loop initialized" else "graph discovery initialized" end)}]
              }
        ' > "$state" || { rm -f "$state"; die "invalid initial workflow configuration"; }
        validate_state_file "$state" || { rm -f "$state"; die "invalid initial workflow state"; }
        if ! "$descope_ledger" init --state "$state" >/dev/null; then
            rm -f "$state"
            die "failed to initialize descope ledger"
        fi
        dispatch_json
        ;;

    preview|add-node|edit-node|remove-node|set-retries|approve-graph|approve-and-dispatch|dispatch|next|status|start|complete|verify|reverify|fail|block|approve|reject|add-task|handoff)
        state=""
        node=""
        task_id=""
        node_type=""
        role=""
        goal=""
        order=""
        depends=""
        human_gate="false"
        output=""
        evidence=""
        reason=""
        revision=""
        approval_text=""
        max_retries=""
        changed=""
        next_step=""
        blocker=""
        claim="none"
        blocker_set=false
        goal_set=false
        depends_set=false
        type_set=false
        role_set=false
        order_set=false
        human_gate_set=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --state) require_value "$@"; state="$2"; shift 2 ;;
                --node) require_value "$@"; node="$2"; shift 2 ;;
                --id) require_value "$@"; task_id="$2"; shift 2 ;;
                --type) require_value "$@"; node_type="$2"; type_set=true; shift 2 ;;
                --role) require_value "$@"; role="$2"; role_set=true; shift 2 ;;
                --goal) require_value "$@"; goal="$2"; goal_set=true; shift 2 ;;
                --order) require_value "$@"; order="$2"; order_set=true; shift 2 ;;
                --depends) require_value "$@"; depends="$2"; depends_set=true; shift 2 ;;
                --human-gate) require_value "$@"; human_gate="$2"; human_gate_set=true; shift 2 ;;
                --output) require_value "$@"; output="$2"; shift 2 ;;
                --evidence) require_value "$@"; evidence="$2"; shift 2 ;;
                --reason) require_value "$@"; reason="$2"; shift 2 ;;
                --revision) require_value "$@"; revision="$2"; shift 2 ;;
                --approval-text) require_value "$@"; approval_text="$2"; shift 2 ;;
                --max-retries) require_value "$@"; max_retries="$2"; shift 2 ;;
                --changed) require_value "$@"; changed="$2"; shift 2 ;;
                --next) require_value "$@"; next_step="$2"; shift 2 ;;
                --blocker) require_value "$@"; blocker="$2"; blocker_set=true; shift 2 ;;
                --claim) require_value "$@"; claim="$2"; shift 2 ;;
                *) die "unknown $command option: $1" ;;
            esac
        done
        if [ "$command" = "approve-and-dispatch" ] && [ -z "$state" ]; then
            state="$(discover_single_proposal)"
        fi
        load_state
        # verify/reverify: with no caller-chosen evidence path, default to a
        # committable .txt under the real repo root, derived by the same rule as
        # _run_verification_into_evidence (git root of the state dir, else the
        # recorded .repo_root). An explicit --evidence keeps priority untouched.
        if [ -z "$evidence" ] && [ -n "$node" ] \
            && { [ "$command" = "verify" ] || [ "$command" = "reverify" ]; }; then
            evidence_state_dir="$(cd "$(dirname "$state")" && pwd)"
            evidence_repo_root="$(git -C "$evidence_state_dir" rev-parse --show-toplevel 2>/dev/null || true)"
            [ -n "$evidence_repo_root" ] || evidence_repo_root="$(jq -r '.repo_root' "$state")"
            evidence="${evidence_repo_root}/.repomethod/evidence/$(jq -r '.feature' "$state")-${node}.txt"
        fi
        case "$command" in preview|dispatch|next|status) ;; *) acquire_state_lock ;; esac

        case "$command" in
            preview)
                preview_workflow
                ;;
            dispatch)
                dispatch_json
                ;;
            next)
                runnable_ids
                ;;
            status)
                jq -r '"feature=\(.feature) mode=\(.mode) status=\(.status) retries=\(.retry_count)/\(.max_retries)", (.nodes | sort_by(.order, .id)[] | "\(.id)\t\(.type)\t\(.role)\t\(.status)\t\(.outcome // "-")")' "$state"
                ;;
            approve-graph)
                [ -n "$evidence" ] || die "--evidence is required"
                validate_evidence "$evidence"
                validate_graph_approval_request "$revision"
                record_graph_approval "$revision" "$evidence"
                ;;
            approve-and-dispatch)
                [ -n "$approval_text" ] || die "--approval-text is required"
                validate_graph_approval_request "$revision"
                evidence="$(create_approval_evidence "$revision" "$approval_text")"
                validate_evidence "$evidence"
                record_graph_approval "$revision" "$evidence"
                dispatch_json
                ;;
            add-node)
                require_proposal_phase
                [ -n "$task_id" ] || die "--id is required"
                [ -n "$node_type" ] || die "--type is required"
                [ -n "$role" ] || die "--role is required"
                [ -n "$goal" ] || die "--goal is required"
                [ -n "$order" ] || die "--order is required"
                validate_design_id "$task_id"
                validate_id "$node_type"
                validate_non_negative_integer "--order" "$order"
                case "$human_gate" in true|false) ;; *) die "--human-gate must be true or false" ;; esac
                jq -e --arg id "$task_id" 'all(.nodes[]; .id != $id)' "$state" >/dev/null \
                    || die "node already exists: $task_id"
                depends_json="$(csv_json "$depends")"
                missing="$(jq -r --argjson dependencies "$depends_json" '[ $dependencies[] as $id | select(all(.nodes[]; .id != $id)) | $id ] | join(",")' "$state")"
                [ -z "$missing" ] || die "unknown dependencies: $missing"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes += [{id:$id, type:$type, status:"pending", goal:$goal, role:$role, dependencies:$dependencies, inputs:$dependencies, outputs:[], evidence:[], human_gate:$human_gate, outcome:null, attempt:0, order:$order}]
                    | .design_revision += 1
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"node_added", node_id:$id, detail:$goal}]
                ' --arg id "$task_id" --arg type "$node_type" --arg role "$role" --arg goal "$goal" \
                    --arg at "$at" --argjson dependencies "$depends_json" \
                    --argjson human_gate "$human_gate" --argjson order "$order"
                ;;
            edit-node)
                require_proposal_phase
                [ -n "$node" ] || die "--node is required"
                jq -e --arg id "$node" 'any(.nodes[]; .id == $id)' "$state" >/dev/null \
                    || die "unknown node: $node"
                if ! $goal_set && ! $depends_set && ! $type_set && ! $role_set && ! $order_set && ! $human_gate_set; then
                    die "edit-node requires at least one changed field"
                fi
                if $type_set; then validate_id "$node_type"; fi
                if $type_set && { [ "$node" = "verification" ] || [ "$node" = "completion" ]; }; then
                    die "cannot change required boundary node type: $node"
                fi
                if $depends_set && { [ "$node" = "verification" ] || [ "$node" = "completion" ]; }; then
                    die "cannot change required boundary node dependencies: $node (add-task rewires verification automatically)"
                fi
                if $order_set; then validate_non_negative_integer "--order" "$order"; fi
                if $human_gate_set; then case "$human_gate" in true|false) ;; *) die "--human-gate must be true or false" ;; esac; fi
                depends_json="$(csv_json "$depends")"
                if $depends_set; then
                    missing="$(jq -r --argjson dependencies "$depends_json" '[ $dependencies[] as $id | select(all(.nodes[]; .id != $id)) | $id ] | join(",")' "$state")"
                    [ -z "$missing" ] || die "unknown dependencies: $missing"
                fi
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(
                        if .id == $id then
                          (if $goal_set then .goal = $goal else . end)
                          | (if $depends_set then .dependencies = $dependencies | .inputs = $dependencies else . end)
                          | (if $type_set then .type = $type else . end)
                          | (if $role_set then .role = $role else . end)
                          | (if $order_set then .order = $order else . end)
                          | (if $human_gate_set then .human_gate = $human_gate else . end)
                        else . end
                      )
                    | .design_revision += 1
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"node_edited", node_id:$id, detail:"proposed graph revised"}]
                ' --arg id "$node" --arg goal "$goal" --arg type "$node_type" --arg role "$role" \
                    --arg at "$at" --argjson dependencies "$depends_json" --argjson order "${order:-0}" \
                    --argjson human_gate "$human_gate" --argjson goal_set "$goal_set" \
                    --argjson depends_set "$depends_set" --argjson type_set "$type_set" \
                    --argjson role_set "$role_set" --argjson order_set "$order_set" \
                    --argjson human_gate_set "$human_gate_set"
                ;;
            remove-node)
                require_proposal_phase
                [ -n "$node" ] || die "--node is required"
                case "$node" in research|research-*|plan|verification|completion) die "cannot remove required node: $node" ;; esac
                jq -e --arg id "$node" 'any(.nodes[]; .id == $id)' "$state" >/dev/null \
                    || die "unknown node: $node"
                dependents="$(jq -r --arg id "$node" '[.nodes[] | select(.dependencies | index($id)) | .id] | join(",")' "$state")"
                [ -z "$dependents" ] || die "node is still required by: $dependents"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(select(.id != $id))
                    | .design_revision += 1
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"node_removed", node_id:$id, detail:"proposed graph reduced"}]
                ' --arg id "$node" --arg at "$at"
                ;;
            set-retries)
                require_proposal_phase
                validate_non_negative_integer "--max-retries" "$max_retries"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .max_retries = $max_retries
                    | .design_revision += 1
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"retries_changed", node_id:"verification", detail:("maximum retries set to " + ($max_retries | tostring))}]
                ' --arg at "$at" --argjson max_retries "$max_retries"
                ;;
            add-task)
                require_proposal_phase
                [ -n "$task_id" ] || die "--id is required"
                [ -n "$goal" ] || die "--goal is required"
                validate_design_id "$task_id"
                jq -e --arg id "$task_id" 'all(.nodes[]; .id != $id)' "$state" >/dev/null \
                    || die "node already exists: $task_id"
                [ -n "$depends" ] || depends="plan"
                depends_json="$(csv_json "$depends")"
                missing="$(jq -r --argjson dependencies "$depends_json" '[ $dependencies[] as $id | select(all(.nodes[]; .id != $id)) | $id ] | join(",")' "$state")"
                [ -z "$missing" ] || die "unknown dependencies: $missing"
                if [ "$(jq -r '[.nodes[] | select(.id == "implementation" and .status == "pending")] | length' "$state")" -gt 0 ]; then
                    echo "note: replacing the default 'implementation' node with ${task_id}" >&2
                fi
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(select(.id != "implementation" or .status != "pending"))
                    | .nodes += [{id:$id, type:"implementation", status:"pending", goal:$goal, role:"Implementer", dependencies:$dependencies, inputs:$dependencies, outputs:[], evidence:[], human_gate:false, outcome:null, attempt:0, order:40}]
                    | [.nodes[] | select(.type == "implementation") | .id] as $implementation_ids
                    | .nodes |= map(if .id == "verification" then .dependencies = $implementation_ids | .inputs = $implementation_ids else . end)
                    | .design_revision += 1
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"task_added", node_id:$id, detail:$goal}]
                ' --arg id "$task_id" --arg goal "$goal" --arg at "$at" \
                    --argjson dependencies "$depends_json"
                ;;
            start)
                [ -n "$node" ] || die "--node is required"
                start_node "$node"
                ;;
            complete)
                [ -n "$node" ] || die "--node is required"
                [ -n "$output" ] || die "--output is required"
                [ -n "$evidence" ] || die "--evidence is required"
                node_type="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .type][0] // ""' "$state")"
                [ -n "$node_type" ] || die "unknown node: $node"
                [ "$node_type" != "verification" ] \
                    || die "verification cannot be completed manually; use verify"
                validate_evidence "$evidence"
                current_status="$(jq -r --arg id "$node" '.nodes[] | select(.id == $id) | .status' "$state")"
                if [ "$current_status" = "pending" ]; then
                    # Mirror verify: a runnable-but-unstarted node is auto-started
                    # so the audit log still gets a timestamped start entry.
                    start_node "$node"
                    echo "[auto-start] ${node}" >&2
                    current_status="$(jq -r --arg id "$node" '.nodes[] | select(.id == $id) | .status' "$state")"
                fi
                [ "$current_status" = "in_progress" ] || die "node is not in progress: $node"
                if [ "$node_type" = "completion" ]; then
                    # Re-checked here, not only at approval: the state file is committed and
                    # editable, and validate_state_file asserts structure and acyclicity but
                    # not this invariant. A verification node superseded by a retry ends
                    # completed/failed on purpose (see verification_failure), so the rule is
                    # "every implementation and fix succeeded, and every verification node
                    # finished either passed (the loop terminated on a pass) or failed
                    # (superseded), with at least one pass".
                    jq -e '
                        [.nodes[] | select(.type == "implementation" or .type == "verification" or .type == "fix")] as $work
                        | ($work | map(select(.type == "implementation")) | length) > 0
                        and ($work | map(select(.type == "verification")) | length) > 0
                        and all($work[]; .status == "completed")
                        and all($work[] | select(.type == "implementation" or .type == "fix"); .outcome == "succeeded")
                        and all($work[] | select(.type == "verification"); .outcome == "passed" or .outcome == "failed")
                        and any($work[] | select(.type == "verification"); .outcome == "passed")
                    ' "$state" >/dev/null \
                        || die "completion requires every implementation and verification node to be completed and succeeded first"
                fi
                outputs_json="$(csv_json "$output")"
                evidence_json="$(csv_json "$evidence")"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(
                        if .id == $id then
                          .outputs = $outputs
                          | .evidence = $evidence
                          | .outcome = "succeeded"
                          | .status = (if .human_gate then "awaiting_human" else "completed" end)
                        else . end
                      )
                    | if .mode == "graph" and any(.nodes[]; .id == $id and .type == "plan" and .status == "completed")
                      then .status = "awaiting_approval"
                      elif any(.nodes[]; .id == $id and .type == "completion" and .status == "completed")
                      then .status = "completed"
                      else . end
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"completed", node_id:$id, detail:(if any(.nodes[]; .id == $id and .status == "awaiting_human") then "awaiting human approval" else "outputs and evidence recorded" end)}]
                ' --arg id "$node" --arg at "$at" --argjson outputs "$outputs_json" \
                    --argjson evidence "$evidence_json"
                ;;
            verify)
                [ -n "$node" ] || die "--node is required"
                [ -n "$evidence" ] || die "--evidence is required"
                node_type="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .type][0] // ""' "$state")"
                node_status="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")"
                [ "$node_type" = "verification" ] || die "node is not a verification node: $node"
                if [ "$node_status" = "pending" ]; then
                    start_node "$node"
                elif [ "$node_status" != "in_progress" ]; then
                    die "verification node is not runnable or in progress: $node"
                fi
                verify_status="$(_run_verification_into_evidence "$node" "$evidence")"
                if [ "$verify_status" -eq 0 ]; then
                    evidence_json="$(csv_json "$evidence")"
                    at="$(now_utc)"
                    update_state '
                        (.events | length + 1) as $seq
                        | .nodes |= map(if .id == $id then .status = "completed" | .outcome = "passed" | .outputs = $evidence | .evidence = $evidence else . end)
                        | .updated_at = $at
                        | .events += [{seq:$seq, at:$at, action:"verification_passed", node_id:$id, detail:"configured command exited with status 0", evidence:$evidence}]
                    ' --arg id "$node" --arg at "$at" --argjson evidence "$evidence_json"
                else
                    verification_failure "$node" "verification command exited with status $verify_status" "$evidence"
                    exit "$verify_status"
                fi
                ;;
            reverify)
                # Re-run the configured command for a verification node that
                # already passed, rewrite and re-stage the evidence under a
                # committable name, and record a `reverified` event. This is
                # NOT a fix loop: no fix/verify nodes, no state transition, the
                # node stays completed/passed.
                [ -n "$node" ] || die "--node is required"
                [ -n "$evidence" ] || die "--evidence is required"
                node_type="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .type][0] // ""' "$state")"
                [ -n "$node_type" ] || die "unknown node: $node"
                node_status="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")"
                node_outcome="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .outcome][0] // ""' "$state")"
                [ "$node_type" = "verification" ] || die "reverify only runs on a verification node: $node"
                { [ "$node_status" = "completed" ] && [ "$node_outcome" = "passed" ]; } \
                    || die "reverify only runs on a passed verification node (got status=${node_status:-missing} outcome=${node_outcome:-none})"
                verify_status="$(_run_verification_into_evidence "$node" "$evidence")"
                [ "$verify_status" -eq 0 ] \
                    || die "reverify: the command now fails (exit $verify_status) — use the fix loop, not reverify"
                evidence_json="$(csv_json "$evidence")"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(if .id == $id then .evidence = $evidence | .outputs = $evidence else . end)
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"reverified", node_id:$id, detail:"verification command re-run on a passed node", evidence:$evidence}]
                ' --arg id "$node" --arg at "$at" --argjson evidence "$evidence_json"
                ;;
            fail)
                [ -n "$node" ] || die "--node is required"
                [ -n "$reason" ] || die "--reason is required"
                [ -n "$evidence" ] || die "--evidence is required"
                validate_evidence "$evidence"
                node_type="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .type][0] // ""' "$state")"
                node_status="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")"
                [ "$node_type" = "verification" ] || die "only verification nodes can enter the fix loop"
                [ "$node_status" = "in_progress" ] || die "verification node is not in progress: $node"
                verification_failure "$node" "$reason" "$evidence"
                ;;
            block)
                [ -n "$node" ] || die "--node is required"
                [ -n "$reason" ] || die "--reason is required"
                node_status="$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")"
                case "$node_status" in pending|in_progress|awaiting_human) ;; *) die "node cannot be blocked from status '${node_status:-missing}'" ;; esac
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(if .id == $id then .status = "blocked" | .outcome = "blocked" else . end)
                    | .status = "blocked"
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"blocked", node_id:$id, detail:$reason}]
                ' --arg id "$node" --arg reason "$reason" --arg at "$at"
                ;;
            approve)
                [ -n "$node" ] || die "--node is required"
                [ -n "$evidence" ] || die "--evidence is required"
                validate_evidence "$evidence"
                [ "$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")" = "awaiting_human" ] \
                    || die "node is not awaiting human approval: $node"
                evidence_json="$(csv_json "$evidence")"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(if .id == $id then .status = "completed" | .evidence += $evidence else . end)
                    | if any(.nodes[]; .id == $id and .type == "completion" and .status == "completed") then .status = "completed" else . end
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"human_approved", node_id:$id, detail:"approval recorded", evidence:$evidence}]
                ' --arg id "$node" --arg at "$at" --argjson evidence "$evidence_json"
                ;;
            reject)
                [ -n "$node" ] || die "--node is required"
                [ -n "$reason" ] || die "--reason is required"
                [ "$(jq -r --arg id "$node" '[.nodes[] | select(.id == $id) | .status][0] // ""' "$state")" = "awaiting_human" ] \
                    || die "node is not awaiting human approval: $node"
                at="$(now_utc)"
                update_state '
                    (.events | length + 1) as $seq
                    | .nodes |= map(if .id == $id then .status = "blocked" | .outcome = "rejected" else . end)
                    | .status = "blocked"
                    | .updated_at = $at
                    | .events += [{seq:$seq, at:$at, action:"human_rejected", node_id:$id, detail:$reason}]
                ' --arg id "$node" --arg reason "$reason" --arg at "$at"
                ;;
            handoff)
                # Machine-readable termination record the supervisor reads. A
                # snapshot, not a log: each write replaces the prior one. It
                # does not mutate the authoritative workflow state.
                [ -n "$node" ] || die "--node is required"
                [ -n "$next_step" ] || die "--next is required"
                case "$claim" in
                    none|complete|needs_human) ;;
                    *) die "--claim must be none, complete, or needs_human" ;;
                esac
                jq -e --arg id "$node" 'any(.nodes[]; .id == $id)' "$state" >/dev/null \
                    || die "unknown node: $node"
                if $blocker_set && [ "$claim" = "complete" ]; then
                    die "--blocker cannot be combined with --claim complete"
                fi
                if [ "$claim" = "needs_human" ] && ! $blocker_set; then
                    die "--claim needs_human requires --blocker"
                fi
                changed_json="$(csv_json "$changed")"
                if [ "$(jq 'length' <<< "$changed_json")" -eq 0 ] \
                    && ! $blocker_set && [ "$claim" != "needs_human" ]; then
                    die "--changed must list at least one file unless --blocker or --claim needs_human is set"
                fi
                blocker_json="null"
                $blocker_set && blocker_json="$(jq -Rn --arg b "$blocker" '$b')"
                descope_state="$($descope_ledger state --state "$state")" \
                    || die "cannot write handoff while descope ledger is invalid"
                feature="$(jq -r '.feature' "$state")"
                at="$(now_utc)"
                handoff_path="$(dirname "$state")/${feature}.handoff.json"
                tmp="$(mktemp "${handoff_path}.XXXXXX")"
                jq -n \
                    --arg feature "$feature" --arg at "$at" --arg node "$node" \
                    --arg next "$next_step" --arg claim "$claim" \
                    --argjson changed "$changed_json" --argjson blocker "$blocker_json" \
                    --argjson descopes "$(jq -c '.descopes' <<< "$descope_state")" \
                    --argjson open_descope_ids "$(jq -c '.blocking_ids' <<< "$descope_state")" \
                    --slurpfile state "$state" '
                    {
                      schema_version: 1,
                      feature: $feature,
                      at: $at,
                      node: $node,
                      changed_files: $changed,
                      next_step: $next,
                      blocker: $blocker,
                      claim: $claim,
                      workflow_status: $state[0].status,
                      workflow_revision: $state[0].design_revision,
                      descopes: $descopes,
                      open_descope_ids: $open_descope_ids
                    }
                ' > "$tmp" || { rm -f "$tmp"; die "failed to render handoff"; }
                mv "$tmp" "$handoff_path"
                echo "handoff written: $handoff_path"
                ;;
        esac
        ;;

    help|-h|--help)
        usage
        ;;
    *)
        usage
        die "unknown command: $command"
        ;;
esac
