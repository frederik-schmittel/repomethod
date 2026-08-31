#!/usr/bin/env bash
# check-doc-references.sh <repo-root> — flags path-like inline-code
# references in README.md/AGENTS.md/CLAUDE.md that no longer resolve to a
# real file or directory.
set -euo pipefail

repo_root="${1:?usage: check-doc-references.sh <repo-root>}"
stale=0
checked=0

for doc in README.md AGENTS.md CLAUDE.md; do
    doc_path="${repo_root}/${doc}"
    [ -f "$doc_path" ] || continue

    # shellcheck disable=SC2016 # single-quoted: literal backtick patterns, no expansion intended
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        case "$ref" in
            *://*|mailto:*|tel:*) continue ;;
        esac
        checked=$((checked + 1))
        if [ ! -e "${repo_root}/${ref}" ]; then
            echo "STALE: ${doc}: ${ref}"
            stale=$((stale + 1))
        fi
    done < <(grep -oE '`[^`]*/[^`]*`' "$doc_path" | sed -E 's/^`(.*)`$/\1/')
done

if [ "$stale" -gt 0 ]; then
    exit 1
fi

echo "OK: ${checked} references checked"
exit 0
