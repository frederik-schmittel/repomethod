#!/usr/bin/env bash
# scripts/release.sh — cut a new repomethod release: bump VERSION and npm
# package metadata, run the project's verification gate, commit, and tag. Does
# NOT publish the package or push the tag — those are separate, deliberate
# steps (see the final message it prints).
#
# Usage: scripts/release.sh X.Y.Z
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=../lib/common.sh disable=SC1091
source "${REPO_ROOT}/lib/common.sh"

require_cmd git
require_cmd bats
require_cmd shellcheck
require_cmd node
require_cmd npm

new_version="${1:-}"

if [ -z "$new_version" ]; then
    die "usage: scripts/release.sh X.Y.Z"
fi

if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "'${new_version}' is not a valid semver (expected X.Y.Z, e.g. 0.2.0)"
fi

cd "$REPO_ROOT"

if [ -n "$(git status --porcelain)" ]; then
    die "working tree is dirty — commit or stash your changes before releasing"
fi

log_info "running verification gate: bats"
# Intentionally the exact invocation this project already treats as its
# correctness gate — not reinvented for this script. tests/release_script.bats
# is itself part of this suite and exercises this script end-to-end against a
# throwaway clone; export a marker so that nested invocation skips re-running
# those clone-based tests instead of recursing into another full gate run
# inside the clone.
export REPOMETHOD_RELEASE_SELFTEST_NESTED=1
if ! bats tests/*.bats; then
    die "bats suite failed — aborting release"
fi

log_info "running verification gate: shellcheck"
if ! shellcheck lib/*.sh install.sh update.sh uninstall.sh scripts/*.sh blueprint/.repomethod/scripts/*.sh blueprint/.repomethod/skills/*/scripts/*.sh; then
    die "shellcheck failed — aborting release"
fi

log_info "running verification gate: npm package"
register_cleanup_trap
npm_cache="$(make_temp_dir)"
if ! npm_config_cache="$npm_cache" npm pack --dry-run --json >/dev/null; then
    die "npm package check failed — aborting release"
fi

log_info "writing release version: ${new_version}"
npm version "$new_version" --no-git-tag-version --allow-same-version --ignore-scripts >/dev/null
printf '%s\n' "$new_version" > "${REPO_ROOT}/VERSION"

git add VERSION package.json package-lock.json
if git diff --cached --quiet; then
    log_info "release metadata already matches ${new_version}; tagging the current commit"
else
    git commit -q -m "chore: release v${new_version}"
fi

tag="v${new_version}"
git tag -a "$tag" -m "$tag"

log_info "release v${new_version} tagged locally as ${tag}."
log_info "publish the npm package deliberately after checking the tag:"
log_info "    npm publish"
log_info "this script does NOT push the tag — pushing is a separate, deliberate step:"
log_info "    git push origin ${tag}"
