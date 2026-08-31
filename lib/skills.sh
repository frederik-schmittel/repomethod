#!/usr/bin/env bash
# lib/skills.sh — stage a canonical skill directory under
# .repomethod/skills/<name> into a per-tool skill location
# (.agents/skills/<name>, .claude/skills/<name>) as a relative symlink.
# Skills have exactly one representation: a symlink. A filesystem that
# cannot create one is a hard failure, not a silent copy fallback.
set -euo pipefail

# True (and exit 0) iff prior_manifest_json — the ownership journal as it
# stood before the current install/update run — proves repomethod itself
# put the symlink now at rel_path there: it records source "skill-link"
# with a target that still matches current_target exactly. An empty
# prior_manifest_json (no journal at all, e.g. a target with no
# manifest.json yet) is never trusted just because current_target happens
# to already look like the right thing — every real caller (install.sh,
# update.sh) has a manifest to check by the time anything could
# legitimately already be sitting at this path, so "no journal" only ever
# means "nothing repomethod wrote", not implicit permission to adopt
# whatever is already there.
skill_link_owned() {
    local prior_manifest_json="$1" rel_path="$2" current_target="$3"
    [ -n "$prior_manifest_json" ] || return 1
    local prior_source prior_target
    prior_source="$(jq -r --arg path "$rel_path" '.files[$path].source // ""' <<<"$prior_manifest_json")"
    prior_target="$(jq -r --arg path "$rel_path" '.files[$path].sha256 // ""' <<<"$prior_manifest_json")"
    [ "$prior_source" = "skill-link" ] && [ "$prior_target" = "$current_target" ]
}

stage_skill_link() {
    local target_dir="$1" skill_name="$2" link_parent_rel="$3"
    local prior_manifest_json="${4:-}"
    local canonical_rel="../../.repomethod/skills/${skill_name}"
    local link_parent_dir="${target_dir}/${link_parent_rel}"
    local link_path="${link_parent_dir}/${skill_name}"
    local rel_path="${link_parent_rel}/${skill_name}"

    # link_parent_dir (.agents/skills, .claude/skills) is itself a
    # candidate escape point: if the user (or a prior tool) replaced it, or
    # an ancestor of it, with a symlink pointing outside target_dir, mkdir
    # -p and the ln -s below would silently create the skill link there
    # instead. Checked before mkdir specifically so the directory is never
    # created outside the repo even transiently.
    require_repo_path_contained "$target_dir" "$link_parent_dir"
    mkdir -p "$link_parent_dir"

    if [ ! -e "$link_path" ] && [ ! -L "$link_path" ]; then
        ln -s "$canonical_rel" "$link_path" \
            || die "symbolic links are required for RepoMethod skill links: ${rel_path}"
        return 0
    fi

    # Appearance is never ownership: a symlink already pointing at the
    # canonical target still is not repomethod's unless skill_link_owned
    # proves it. Anything not provably owned falls through to the conflict
    # below and is never touched — including a mismatched-target symlink,
    # a file, or a directory (e.g. one left by a retired pre-0.2
    # copy-fallback install).
    if [ -L "$link_path" ]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if skill_link_owned "$prior_manifest_json" "$rel_path" "$current_target"; then
            [ "$current_target" = "$canonical_rel" ] && return 0
            rm -f -- "$link_path"
            ln -s "$canonical_rel" "$link_path" \
                || die "symbolic links are required for RepoMethod skill links: ${rel_path}"
            return 0
        fi
    fi

    die "conflict: ${rel_path} already exists and was not created by repomethod — remove it manually, or rename the conflicting skill"
}

skill_is_disabled() {
    local target_dir="$1" skill_name="$2"
    local disabled_file="${target_dir}/.repomethod/disabled-skills.txt"

    [ -f "$disabled_file" ] && grep -Fqx -- "$skill_name" "$disabled_file"
}

# Stages every skill found under <target_dir>/.repomethod/skills/ into
# both .agents/skills/ and .claude/skills/, recording each result in
# <manifest_json> (printed on stdout, pure w.r.t. its input besides the
# disk writes stage_skill_link performs). One entry per link, keyed by
# "<link_parent_rel>/<name>", with the *symlink's target string* (not a
# content hash) stored in the "sha256" field and source "skill-link" —
# update.sh/uninstall.sh must compare this against `readlink`, not
# sha256_file, since sha256sum can't hash a directory symlink.
stage_core_skills() {
    local target_dir="$1" manifest_json="$2"
    local prior_manifest_json="${3:-}"
    local skills_dir="${target_dir}/.repomethod/skills"

    [ -d "$skills_dir" ] || { printf '%s' "$manifest_json"; return 0; }

    local name link_parent_rel link_path rel_path
    for name in $(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort); do
        if skill_is_disabled "$target_dir" "$name"; then
            continue
        fi
        for link_parent_rel in ".agents/skills" ".claude/skills"; do
            stage_skill_link "$target_dir" "$name" "$link_parent_rel" "$prior_manifest_json"
            link_path="${target_dir}/${link_parent_rel}/${name}"
            rel_path="${link_parent_rel}/${name}"
            manifest_json="$(manifest_add_file "$manifest_json" "$rel_path" "$(readlink "$link_path")" "skill-link")"
        done
    done

    printf '%s' "$manifest_json"
}

# Read-only check for install.sh, run BEFORE stage_blueprint writes anything.
# stage_blueprint and stage_core_skills each detect their own conflicts
# correctly, but stage_blueprint always runs first — so a skill-link
# conflict that stage_core_skills would only discover afterward used to
# leave the blueprint's files already written to disk despite the overall
# install failing. Walking the source skill list here (not
# target_dir/.repomethod/skills, which will not exist yet on a first
# install) and refusing on the same known collisions up front means a
# doomed install fails clean, before any write. No rollback machinery is
# involved: this only ever reads.
preflight_skill_links() {
    local target_dir="$1" src_dir="$2"
    local prior_manifest_json="${3:-}"
    local skills_dir="${src_dir}/.repomethod/skills"

    [ -d "$skills_dir" ] || return 0

    local name link_parent_rel link_path rel_path current_target
    for name in $(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort); do
        skill_is_disabled "$target_dir" "$name" && continue
        for link_parent_rel in ".agents/skills" ".claude/skills"; do
            link_path="${target_dir}/${link_parent_rel}/${name}"
            rel_path="${link_parent_rel}/${name}"

            if [ -L "$link_path" ]; then
                current_target="$(readlink "$link_path")"
                skill_link_owned "$prior_manifest_json" "$rel_path" "$current_target" && continue
            fi

            if [ -e "$link_path" ] || [ -L "$link_path" ]; then
                die "conflict: ${rel_path} already exists and was not created by repomethod — remove it manually, or rename the conflicting skill"
            fi
        done
    done
}
