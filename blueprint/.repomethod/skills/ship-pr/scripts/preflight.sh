#!/usr/bin/env bash
# preflight.sh <repo-root> <base-ref> [--quick] — read-only check that a task
# is actually ready to ship. Never opens a PR itself.
#
# Full mode: a real task spec is present (not just the template), and the
# acceptance/evidence gate scripts exist.
# Quick mode (--quick, for a quick-mvp PR): no spec required; instead the
# evidence report must be a non-empty free-text note and no protected zone
# may have been touched.
set -euo pipefail

repo_root="${1:?usage: preflight.sh <repo-root> <base-ref> [--quick]}"
base_ref="${2:?usage: preflight.sh <repo-root> <base-ref> [--quick]}"
quick=false
[ "${3:-}" = "--quick" ] && quick=true

if [ ! -f "${repo_root}/.repomethod/scripts/verify-acceptance.sh" ] || [ ! -f "${repo_root}/.repomethod/scripts/verify-evidence.sh" ]; then
    echo "NOT READY: missing .repomethod/scripts/verify-acceptance.sh or .repomethod/scripts/verify-evidence.sh"
    exit 1
fi

if [ "$quick" = true ]; then
    if [ ! -s "${repo_root}/.repomethod/evidence/report.md" ]; then
        echo "NOT READY: quick-mvp needs a non-empty .repomethod/evidence/report.md"
        exit 1
    fi
    if ! "${repo_root}/.repomethod/scripts/verify-scope.sh" --quick --base "$base_ref" --repo "$repo_root" >/dev/null 2>&1; then
        echo "NOT READY: quick-mvp PR touches a protected zone — use classic or graph with a spec"
        exit 1
    fi
    echo "READY"
    exit 0
fi

: "$base_ref" # reserved for a future check against changed files; unused in full mode today

if [ ! -d "${repo_root}/specs" ]; then
    echo "NOT READY: no specs/ directory found"
    exit 1
fi

real_spec_found=false
for spec in "${repo_root}"/specs/*.md; do
    [ -e "$spec" ] || continue
    [ "$(basename "$spec")" = "TEMPLATE.md" ] && continue
    real_spec_found=true
    break
done

if [ "$real_spec_found" = false ]; then
    echo "NOT READY: no task spec found beyond specs/TEMPLATE.md"
    exit 1
fi

echo "READY"
exit 0
