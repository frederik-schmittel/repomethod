#!/usr/bin/env bash
# supervisor.sh — a thin, deterministic driver around a Classic/Graph workflow.
# It runs no model and makes no judgement: it reads the workflow state, the
# agent's handoff, and the gate result, then emits a verdict.
#
#   supervisor.sh check --state <file> [--base <ref>] [--max-idle-runs <K>]
#     Runs the workflow's verification command once, compares a progress
#     fingerprint against its own sidecar, and prints a verdict JSON:
#       done             gate green, workflow completed, completion node
#                        succeeded, scope clean, handoff reports no open blocker
#       continue         more work to do (next_dispatch names the runnable nodes)
#       blocked          no progress for K consecutive checks
#       needs_human      the handoff explicitly claims needs_human
#       evidence-ignored a required plan artifact (spec, state, handoff, or a
#                        completed verification node's evidence) is covered by a
#                        .gitignore rule and would be absent from a fresh clone
#     Exit code: 0 done, 10 continue, 2 blocked, 3 needs_human,
#                4 evidence-ignored, 1 error.
#     check never mutates the authoritative workflow state; it writes only
#     <feature>.supervisor.json next to the state file.
#
#   supervisor.sh run --state <file> [--agent-command "<cmd>"] [--base <ref>]
#                     [--max-idle-runs <K>] [--max-runs <N>]
#     Without --agent-command: one check, printed. With it: loop
#     check -> on `continue`, render <feature>.dispatch.md and run the command
#     (env RM_STATE, RM_SPEC, RM_HANDOFF, RM_GATE_LOG, RM_DISPATCH) -> repeat.
#     On `blocked` it calls `workflow-graph.sh block` so the state reflects it.
#     Exit code mirrors the terminal verdict.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "supervisor: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'
    fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

resolve_base() {
    local dir="${1:-.}" mb ref up cur
    up="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    # <remote>/<same-branch> is this branch's own pushed copy, not a fork
    # point — skip it and fall through to origin/HEAD, then main.
    if [ -n "$up" ] && [ "${up#*/}" != "$cur" ]; then
        if mb="$(git -C "$dir" merge-base HEAD "$up" 2>/dev/null)" && [ -n "$mb" ]; then
            printf '%s\n' "$mb"
            return 0
        fi
    fi
    if ref="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$ref" ]; then
        if mb="$(git -C "$dir" merge-base HEAD "$ref" 2>/dev/null)" && [ -n "$mb" ]; then
            printf '%s\n' "$mb"
            return 0
        fi
    fi
    if git -C "$dir" rev-parse --verify --quiet 'main^{commit}' >/dev/null 2>&1; then
        printf '%s\n' "main"
        return 0
    fi
    echo "error: cannot resolve a base ref — pass --base <ref>" >&2
    exit 1
}

# Finding 5 / KORREKTUR 2: the state file is a committed, editable artifact and
# four write paths below are derived from its directory (.handoff.json,
# .supervisor.json, .dispatch.md, and the
# .repomethod/evidence/supervisor-<feature>-<ts>.log gate log). Refuse the state
# if the state file itself, or any path segment up to its repository root, is a
# symlink. Runs BEFORE the `cd ... && pwd` below, which resolves symlinks away.
# ponytail: ceiling is the repo root located by a lexical `.git` search; outside
# a git repo only the state file and its own directory are checked.
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

# ---------------------------------------------------------------------------

subcommand="${1:-}"
[ -n "$subcommand" ] || die "usage: supervisor.sh <check|run> --state <file> [options]"
shift

state=""
base=""
max_idle_runs=2
max_runs=10
agent_command=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --state) state="${2:-}"; shift 2 ;;
        --base) base="${2:-}"; shift 2 ;;
        --max-idle-runs) max_idle_runs="${2:-}"; shift 2 ;;
        --max-runs) max_runs="${2:-}"; shift 2 ;;
        --agent-command) agent_command="${2:-}"; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$state" ] || die "--state is required"
[ -f "$state" ] || die "state not found: $state"
case "$max_idle_runs" in ''|*[!0-9]*) die "--max-idle-runs must be a non-negative integer" ;; esac
case "$max_runs" in ''|*[!0-9]*) die "--max-runs must be a non-negative integer" ;; esac

refuse_symlinked_state "$state"

state_dir="$(cd "$(dirname "$state")" && pwd)"
state="${state_dir}/$(basename "$state")"

feature="$(jq -r '.feature' "$state")"
# Same reason as refuse_symlinked_state: .feature comes out of a committed,
# editable state file and the write paths below are built from it. workflow-
# graph.sh spells the regex out too — a standalone blueprint script cannot
# source it.
[[ "$feature" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "invalid feature slug in state file ${state}: '${feature}'"
verification_command="$(jq -r '.config.verification_command' "$state")"

# The state file may have been written on a different machine; the recorded
# repo_root is a hint, not an address. Derive the real root from where the
# state file actually lives and fall back to the record only if this is not a
# git checkout.
repo_root="$(git -C "$state_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || repo_root="$(jq -r '.repo_root' "$state")"
[ -d "$repo_root" ] || die "cannot locate the repository for ${state} (recorded repo_root: $(jq -r '.repo_root' "$state"))"

# Base priority mirrors the state consumers: explicit --base; else the pinned
# config.base_ref; else resolve_base. A present-but-invalid state value fails
# hard with the same message, never a silent fallback.
explicit_base=false
[ -n "$base" ] && explicit_base=true
if [ "$explicit_base" = false ]; then
    state_base="$(jq -r '.config.base_ref? // empty' "$state")"
    if [ -n "$state_base" ]; then
        case "$state_base" in
            *[!0-9a-f]*|'') die "invalid config.base_ref in state: $state_base" ;;
        esac
        { [ "${#state_base}" -eq 40 ] \
            && git -C "$repo_root" rev-parse --verify --quiet "${state_base}^{commit}" >/dev/null; } \
            || die "invalid config.base_ref in state: $state_base"
        base="$state_base"
    fi
fi
[ -n "$base" ] || base="$(resolve_base "$repo_root")"

handoff_path="${state_dir}/${feature}.handoff.json"
sidecar_path="${state_dir}/${feature}.supervisor.json"
dispatch_path="${state_dir}/${feature}.dispatch.md"
spec_rel="specs/${feature}.md"

# --- progress fingerprint -------------------------------------------------

fingerprint() {
    local evidence_dir="${repo_root}/.repomethod/evidence" ev_names="" ev_hash="none" hf_hash="none"
    local state_proj git_head git_porcelain obl_hash="none" descopes_hash="none"
    state_proj="$(jq -S '{design_revision, retry_count, status, events:(.events|length),
        conformance_retry_count:(.conformance_retry_count // 0),
        nodes:[.nodes[]|{id,status,outcome,attempt}]}' "$state")"
    # Review authorities live under .repomethod/workflows/ (filtered out of
    # git_porcelain because the runner rewrites that dir every check) but change
    # only on real extraction/approval or a descope decision. Fold their content
    # in so a plan-obligation approval or descope review registers as progress.
    if [ -f "${repo_root}/.repomethod/workflows/${feature}.plan-obligations.json" ]; then
        obl_hash="$(sha256 < "${repo_root}/.repomethod/workflows/${feature}.plan-obligations.json")"
    fi
    descopes_hash="$("${here}/descope-ledger.sh" state --state "$state" 2>/dev/null \
        | jq -S . 2>/dev/null | sha256 2>/dev/null || echo none)"
    git_head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo none)"
    # Drop RepoMethod's own runtime dirs: the supervisor and workflow runner
    # write there every check, and that is not agent progress.
    git_porcelain="$(git -C "$repo_root" status --porcelain=v1 2>/dev/null \
        | grep -vE ' \.repomethod/(workflows|evidence)/' | LC_ALL=C sort || true)"
    if [ -d "$evidence_dir" ]; then
        # Exclude the supervisor's own per-check gate logs — they are written
        # on every check and would otherwise register as "progress" forever.
        ev_names="$(cd "$evidence_dir" && find . -type f ! -name 'supervisor-*' | LC_ALL=C sort)"
        ev_hash="$(cd "$evidence_dir" && find . -type f ! -name 'supervisor-*' -print0 \
            | LC_ALL=C sort -z | xargs -0 cat 2>/dev/null | sha256)"
    fi
    [ -f "$handoff_path" ] && hf_hash="$(sha256 < "$handoff_path")"
    printf '%s\n--\n%s\n--\n%s\n--\n%s\n--\n%s\n--\n%s\n--\n%s\n--\n%s\n' \
        "$state_proj" "$git_head" "$git_porcelain" "$ev_names" "$ev_hash" "$hf_hash" \
        "$obl_hash" "$descopes_hash" | sha256
}

# --- one check ----------------------------------------------------------------

do_check() {
    local ts gate_log gate_exit
    ts="$(now_utc | tr ':' '-')"
    mkdir -p "${repo_root}/.repomethod/evidence"
    gate_log=".repomethod/evidence/supervisor-${feature}-${ts}.log"
    {
        printf 'command=%s\n' "$verification_command"
        printf 'started_at=%s\n' "$(now_utc)"
    } > "${repo_root}/${gate_log}"
    set +e
    ( cd "$repo_root" && bash -c "$verification_command" ) >> "${repo_root}/${gate_log}" 2>&1
    gate_exit=$?
    set -e
    printf 'exit_code=%s\n' "$gate_exit" >> "${repo_root}/${gate_log}"

    local wf_status completion_ok scope_ok handoff_state blocker claim
    wf_status="$(jq -r '.status' "$state")"
    completion_ok="$(jq -r '[.nodes[] | select(.type == "completion")] | .[0]
        | (.status == "completed" and .outcome == "succeeded") // false' "$state")"

    # Without an explicit --base, forward --state so verify-scope reads the
    # pinned config.base_ref (and stays silent on stale/ancestor diagnostics).
    # With one, forward --base. The quick fallback cannot take --state, so it
    # always uses the concrete resolved base.
    local -a full_base_args
    if [ "$explicit_base" = true ]; then
        full_base_args=(--base "$base")
    else
        full_base_args=(--state "$state")
    fi
    scope_ok=false
    if [ -f "${repo_root}/${spec_rel}" ]; then
        if ( cd "$repo_root" && "${here}/verify-scope.sh" --spec "$spec_rel" "${full_base_args[@]}" --repo . ) >/dev/null 2>&1; then
            scope_ok=true
        fi
    else
        if ( cd "$repo_root" && "${here}/verify-scope.sh" --quick --base "$base" --repo . ) >/dev/null 2>&1; then
            scope_ok=true
        fi
    fi

    # plan-artifact persistence: a completed workflow is only a durable
    # handoff for a fresh agent if the spec, the workflow state, the handoff,
    # and the evidence are committed. The supervisor's own per-check output
    # does not count: the gate logs (evidence/supervisor-*), the sidecar
    # (<feature>.supervisor.json), and the dispatch render (<feature>.dispatch.md)
    # are all rewritten every check and are git-ignored by the shipped
    # gitignore.template — excluded here too so an install without that
    # template still gets a stable verdict on a second consecutive check.
    local plan_dirty plan_persisted=true plan_dirty_paths=""
    plan_dirty="$(git -C "$repo_root" status --porcelain=v1 2>/dev/null \
        | grep -E ' (specs/|\.repomethod/workflows/|\.repomethod/evidence/)' \
        | grep -vF '.repomethod/evidence/supervisor-' \
        | grep -vF "${feature}.supervisor.json" \
        | grep -vF "${feature}.dispatch.md" || true)"
    if [ -n "$plan_dirty" ]; then
        plan_persisted=false
        plan_dirty_paths="$(printf '%s\n' "$plan_dirty" | sed 's/^...//' | paste -sd', ' -)"
    fi

    # A gitignored plan artifact is a harder failure than a merely-uncommitted
    # one: no `git add` will ever stage it, so a fresh clone silently lacks it
    # and the gate would then fail there. Probe each REQUIRED artifact path (the
    # spec, the workflow state, the handoff, and every evidence file a completed
    # verification node references) against the ignore rules.
    local artifact art_rel evidence_ignored=""
    while IFS= read -r artifact; do
        [ -n "$artifact" ] || continue
        art_rel="${artifact#"$repo_root"/}"
        if git -C "$repo_root" check-ignore -q -- "$art_rel" 2>/dev/null; then
            evidence_ignored="$art_rel"
            break
        fi
    done < <(
        printf '%s\n' "$spec_rel" "${state#"$repo_root"/}" "${handoff_path#"$repo_root"/}"
        jq -r '.nodes[] | select(.type == "verification" and .status == "completed" and .outcome == "passed") | .evidence[]?' "$state"
    )

    handoff_state="missing"
    blocker="null"
    claim="none"
    if [ -f "$handoff_path" ]; then
        local hf_at state_at
        hf_at="$(jq -r '.at // ""' "$handoff_path")"
        state_at="$(jq -r '.updated_at // ""' "$state")"
        if [ -n "$hf_at" ] && [ -n "$state_at" ] && [ "$hf_at" \< "$state_at" ]; then
            handoff_state="stale"
        else
            handoff_state="ok"
        fi
        blocker="$(jq -c '.blocker' "$handoff_path")"
        claim="$(jq -r '.claim // "none"' "$handoff_path")"
    fi
    local blocker_open=false
    [ "$handoff_state" != "missing" ] && [ "$blocker" != "null" ] && blocker_open=true

    # progress vs. the previous check
    local fp last_fp idle checks progress
    fp="$(fingerprint)"
    if [ -f "$sidecar_path" ]; then
        last_fp="$(jq -r '.last_fingerprint // ""' "$sidecar_path")"
        idle="$(jq -r '.idle_runs // 0' "$sidecar_path")"
        checks="$(jq -r '.checks // 0' "$sidecar_path")"
    else
        last_fp=""; idle=0; checks=0
    fi
    if [ -z "$last_fp" ] || [ "$fp" != "$last_fp" ]; then
        progress=true; idle=0
    else
        progress=false; idle=$((idle + 1))
    fi

    # verdict
    local verdict reason
    if [ -n "$evidence_ignored" ]; then
        verdict="evidence-ignored"
        reason="EVIDENCE-IGNORED: ${evidence_ignored} is covered by a .gitignore rule — rename it or add a negation"
    elif [ "$claim" = "needs_human" ]; then
        verdict="needs_human"
        reason="handoff claims needs_human: $(jq -r '.blocker // "no reason given"' "$handoff_path")"
    elif [ "$gate_exit" -eq 0 ] && [ "$wf_status" = "completed" ] \
        && [ "$completion_ok" = "true" ] && [ "$scope_ok" = "true" ] \
        && [ "$blocker_open" = false ] && [ "$handoff_state" = "ok" ] \
        && [ "$plan_persisted" = true ]; then
        verdict="done"
        reason="gate green, workflow completed, completion node succeeded, scope clean, fresh handoff, plan artifacts committed, no open blocker"
    elif [ "$progress" = false ] && [ "$idle" -ge "$max_idle_runs" ]; then
        verdict="blocked"
        reason="no progress for ${idle} consecutive checks (limit ${max_idle_runs})"
    else
        verdict="continue"
        if [ "$blocker_open" = true ]; then
            reason="open blocker in handoff: $(jq -r '.blocker' "$handoff_path")"
        elif [ "$gate_exit" -ne 0 ]; then
            reason="gate exited ${gate_exit}; see ${gate_log}"
        elif [ "$wf_status" = "completed" ] && [ "$handoff_state" != "ok" ]; then
            reason="workflow looks complete but the handoff is ${handoff_state}"
        elif [ "$wf_status" = "completed" ] && [ "$plan_persisted" = false ]; then
            reason="workflow complete but plan artifacts are uncommitted (commit spec, .repomethod/workflows, .repomethod/evidence): ${plan_dirty_paths}"
        else
            reason="workflow not yet completed"
        fi
    fi

    local runnable_json='[]' next_dispatch='null'
    if [ "$verdict" = "continue" ]; then
        runnable_json="$( "${here}/workflow-graph.sh" next --state "$state" 2>/dev/null \
            | jq -R . | jq -s 'map(select(length > 0))' )"
        next_dispatch="$(jq -n \
            --arg state "$state" --arg spec "$spec_rel" \
            --arg handoff "$( [ -f "$handoff_path" ] && echo "$handoff_path" || echo "" )" \
            --arg gate_log "$gate_log" --argjson runnable "$runnable_json" '
            {state:$state, spec:$spec,
             handoff:(if $handoff == "" then null else $handoff end),
             gate_log:$gate_log, runnable:$runnable}')"
    fi

    # persist the supervisor sidecar (never the workflow state)
    local tmp
    tmp="$(mktemp "${sidecar_path}.XXXXXX")"
    jq -n --arg feature "$feature" --arg fp "$fp" --arg verdict "$verdict" \
        --arg at "$(now_utc)" --argjson idle "$idle" --argjson checks "$((checks + 1))" \
        --arg gate_log "$gate_log" '
        {schema_version:1, feature:$feature, last_fingerprint:$fp, idle_runs:$idle,
         checks:$checks, last_verdict:$verdict, last_check_at:$at, gate_log:$gate_log}' > "$tmp"
    mv "$tmp" "$sidecar_path"

    jq -n \
        --arg verdict "$verdict" --arg reason "$reason" \
        --argjson progress "$progress" --argjson idle "$idle" \
        --argjson max_idle "$max_idle_runs" --argjson gate_exit "$gate_exit" \
        --arg gate_log "$gate_log" --arg wf_status "$wf_status" \
        --argjson completion_ok "$completion_ok" --argjson scope_ok "$scope_ok" \
        --arg handoff "$handoff_state" --argjson blocker "$blocker" \
        --argjson plan_persisted "$plan_persisted" \
        --argjson next_dispatch "$next_dispatch" '
        {verdict:$verdict, reason:$reason, progress:$progress, idle_runs:$idle,
         max_idle_runs:$max_idle, gate_exit:$gate_exit, gate_log:$gate_log,
         workflow_status:$wf_status, completion_ok:$completion_ok, scope_ok:$scope_ok,
         handoff:$handoff, blocker:$blocker, plan_persisted:$plan_persisted,
         next_dispatch:$next_dispatch}'

    case "$verdict" in
        done) return 0 ;;
        continue) return 10 ;;
        blocked) return 2 ;;
        needs_human) return 3 ;;
        evidence-ignored) return 4 ;;
    esac
}

render_dispatch() {
    local verdict_json="$1" gate_log reason runnable
    gate_log="$(jq -r '.gate_log' <<< "$verdict_json")"
    reason="$(jq -r '.reason' <<< "$verdict_json")"
    runnable="$(jq -r '.next_dispatch.runnable | join(", ")' <<< "$verdict_json")"
    {
        printf '# Dispatch: %s\n\n' "$feature"
        printf 'Generated %s by supervisor.sh — hand this to a fresh agent.\n\n' "$(now_utc)"
        printf -- '- State: %s\n' "$state"
        printf -- '- Spec: %s\n' "$spec_rel"
        printf -- '- Gate log: %s\n' "$gate_log"
        printf -- '- Reason: %s\n' "$reason"
        printf -- '- Runnable nodes: %s\n\n' "$runnable"
        if [ -f "$handoff_path" ]; then
            printf '## Previous handoff\n\n'
            printf '%s\n\n' '```json'
            cat "$handoff_path"
            printf '\n%s\n\n' '```'
        fi
        printf 'Resume from the runnable node(s). Before you stop, write a handoff with\n'
        printf 'workflow-graph.sh handoff (node, next step, changed files, blocker or claim).\n'
    } > "$dispatch_path"
}

# --- dispatch ---------------------------------------------------------------

case "$subcommand" in
    check|run)
        if [ "$subcommand" = check ] || [ -z "$agent_command" ]; then
            set +e
            out="$(do_check)"
            rc=$?
            set -e
            printf '%s\n' "$out"
            exit "$rc"
        fi
        run_count=0
        while :; do
            set +e
            out="$(do_check)"; rc=$?
            set -e
            printf '%s\n' "$out"
            verdict="$(printf '%s' "$out" | jq -r '.verdict')"
            case "$verdict" in
                done) exit 0 ;;
                needs_human) exit 3 ;;
                evidence-ignored) exit 4 ;;
                blocked)
                    node="$(printf '%s' "$out" | jq -r '.next_dispatch.runnable[0] // "completion"')"
                    "${here}/workflow-graph.sh" block --state "$state" --node "$node" \
                        --reason "supervisor: $(printf '%s' "$out" | jq -r '.reason')" || true
                    exit 2
                    ;;
                continue)
                    run_count=$((run_count + 1))
                    if [ "$run_count" -gt "$max_runs" ]; then
                        echo "supervisor: reached --max-runs ${max_runs} without a terminal verdict" >&2
                        exit 1
                    fi
                    render_dispatch "$out"
                    agent_rc=0
                    RM_STATE="$state" RM_SPEC="${repo_root}/${spec_rel}" \
                        RM_HANDOFF="$handoff_path" \
                        RM_GATE_LOG="${repo_root}/$(printf '%s' "$out" | jq -r '.gate_log')" \
                        RM_DISPATCH="$dispatch_path" \
                        bash -c "$agent_command" || agent_rc=$?
                    [ "$agent_rc" -eq 0 ] || echo "supervisor: agent command exited ${agent_rc}" >&2
                    ;;
            esac
        done
        ;;
    *)
        die "unknown subcommand: ${subcommand} (expected check or run)"
        ;;
esac
