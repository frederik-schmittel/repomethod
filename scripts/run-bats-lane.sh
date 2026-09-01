#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANE="${1:?usage: run-bats-lane.sh <full|smoke|shard> [results-dir] [shard-index]}"
RESULTS_DIR="${2:-test-results}"

cd "$ROOT"
case "$LANE" in
    full)
        files=(tests/*.bats)
        ;;
    smoke)
        mapfile -t files < <(grep -Ev '^[[:space:]]*(#|$)' .github/ci/bats-smoke.txt)
        [ "${#files[@]}" -gt 0 ] || { echo "[error] smoke suite is empty" >&2; exit 1; }
        declare -A seen=()
        for file in "${files[@]}"; do
            [ -f "$file" ] || { echo "[error] smoke suite references missing file: $file" >&2; exit 1; }
            [ -z "${seen[$file]:-}" ] || { echo "[error] duplicate smoke test file: $file" >&2; exit 1; }
            seen[$file]=1
        done
        ;;
    shard)
        shard="${3:?shard lane requires a shard index}"
        mapfile -t files < <("$ROOT/scripts/select-bats-shard.sh" "$shard" 2)
        [ "${#files[@]}" -gt 0 ] || { echo "[error] shard $shard is empty" >&2; exit 1; }
        ;;
    *)
        echo "[error] unknown Bats lane: $LANE" >&2
        exit 2
        ;;
esac

exec "$ROOT/scripts/run-bats-timed.sh" "$RESULTS_DIR" "${files[@]}"
