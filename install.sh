#!/usr/bin/env bash
# install.sh — install the repomethod blueprint into a target git repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${HERE}/lib/common.sh"
# shellcheck source=lib/target.sh disable=SC1091
source "${HERE}/lib/target.sh"
# shellcheck source=lib/manifest.sh disable=SC1091
source "${HERE}/lib/manifest.sh"
# shellcheck source=lib/args.sh disable=SC1091
source "${HERE}/lib/args.sh"
# shellcheck source=lib/blueprint.sh disable=SC1091
source "${HERE}/lib/blueprint.sh"
# shellcheck source=lib/skills.sh disable=SC1091
source "${HERE}/lib/skills.sh"
# shellcheck source=lib/pointer.sh disable=SC1091
source "${HERE}/lib/pointer.sh"

require_cmd git
require_cmd jq
require_cmd find
require_cmd diff

register_cleanup_trap
parse_install_args "$@"

target_abs="$(validate_target "$ARG_TARGET")"

version="$(cat "${HERE}/VERSION")"

mode="strict"
[ "$ARG_PRESERVE" = "true" ] && mode="preserve"
[ "$ARG_BACKUP" = "true" ] && mode="backup"
[ "$ARG_FORCE" = "true" ] && mode="force"

if [ "$ARG_DRY_RUN" = "true" ]; then
    src_dir="$(blueprint_source_dir)"
    log_info "dry run: would stage the following files into ${target_abs} (mode: ${mode})"
    blueprint_list_files "$src_dir"
    exit 0
fi

manifest_path="${target_abs}/.repomethod/manifest.json"
require_repo_path_contained "$target_abs" "$manifest_path"

# The ownership journal from before this run, read now — before
# stage_blueprint overwrites manifest.json — so the preflight check and
# skill-link staging below can prove which existing skill links (if any)
# repomethod itself created, instead of trusting what a pre-existing
# symlink merely looks like. Empty on a genuinely first-ever install.
prior_manifest=""
if [ -f "$manifest_path" ]; then
    prior_manifest="$(manifest_read "$manifest_path")"
    if ! jq -e '.profiles == ["core"]' <<<"$prior_manifest" >/dev/null; then
        die "this installation contains legacy external profiles, which are no
longer supported. Run this repository's uninstall.sh, then install the
current core release."
    fi
fi

preflight_pointer_block "$target_abs" "AGENTS.md" \
    '<!-- repomethod:begin -->' '<!-- repomethod:end -->' "$prior_manifest"
preflight_pointer_block "$target_abs" "CLAUDE.md" \
    '<!-- repomethod:begin -->' '<!-- repomethod:end -->' "$prior_manifest"

preflight_skill_links "$target_abs" "$(blueprint_source_dir)" "$prior_manifest"

stage_blueprint "$target_abs" "$mode" "$version" "core" "$prior_manifest"

require_repo_path_contained "$target_abs" "$manifest_path"
manifest="$(manifest_read "$manifest_path")"
manifest="$(stage_core_skills "$target_abs" "$manifest" "$prior_manifest")"
require_repo_path_contained "$target_abs" "$manifest_path"
manifest_write "$manifest" "$manifest_path"

log_info "installed repomethod ${version} into ${target_abs}"
