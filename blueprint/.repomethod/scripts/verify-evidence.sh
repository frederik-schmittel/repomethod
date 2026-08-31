#!/usr/bin/env bash
# verify-evidence.sh --spec <spec.md>
# Checks that every evidence file declared in the spec's "Expected Evidence"
# section (or the original German "Erwartete Evidenz" — both spellings are
# accepted) exists under .repomethod/evidence/ and is non-empty.
#
# The evidence directory is fixed at .repomethod/evidence/ relative to the
# working directory (the repo root, as the gate runs it): it is the one place
# RepoMethod evidence ever lives, it is exactly the prefix the spec declares,
# and matching those two spellings is the whole point of the check.
#
# Containment: a declared path must resolve to a real, regular, non-empty file
# that physically sits inside .repomethod/evidence/. An absolute path, a "."
# or ".." component, and any symlink on the path — the leaf, an intermediate
# directory, the evidence root, or .repomethod itself — are refused with
# REJECTED: rather than allowed to reach a file outside the evidence directory.
set -euo pipefail

spec=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$spec" ]; then
    echo "usage: verify-evidence.sh --spec <spec.md>" >&2
    exit 1
fi

if [ ! -f "$spec" ]; then
    echo "spec not found: ${spec}" >&2
    exit 1
fi

prefix=".repomethod/evidence/"

# evidence_file_ok <token> — classify an evidence path for containment.
#   return 0  a real, non-symlink, regular, non-empty file that physically
#             lives inside this repo's own .repomethod/evidence/
#   return 1  nothing is there, or it is an empty regular file ("missing")
#   return 2  the path escapes .repomethod/evidence/ and must be refused:
#             an absolute path or a "."/".." component; a symlink on
#             .repomethod, on .repomethod/evidence, or on any existing
#             segment of the path; a physical evidence root that is not
#             exactly <repo>/.repomethod/evidence; or a leaf whose physical
#             parent is not under that physical root.
#
# `test -s` follows both ".." and symlinks, so the lexical prefix check alone
# let a spec declare `.repomethod/evidence/../../README.md`, or point at a
# symlink planted anywhere on the path (including .repomethod itself), and
# have any existing non-empty file stand in for real evidence.
#
# This function is duplicated byte-for-byte in verify-evidence.sh and
# verify-acceptance.sh: blueprint scripts are standalone on purpose so a
# forked copy still composes with a refreshed agent-gate.sh, and the two test
# suites carry the identical vector list so a divergence between the copies
# shows up as a failing test.
evidence_file_ok() {
    local token="$1" repo_phys root_phys parent_phys rel seg path
    case "$token" in
        .repomethod/evidence/?*) ;;
        *) return 2 ;;
    esac
    case "$token" in
        /*|*/../*|*/..|*/./*|*/.) return 2 ;;
    esac
    repo_phys="$(pwd -P)" || return 2
    [ -L ".repomethod" ] && return 2
    [ -L ".repomethod/evidence" ] && return 2
    rel="${token#.repomethod/evidence/}"
    path=".repomethod/evidence"
    while [ -n "$rel" ]; do
        seg="${rel%%/*}"
        path="${path}/${seg}"
        [ -L "$path" ] && return 2
        [ "$seg" = "$rel" ] && break
        rel="${rel#*/}"
    done
    [ -f "$token" ] || return 1
    [ -s "$token" ] || return 1
    root_phys="$(cd .repomethod/evidence 2>/dev/null && pwd -P)" || return 2
    [ "$root_phys" = "${repo_phys}/.repomethod/evidence" ] || return 2
    parent_phys="$(cd "$(dirname "$token")" 2>/dev/null && pwd -P)" || return 2
    case "${parent_phys}/" in
        "${root_phys}/"*) return 0 ;;
        *) return 2 ;;
    esac
}

mapfile -t declared < <(
    awk '/^## (Expected Evidence|Erwartete Evidenz)/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -E '^- `'"${prefix}" \
    | sed -E "s|^- \`${prefix}([^\`]+)\`.*|\1|"
)

missing=0
total=${#declared[@]}

if [ "$total" -eq 0 ]; then
    echo "no evidence files declared in ${spec} (missing or empty ## Expected Evidence / ## Erwartete Evidenz section)" >&2
    exit 1
fi

for name in "${declared[@]}"; do
    path="${prefix}${name}"
    rc=0
    evidence_file_ok "$path" || rc=$?
    if [ "$rc" -eq 0 ]; then
        continue
    elif [ "$rc" -eq 2 ]; then
        echo "REJECTED: ${path} (evidence must be a regular, non-empty file directly under .repomethod/evidence/, with no '..' component and no symlink on the path)"
    else
        echo "MISSING: ${path}"
    fi
    missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    exit 1
fi

echo "OK: ${total}/${total} evidence files present"
exit 0
