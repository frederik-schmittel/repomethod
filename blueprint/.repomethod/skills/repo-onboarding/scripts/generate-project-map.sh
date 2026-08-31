#!/usr/bin/env bash
# generate-project-map.sh <repo-root> — writes a size-capped
# .repomethod/project-map.md: stack, make targets, protected zones,
# shallow directory structure. Structure is truncated first if the map
# would exceed MAX_LINES; commands and protected zones are never truncated.
set -euo pipefail

MAX_LINES=400
dir="${1:-.}"
out="${dir}/.repomethod/project-map.md"
mkdir -p "$(dirname "$out")"

# Write the never-truncated sections straight to $out, then append as many
# structure lines as fit under MAX_LINES. No temp file, no locating the
# structure heading and subtracting — the arithmetic that went negative (and
# killed BSD `head`) when make targets or protected zones alone exceeded the
# cap.
{
    echo "# Project Map"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Make targets"
    if [ -f "${dir}/Makefile" ]; then
        grep -E '^[a-zA-Z0-9_-]+:' "${dir}/Makefile" | sed -E 's/:.*//' | sed 's/^/- /'
    else
        echo "(no Makefile)"
    fi
    echo
    echo "## Protected zones"
    if [ -f "${dir}/.repomethod/protected-zones.txt" ]; then
        grep -Ev '^[[:space:]]*(#|$)' "${dir}/.repomethod/protected-zones.txt" | sed 's/^/- /'
    else
        echo "(none declared)"
    fi
    echo
    echo "## Structure (depth 2)"
} > "$out"

remaining=$(( MAX_LINES - $(wc -l < "$out") - 1 ))
[ "$remaining" -lt 0 ] && remaining=0
structure="$(find "$dir" -mindepth 1 -maxdepth 2 -type d \
    \( -name .git -o -name node_modules \) -prune -o \
    -type d -print | sed "s|^${dir}/||" | sort | sed 's/^/- /')"
structure_count="$(printf '%s\n' "$structure" | wc -l)"
# `head -n 0` is an error on BSD/macOS head, so only append when something fits.
if [ "$remaining" -gt 0 ]; then
    printf '%s\n' "$structure" | head -n "$remaining" >> "$out"
fi
if [ "$structure_count" -gt "$remaining" ]; then
    echo "(truncated: structure exceeded the ${MAX_LINES}-line cap)" >> "$out"
fi
