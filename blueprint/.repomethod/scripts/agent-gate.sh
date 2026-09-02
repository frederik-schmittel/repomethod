#!/usr/bin/env bash
# agent-gate.sh --spec <required> [--base <b>] [--state <f>] [--report <r>]
# agent-gate.sh --quick [--base <b>] [--report <r>]
#
# Full gate (classic/graph): runs verify, verify-scope, verify-forbidden,
# plan-obligations, verify-contracts, verify-acceptance, verify-evidence, verify-report, and
# verify-invariants in order and trusts only their exit status. Every argument
# comes from a flag — nothing is read from the environment. --spec has no
# default and fails closed if omitted.
#
# Quick gate (quick-mvp close-out): runs verify, checks that no protected
# zone was touched, and checks that the evidence report exists and is not
# empty. No spec document, no acceptance/evidence-vs-spec aggregate.
set -euo pipefail

SPEC=""
BASE=""
STATE=""
REPORT=".repomethod/evidence/report.md"
QUICK=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) QUICK=true; shift ;;
        --spec) SPEC="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --state) STATE="$2"; shift 2 ;;
        --report) REPORT="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

# --state carries the workflow's pinned config.base_ref (read by verify-scope).
# It only makes sense for the full, spec-driven gate.
if [ "$QUICK" = true ] && [ -n "$STATE" ]; then
    echo "--state is only valid with --spec" >&2
    exit 1
fi

# --spec has no default and fails closed if omitted. Checked before the preflight
# so a missing spec is still the first thing reported.
if [ "$QUICK" != true ] && [ -z "$SPEC" ]; then
    echo "error: --spec is required" >&2
    exit 1
fi

# Environment preflight: after argument validation, before any base resolution
# or verify.sh, for both the quick and the spec gate. A hard finding aborts here
# with preflight's own exit status.
"${here}/preflight.sh" --quiet || exit $?

if [ "$QUICK" = true ]; then
    [ -n "$BASE" ] || BASE="$(resolve_base .)"
    "${here}/verify.sh" .
    "${here}/verify-scope.sh" --quick --base "$BASE" --repo .
    if [ ! -s "$REPORT" ]; then
        echo "error: --quick needs a non-empty evidence report at ${REPORT} (a short free-text note of what was built and how it was verified)" >&2
        exit 1
    fi
    echo "[agent-gate] quick gate passed (verify + protected zones + evidence note)"
    exit 0
fi

# Base authority is verify-scope's. An explicit --base wins and keeps its
# diagnostics; otherwise forward --state so verify-scope reads config.base_ref;
# with neither, verify-scope falls back to its own resolve_base.
scope_base_args=()
if [ -n "$BASE" ]; then
    scope_base_args=(--base "$BASE")
elif [ -n "$STATE" ]; then
    scope_base_args=(--state "$STATE")
fi

# Plan-obligations mode binding: when a workflow state is supplied, pin the
# obligations check to that state's delivery mode so an artifact recorded for
# the other mode is rejected. Legacy/minimal states without a mode stay
# mode-neutral (the check then accepts either classic or graph).
obligation_mode_args=()
if [ -n "$STATE" ]; then
    [ -f "$STATE" ] || { echo "error: workflow state not found: $STATE" >&2; exit 1; }
    workflow_mode="$(jq -r '.mode? // empty' "$STATE" 2>/dev/null)" \
        || { echo "error: cannot read workflow mode from state: $STATE" >&2; exit 1; }
    case "$workflow_mode" in
        classic|graph) obligation_mode_args=(--mode "$workflow_mode") ;;
        '') ;;
        *) echo "error: workflow state has unsupported mode: $workflow_mode" >&2; exit 1 ;;
    esac
fi

"${here}/verify.sh" --warn-frontend-uncovered .
"${here}/verify-scope.sh" --spec "$SPEC" "${scope_base_args[@]}" --repo .
"${here}/verify-forbidden.sh" --spec "$SPEC" --repo .
"${here}/plan-obligations.sh" check "${obligation_mode_args[@]}" --spec "$SPEC" --repo .
"${here}/verify-contracts.sh" --spec "$SPEC"
"${here}/verify-acceptance.sh" --spec "$SPEC" --report "$REPORT"
"${here}/verify-evidence.sh" --spec "$SPEC"
"${here}/verify-report.sh" --spec "$SPEC" --report "$REPORT"
"${here}/verify-invariants.sh" --spec "$SPEC"

echo "[agent-gate] all gates passed"
