#!/usr/bin/env bash
# verify-acceptance.sh --spec <spec.md> --report <report.md>
# Checks that every numbered acceptance criterion in the spec has a
# corresponding "- [x] N. ..." confirmation line in the evidence report.
#
# Section headings are read in English ("## Acceptance Criteria",
# "## Acceptance Mapping") or the original German ("## Akzeptanzkriterien",
# "## Akzeptanz-Mapping") — both spellings are accepted for backward
# compatibility with specs already written.
#
# Opt-in strict check: if the spec's "## Acceptance Mapping" table maps a
# criterion to a backticked token, that token is enforced —
#   - a path under .repomethod/evidence/ must exist and be non-empty
#   - any other token (a test id) must appear literally in some non-empty
#     file under .repomethod/evidence/
# A criterion with no mapping row, a non-backticked cell, or an angle-bracket
# placeholder keeps the checkbox-only behavior. Fully backward compatible.
#
# The evidence directory is fixed at .repomethod/evidence/ on purpose: it is
# the one place RepoMethod evidence ever lives, and keeping the argument list
# unchanged from earlier releases means a locally forked copy of this script
# still composes with a refreshed agent-gate.sh.
#
# Containment: a mapped evidence path must resolve to a real, regular,
# non-empty file physically inside .repomethod/evidence/. An absolute path, a
# "." or ".." component, and any symlink on the path (leaf, intermediate
# directory, the evidence root, or .repomethod itself) are refused with
# STRICT-REJECTED:. The test-id search first calls evidence_tree_ok, which
# refuses a symlinked .repomethod or .repomethod/evidence up front (find
# resolves a symlinked start-point component before it ever lstat()s it);
# `find -type f` then handles any symlink encountered *within* a real
# evidence tree.
set -euo pipefail

spec=""
report=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spec) spec="$2"; shift 2 ;;
        --report) report="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$spec" ] || [ -z "$report" ]; then
    echo "usage: verify-acceptance.sh --spec <spec.md> --report <report.md>" >&2
    exit 1
fi

if [ ! -f "$spec" ]; then
    echo "spec not found: ${spec}" >&2
    exit 1
fi

if [ ! -f "$report" ]; then
    echo "report not found: ${report}" >&2
    exit 1
fi

mapfile -t criteria < <(
    awk '/^## (Acceptance Criteria|Akzeptanzkriterien)/{flag=1; next} /^## /{flag=0} flag' "$spec" \
    | grep -E '^[0-9]+\. '
)

missing=0
strict_missing=0
strict_checked=0
total=${#criteria[@]}

if [ "$total" -eq 0 ]; then
    echo "no acceptance criteria found in ${spec} (missing or empty ## Acceptance Criteria / ## Akzeptanzkriterien section)" >&2
    exit 1
fi

# Backticked token mapped to criterion N in the "## Acceptance Mapping" table,
# or empty. Angle-bracket placeholders (`<...>`) are deliberately ignored.
strict_token_for() {
    awk -v want="$1" '
        /^## (Acceptance Mapping|Akzeptanz-Mapping)/ {flag=1; next}
        /^## / {flag=0}
        flag && /^\|/ {
            line=$0
            sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
            n=split(line, col, "|")
            key=col[1]; gsub(/[[:space:]]/, "", key)
            if (key == want && n >= 2) {
                cell=col[2]
                if (match(cell, /`[^`]+`/)) {
                    tok=substr(cell, RSTART+1, RLENGTH-2)
                    if (tok !~ /[<>]/) print tok
                }
                exit
            }
        }
    ' "$spec"
}

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

# The test-id search below descends .repomethod/evidence with `find`. `find`
# resolves a symlinked path component before it starts, so a symlinked
# .repomethod or .repomethod/evidence would silently redirect the search
# outside the repo — the same escape evidence_file_ok refuses for the
# path-token branch. Refuse it here too, before any file is read.
evidence_tree_ok() {
    local repo_phys root_phys
    [ -L ".repomethod" ] && return 1
    [ -L ".repomethod/evidence" ] && return 1
    [ -d ".repomethod/evidence" ] || return 0   # nothing to search; "not found" below is correct
    repo_phys="$(pwd -P)" || return 1
    root_phys="$(cd .repomethod/evidence 2>/dev/null && pwd -P)" || return 1
    [ "$root_phys" = "${repo_phys}/.repomethod/evidence" ] || return 1
    return 0
}

for line in "${criteria[@]}"; do
    n="$(printf '%s' "$line" | sed -E 's/^([0-9]+)\..*/\1/')"
    if ! grep -qE "^- \[x\] ${n}\." "$report"; then
        echo "MISSING: ${n} ${line#*. }"
        missing=$((missing + 1))
        continue
    fi

    token="$(strict_token_for "$n")"
    [ -n "$token" ] || continue
    strict_checked=$((strict_checked + 1))

    case "$token" in
        .repomethod/evidence/*)
            rc=0
            evidence_file_ok "$token" || rc=$?
            if [ "$rc" -eq 2 ]; then
                echo "STRICT-REJECTED: ${n} evidence path ${token} escapes .repomethod/evidence/ (traversal or symlink)"
                strict_missing=$((strict_missing + 1))
            elif [ "$rc" -ne 0 ]; then
                echo "STRICT-MISSING: ${n} evidence file ${token} is absent or empty"
                strict_missing=$((strict_missing + 1))
            fi
            ;;
        *)
            # A symlinked .repomethod / .repomethod/evidence is resolved by
            # the kernel before `find` starts, silently redirecting the search
            # outside the repo — evidence_tree_ok refuses that here, before any
            # file is read, the same escape evidence_file_ok refuses for the
            # path-token branch. Within a real evidence tree, `find -type f` is
            # false for a symlink and does not descend a symlinked directory,
            # so a planted link inside it can no longer make an outside file
            # satisfy a test-id token the way `grep -r` allowed.
            # The search is a plain loop, not `find ... | xargs grep`: with
            # pipefail an early match closing the pipe kills find with SIGPIPE
            # and would be miscounted as missing evidence.
            # The agent's own planning artifacts (plan.md, spec.md,
            # task_plan.md, findings.md, progress.md) are excluded from the
            # search: they routinely name a test id in prose, and a bare token
            # matching that prose would be a false pass with no test behind it.
            if ! evidence_tree_ok; then
                echo "STRICT-REJECTED: ${n} .repomethod/evidence is not a real directory inside this repo (symlink or traversal)"
                strict_missing=$((strict_missing + 1))
                continue
            fi
            found=0
            while IFS= read -r -d '' file; do
                if grep -qF -- "$token" "$file"; then
                    found=1
                    break
                fi
            done < <(find .repomethod/evidence -type f \
                -not -name plan.md -not -name spec.md -not -name task_plan.md \
                -not -name findings.md -not -name progress.md \
                -print0 2>/dev/null)
            if [ "$found" -eq 0 ]; then
                echo "STRICT-MISSING: ${n} test ${token} not found under .repomethod/evidence/"
                strict_missing=$((strict_missing + 1))
            fi
            ;;
    esac
done

if [ "$missing" -gt 0 ] || [ "$strict_missing" -gt 0 ]; then
    exit 1
fi

if [ "$strict_checked" -gt 0 ]; then
    echo "OK: ${total}/${total} acceptance criteria confirmed (${strict_checked} strict)"
else
    echo "OK: ${total}/${total} acceptance criteria confirmed"
fi
exit 0
