#!/usr/bin/env bash
# Add, list, remove, and re-enable repository-local agent skills.
# shellcheck disable=SC2016 # jq programs are intentionally single-quoted.
set -euo pipefail

die() {
    echo "manage-skills: $*" >&2
    exit 1
}

# Refuses if any path component of <rel> (walked from repo_root, e.g.
# ".agents/skills") is itself a symlink. This script only ever writes under
# a small, fixed set of relative paths (.agents/skills, .claude/skills,
# .repomethod/skills, .repomethod) — never anything shipped by the
# blueprint or derived from untrusted input — so a plain per-component -L
# check is proportionate here: it doesn't need the device/inode identity
# machinery lib/common.sh uses for the installer's own arbitrary blueprint
# file paths, just "is any of these fixed names currently a symlink". A
# symlinked component would otherwise let mkdir -p / the manifest read-write
# below silently operate outside the repository.
assert_no_symlink_parent() {
    local rel="$1"
    local current="$repo_root"
    local part
    local -a parts

    IFS='/' read -ra parts <<<"$rel"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        current="${current}/${part}"
        # `[ -L ... ] && die` would evaluate to a non-zero status on the
        # ordinary, safe case (no symlink found) — as the last command of a
        # loop iteration, set -e would treat that as this function failing
        # and abort the whole script even though nothing is wrong.
        if [ -L "$current" ]; then
            die "refusing to operate through symlinked managed directory: ${current#"${repo_root}"/}"
        fi
    done
}

usage() {
    cat <<'EOF'
usage:
  .repomethod/scripts/manage-skills.sh list
  .repomethod/scripts/manage-skills.sh add --source <skill-directory>
  .repomethod/scripts/manage-skills.sh remove --name <name>
  .repomethod/scripts/manage-skills.sh enable --name <name>
EOF
}

validate_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || die "invalid skill name '$1' (use lowercase letters, digits, dot, underscore, or hyphen)"
}

read_declared_name() {
    awk '
        NR == 1 && $0 == "---" { in_frontmatter = 1; next }
        in_frontmatter && $0 == "---" { exit }
        in_frontmatter && /^[[:space:]]*name:[[:space:]]*/ {
            sub(/^[[:space:]]*name:[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$1"
}

manifest_update() {
    local filter="$1"
    shift
    local tmp
    tmp="$(mktemp "${manifest_path}.tmp.XXXXXX")"
    if jq "$@" "$filter" "$manifest_path" > "$tmp"; then
        mv "$tmp" "$manifest_path"
    else
        rm -f -- "$tmp"
        die "could not update manifest"
    fi
}

manifest_remove_links() {
    local skill_name="$1"
    manifest_update '
        .files |= with_entries(
            select(
                (.key == (".agents/skills/" + $name)
                 or .key == (".claude/skills/" + $name)
                 or (.key | startswith(".agents/skills/" + $name + "/"))
                 or (.key | startswith(".claude/skills/" + $name + "/")))
                | not
            )
        )
    ' --arg name "$skill_name"
}

manifest_skill_is_managed() {
    local skill_name="$1"
    jq -e --arg prefix ".repomethod/skills/${skill_name}/" '
        any(.files | keys[]; startswith($prefix))
    ' "$manifest_path" >/dev/null
}

is_disabled() {
    local skill_name="$1"
    [ -f "$disabled_file" ] && grep -Fqx -- "$skill_name" "$disabled_file"
}

mark_disabled() {
    local skill_name="$1" tmp
    mkdir -p "$(dirname "$disabled_file")"
    tmp="$(mktemp "${disabled_file}.tmp.XXXXXX")"
    { [ ! -f "$disabled_file" ] || cat "$disabled_file"; printf '%s\n' "$skill_name"; } \
        | awk 'NF' | sort -u > "$tmp"
    mv "$tmp" "$disabled_file"
}

clear_disabled() {
    local skill_name="$1" tmp
    [ -f "$disabled_file" ] || return 0
    tmp="$(mktemp "${disabled_file}.tmp.XXXXXX")"
    grep -Fvx -- "$skill_name" "$disabled_file" > "$tmp" || true
    if [ -s "$tmp" ]; then
        mv "$tmp" "$disabled_file"
    else
        rm -f -- "$tmp" "$disabled_file"
    fi
}

# A symlink's target string looking right is not proof this script created
# it — only a manifest record of source "skill-link" with a matching target
# is. Without that proof the path is refused, never removed, even when the
# readlink output happens to already match canonical_rel exactly.
manifest_link_is_owned() {
    local rel_path="$1" current_target="$2"
    jq -e --arg path "$rel_path" --arg target "$current_target" \
        '.files[$path].source == "skill-link" and .files[$path].sha256 == $target' \
        "$manifest_path" >/dev/null
}

link_is_safe_to_remove() {
    local skill_name="$1" link_parent_rel="$2"
    local link_path="${repo_root}/${link_parent_rel}/${skill_name}"
    local rel_path="${link_parent_rel}/${skill_name}"

    [ -e "$link_path" ] || [ -L "$link_path" ] || return 0
    if [ -L "$link_path" ]; then
        manifest_link_is_owned "$rel_path" "$(readlink "$link_path")" \
            || die "refusing to remove foreign symlink: ${rel_path}"
        return 0
    fi
    die "refusing to remove modified or foreign path: ${rel_path}"
}

remove_links() {
    local skill_name="$1" link_parent_rel link_path
    for link_parent_rel in ".agents/skills" ".claude/skills"; do
        link_is_safe_to_remove "$skill_name" "$link_parent_rel"
    done
    for link_parent_rel in ".agents/skills" ".claude/skills"; do
        link_path="${repo_root}/${link_parent_rel}/${skill_name}"
        [ -L "$link_path" ] && rm -f -- "$link_path"
    done
    manifest_remove_links "$skill_name"
}

stage_link() {
    local skill_name="$1" link_parent_rel="$2"
    local canonical_rel="../../.repomethod/skills/${skill_name}"
    local link_parent="${repo_root}/${link_parent_rel}"
    local link_path="${link_parent}/${skill_name}"
    local rel_path="${link_parent_rel}/${skill_name}"

    assert_no_symlink_parent "$link_parent_rel"
    mkdir -p "$link_parent"

    # A correct-looking symlink is only trusted as already-ours when the
    # manifest backs that up (manifest_link_is_owned) — matching lib/skills.sh's
    # own ownership rule. Anything else at this path, including a symlink
    # that merely resolves to the right place, is refused untouched.
    if [ -L "$link_path" ]; then
        if [ "$(readlink "$link_path")" = "$canonical_rel" ] \
            && manifest_link_is_owned "$rel_path" "$canonical_rel"; then
            manifest_update '.files[$path] = {sha256:$target, source:"skill-link"}' \
                --arg path "$rel_path" --arg target "$canonical_rel"
            return 0
        fi
        die "skill target already exists and is not managed: ${rel_path}"
    fi
    if [ -e "$link_path" ]; then
        die "skill target already exists and is not managed: ${rel_path}"
    fi

    ln -s "$canonical_rel" "$link_path" \
        || die "symbolic links are required for RepoMethod skill links: ${rel_path}"
    manifest_update '.files[$path] = {sha256:$target, source:"skill-link"}' \
        --arg path "$rel_path" --arg target "$canonical_rel"
}

# Read-only mirror of stage_link's own refusals, run for BOTH hosts before
# anything is copied or linked. stage_link is correct in isolation but runs
# once per host: a conflict at the second host used to leave the copied
# skill directory, the first host's symlink, and its manifest entry behind,
# and a retry then failed with "skill already exists". Same shape and same
# reason as lib/skills.sh's preflight_skill_links on the install path.
preflight_links() {
    local skill_name="$1" link_parent_rel link_path rel_path
    local canonical_rel="../../.repomethod/skills/${skill_name}"
    for link_parent_rel in ".agents/skills" ".claude/skills"; do
        assert_no_symlink_parent "$link_parent_rel"
        link_path="${repo_root}/${link_parent_rel}/${skill_name}"
        rel_path="${link_parent_rel}/${skill_name}"
        if [ -L "$link_path" ]; then
            if [ "$(readlink "$link_path")" = "$canonical_rel" ] \
                && manifest_link_is_owned "$rel_path" "$canonical_rel"; then
                continue
            fi
            die "skill target already exists and is not managed: ${rel_path}"
        fi
        if [ -e "$link_path" ]; then
            die "skill target already exists and is not managed: ${rel_path}"
        fi
    done
    return 0
}

enable_skill() {
    local skill_name="$1"
    [ -f "${skills_root}/${skill_name}/SKILL.md" ] \
        || die "skill not found: $skill_name"
    preflight_links "$skill_name"
    stage_link "$skill_name" ".agents/skills"
    stage_link "$skill_name" ".claude/skills"
    clear_disabled "$skill_name"
}

list_skills() {
    local skill_dir skill_name status source
    [ -d "$skills_root" ] || return 0
    while IFS= read -r skill_dir; do
        skill_name="$(basename "$skill_dir")"
        status="enabled"
        is_disabled "$skill_name" && status="disabled"
        source="local"
        manifest_skill_is_managed "$skill_name" && source="managed"
        printf '%s\t%s\t%s\n' "$skill_name" "$status" "$source"
    done < <(find "$skills_root" -mindepth 1 -maxdepth 1 -type d | sort)
}

add_skill() {
    local source_dir="$1"
    local source_abs declared_name skill_name destination temp_dir
    [ -d "$source_dir" ] || die "skill directory not found: $source_dir"
    [ -f "${source_dir}/SKILL.md" ] || die "SKILL.md not found in: $source_dir"
    source_abs="$(cd "$source_dir" && pwd -P)"
    declared_name="$(read_declared_name "${source_abs}/SKILL.md")"
    [ -n "$declared_name" ] || die "SKILL.md must declare a frontmatter name"
    validate_name "$declared_name"
    skill_name="$declared_name"
    if find "$source_abs" -type l -print -quit | grep -q .; then
        die "skill source must not contain symlinks"
    fi
    destination="${skills_root}/${skill_name}"

    [ ! -e "$destination" ] || die "skill already exists: $skill_name (use enable if it is disabled)"
    preflight_links "$skill_name"
    mkdir -p "$skills_root"
    temp_dir="$(mktemp -d "${skills_root}/.${skill_name}.tmp.XXXXXX")"
    cp -R "${source_abs}/." "$temp_dir/"
    mv "$temp_dir" "$destination"
    enable_skill "$skill_name"
    printf 'added skill: %s\n' "$skill_name"
}

remove_skill() {
    local skill_name="$1"
    [ -d "${skills_root}/${skill_name}" ] || die "skill not found: $skill_name"
    if manifest_skill_is_managed "$skill_name"; then
        if is_disabled "$skill_name"; then
            printf 'skill already disabled: %s\n' "$skill_name"
            return 0
        fi
        remove_links "$skill_name"
        mark_disabled "$skill_name"
        printf 'disabled managed skill: %s\n' "$skill_name"
        return 0
    fi

    remove_links "$skill_name"
    rm -rf -- "${skills_root:?}/${skill_name}"
    clear_disabled "$skill_name"
    printf 'removed local skill: %s\n' "$skill_name"
}

command="${1:-}"
[ -n "$command" ] || { usage; exit 1; }
shift

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
skills_root="${repo_root}/.repomethod/skills"
manifest_path="${repo_root}/.repomethod/manifest.json"
disabled_file="${repo_root}/.repomethod/disabled-skills.txt"

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
assert_no_symlink_parent ".repomethod"
assert_no_symlink_parent ".repomethod/skills"
[ -f "$manifest_path" ] || die "repomethod manifest not found: $manifest_path"
jq -e . "$manifest_path" >/dev/null 2>&1 || die "invalid manifest: $manifest_path"

name=""
source_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) [ "$#" -ge 2 ] || die "missing value for --name"; name="$2"; shift 2 ;;
        --source) [ "$#" -ge 2 ] || die "missing value for --source"; source_dir="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$command" in
    list)
        if [ -n "$name" ] || [ -n "$source_dir" ]; then
            die "list accepts no arguments"
        fi
        list_skills
        ;;
    add)
        [ -n "$source_dir" ] || die "add requires --source"
        [ -z "$name" ] || die "add reads the name from SKILL.md"
        add_skill "$source_dir"
        ;;
    remove)
        [ -n "$name" ] || die "remove requires --name"
        validate_name "$name"
        remove_skill "$name"
        ;;
    enable)
        [ -n "$name" ] || die "enable requires --name"
        validate_name "$name"
        enable_skill "$name"
        printf 'enabled skill: %s\n' "$name"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        die "unknown command: $command"
        ;;
esac
