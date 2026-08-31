#!/usr/bin/env bash
# lib/manifest.sh — sha256 hashing and manifest.json read/write/diff.
set -euo pipefail

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        shasum -a 256 "$path" | awk '{print $1}'
    fi
}

# Hex digest of the exact bytes of <text>, with no trailing newline added
# (printf '%s', not echo). Needed by lib/pointer.sh to hash a marker block's
# content without round-tripping it through a file.
sha256_string() {
    local text="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$text" | sha256sum | awk '{print $1}'
    else
        printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
    fi
}

manifest_init() {
    local version="$1"
    local profiles_csv="$2"
    jq -n \
        --arg version "$version" \
        --arg profiles_csv "$profiles_csv" \
        --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            version: $version,
            installed_at: $installed_at,
            profiles: ($profiles_csv | split(",")),
            files: {}
        }'
}

manifest_add_file() {
    local manifest_json="$1"
    local rel_path="$2"
    local sha256="$3"
    local source="$4"
    local extra_json="${5:-}"
    [ -n "$extra_json" ] || extra_json='{}'
    jq \
        --arg path "$rel_path" \
        --arg sha256 "$sha256" \
        --arg source "$source" \
        --argjson extra "$extra_json" \
        '.files[$path] = ({sha256: $sha256, source: $source} + $extra)' \
        <<<"$manifest_json"
}

manifest_remove_file() {
    local manifest_json="$1"
    local rel_path="$2"
    jq --arg path "$rel_path" 'del(.files[$path])' <<<"$manifest_json"
}

manifest_write() {
    local manifest_json="$1"
    local manifest_path="$2"
    local formatted target_dir
    formatted="$(printf '%s\n' "$manifest_json" | jq '.')"   # fork BEFORE the check
    mkdir -p "$(dirname "$manifest_path")"                    # fork BEFORE the check
    # Re-verify containment as the last thing before the redirect: callers
    # check too, but jq/dirname/mkdir fork between their check and here. The
    # manifest path is always <target>/.repomethod/manifest.json; derive the
    # repo root and refuse if a concurrent swap redirected it. require_repo_path_contained
    # comes from lib/common.sh, which every entrypoint and test sources first.
    target_dir="${manifest_path%/.repomethod/manifest.json}"
    if [ "$target_dir" != "$manifest_path" ]; then
        require_repo_path_contained "$target_dir" "$manifest_path"
    fi
    printf '%s\n' "$formatted" > "$manifest_path"            # only a builtin between check and sink
}

manifest_read() {
    local manifest_path="$1"
    if [ ! -f "$manifest_path" ]; then
        die "manifest not found: ${manifest_path}"
    fi
    if ! jq -e '.' "$manifest_path" >/dev/null 2>&1; then
        die "manifest is not valid JSON: ${manifest_path}"
    fi
    # Top-level shape only. A structurally broken top level (not an object,
    # no string .version, no object .files) was already effectively a `die`
    # everywhere downstream, so refuse it here with a clear message. Per-entry
    # validation is deliberately NOT done here: a single malformed *entry*
    # must not make `uninstall` unrunnable (that would be a DoS on cleanup) —
    # the loops call manifest_entry_trusted per entry and preserve-and-report.
    if ! jq -e '(type == "object") and (.version | type == "string") and (.files | type == "object")' \
        "$manifest_path" >/dev/null 2>&1; then
        die "manifest has a malformed top-level structure (need an object with a string .version and an object .files): ${manifest_path}"
    fi
    cat "$manifest_path"
}

# The manifest lives in the target repository and any contributor or local
# process can edit it, so it is untrusted input, not a record of fact.
# manifest_entry_trusted guards against that in two layers: the STRUCTURAL
# half (Task 10A) — a fixed source enum, keys that are plain relative paths,
# and the two source classes whose namespace is fixed by construction — and
# the INVENTORY cross-check (Task 10B, further down the function) that proves
# a "blueprint" key is a path this running package actually ships and a
# "skill-link" key has its canonical directory and link target.
#
# Populated ONCE per run by manifest_trust_init, before the entry loop, so
# blueprint_inventory (which forks a `find`) runs once rather than once per
# entry. `declare -gA` needs bash 4.x — guaranteed by the lib/common.sh 4.4
# guard. Empty until manifest_trust_init runs, so an unseeded "blueprint"
# check fails closed, which is the safe default. manifest_trust_init streams
# blueprint_inventory rather than capturing its status: an empty result
# (unreadable package blueprint) deliberately leaves the array empty ->
# every "blueprint" entry then fails closed and is preserved + reported.
declare -gA _MANIFEST_BLUEPRINT_INVENTORY=()

manifest_trust_init() {
    _MANIFEST_BLUEPRINT_INVENTORY=()
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && _MANIFEST_BLUEPRINT_INVENTORY["$f"]=1
    done < <(blueprint_inventory)
    # Explicit: the loop body's last command is a `[ -n "$f" ]` test that is
    # false on an empty trailing line, which would make this function return 1.
    # It is called bare under `set -e` (uninstall.sh, update.sh) in the
    # destructive path, so a defined 0 exit is load-bearing.
    return 0
}

# Returns 0 when the entry is structurally trusted AND (Task 10B) cross-checks
# against independent evidence for its source class; non-zero with a concrete
# reason on stderr otherwise (callers slice the reason for their log line).
# The optional 3rd arg target_abs is the repository root — needed by the
# skill-link branch to locate the canonical skill directory; a caller that
# omits it makes that check unsatisfiable (fail closed).
manifest_entry_trusted() {
    local manifest_json="$1"
    local rel_path="$2"
    local target_abs="${3:-}"
    local source
    source="$(jq -r --arg p "$rel_path" '.files[$p].source // ""' <<<"$manifest_json")"

    # "generated" is deliberately absent: the plan records it as vestigial
    # (named only in one update.sh exclusion filter, written by no code
    # path), so it is rejected like any other unknown class.
    case "$source" in
        blueprint|local|skill-link|pointer-block) ;;
        *)
            printf 'manifest_entry_trusted: %s: unknown source class "%s"\n' "$rel_path" "$source" >&2
            return 1 ;;
    esac

    if [[ "$rel_path" == /* ]]; then
        printf 'manifest_entry_trusted: "%s": unsafe key (absolute path)\n' "$rel_path" >&2
        return 1
    fi
    if [[ "$rel_path" =~ (^|/)\.\.(/|$) ]]; then
        printf 'manifest_entry_trusted: "%s": unsafe key (contains "..")\n' "$rel_path" >&2
        return 1
    fi
    if [[ "$rel_path" =~ (^|/)\.(/|$) ]]; then
        printf 'manifest_entry_trusted: "%s": unsafe key (contains "." path component)\n' "$rel_path" >&2
        return 1
    fi
    if [[ -z "${rel_path//[[:space:]]/}" ]]; then
        printf 'manifest_entry_trusted: "%s": unsafe key (empty or whitespace-only)\n' "$rel_path" >&2
        return 1
    fi

    if [ "$source" = "pointer-block" ]; then
        case "$rel_path" in
            AGENTS.md|CLAUDE.md) ;;
            *)
                printf 'manifest_entry_trusted: "%s": pointer-block source on a non-pointer path\n' "$rel_path" >&2
                return 1 ;;
        esac
    fi

    if [ "$source" = "skill-link" ]; then
        if [[ ! "$rel_path" =~ ^\.(agents|claude)/skills/[a-z0-9][a-z0-9._-]*$ ]]; then
            printf 'manifest_entry_trusted: "%s": skill-link source outside .agents|.claude/skills/<name>\n' "$rel_path" >&2
            return 1
        fi
    fi

    # Task 10B — the load-bearing half: the structural checks above prove the
    # key is well-formed; the per-source cross-check below proves the entry
    # names something this running package could actually have installed, so a
    # forged entry for an arbitrary in-repo path is preserved and reported
    # instead of deleted (uninstall) / refreshed (update).
    case "$source" in
        blueprint)
            # Must be a path this version's own blueprint ships. The
            # inventory is seeded once per run by manifest_trust_init from
            # blueprint_source_dir() inside the package (never from --source);
            # an unseeded or absent key fails closed.
            if [ -z "${_MANIFEST_BLUEPRINT_INVENTORY[$rel_path]+set}" ]; then
                printf 'manifest_entry_trusted: %s: not in this version'"'"'s blueprint inventory\n' "$rel_path" >&2
                return 1
            fi
            ;;
        local)
            # No inventory check (Ruling P2): a "local" entry never leads to a
            # destructive or overwriting op — uninstall keeps it, update never
            # overwrites it — so it needs no package inventory to be
            # preserved. The structural pass alone makes it trusted.
            ;;
        skill-link)
            # Deliberately NOT inventoried: a skill added with
            # manage-skills.sh is legitimate and unknown to the package
            # blueprint. Require instead that (a) the canonical skill
            # directory exists and (b) the recorded link target is exactly
            # the canonical relative link. Empty target_abs => (a) is
            # unsatisfiable => fail closed.
            local skill_name="${rel_path##*/}"
            if [ -z "$target_abs" ] || [ ! -d "${target_abs}/.repomethod/skills/${skill_name}" ]; then
                printf 'manifest_entry_trusted: %s: skill-link canonical directory .repomethod/skills/%s not present\n' "$rel_path" "$skill_name" >&2
                return 1
            fi
            local recorded_target
            recorded_target="$(jq -r --arg p "$rel_path" '.files[$p].sha256 // ""' <<<"$manifest_json")"
            if [ "$recorded_target" != "../../.repomethod/skills/${skill_name}" ]; then
                printf 'manifest_entry_trusted: %s: skill-link recorded target "%s" is not "../../.repomethod/skills/%s"\n' "$rel_path" "$recorded_target" "$skill_name" >&2
                return 1
            fi
            ;;
        pointer-block)
            # No inventory check needed: the key is already restricted to
            # AGENTS.md / CLAUDE.md above, both shipped by the package
            # blueprint.
            ;;
    esac

    return 0
}

manifest_file_hash() {
    local manifest_json="$1"
    local rel_path="$2"
    jq -r --arg path "$rel_path" '.files[$path].sha256 // ""' <<<"$manifest_json"
}
