#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${1:-${ROOT}/.github/ci/bats-shards.tsv}"
SHARD_COUNT="${2:-2}"

case "$SHARD_COUNT" in
    ''|*[!0-9]*|0) echo "[error] shard count must be a positive integer" >&2; exit 1 ;;
esac

cd "$ROOT"
expected=(tests/*.bats)
if [ "${#expected[@]}" -eq 0 ] || [ ! -f "${expected[0]}" ]; then
    echo "[error] no Bats test files found" >&2
    exit 1
fi
[ -f "$MANIFEST" ] || { echo "[error] missing shard manifest: $MANIFEST" >&2; exit 1; }

declare -A seen=()
declare -a counts=()
for ((i = 0; i < SHARD_COUNT; i++)); do counts[i]=0; done

while IFS=$'\t' read -r shard file extra; do
    [ -z "${shard}${file}${extra}" ] && continue
    [[ "$shard" == \#* ]] && continue
    [ -z "$extra" ] || { echo "[error] malformed shard row for $file" >&2; exit 1; }
    case "$shard" in ''|*[!0-9]*) echo "[error] invalid shard id: $shard" >&2; exit 1 ;; esac
    [ "$shard" -lt "$SHARD_COUNT" ] || { echo "[error] shard id out of range: $shard" >&2; exit 1; }
    [ -f "$file" ] || { echo "[error] shard manifest references missing file: $file" >&2; exit 1; }
    [ -z "${seen[$file]:-}" ] || { echo "[error] duplicate test file in shard manifest: $file" >&2; exit 1; }
    seen[$file]=1
    counts[shard]=$((counts[shard] + 1))
done < "$MANIFEST"

for file in "${expected[@]}"; do
    [ -n "${seen[$file]:-}" ] || { echo "[error] test file omitted from shard manifest: $file" >&2; exit 1; }
done
[ "${#seen[@]}" -eq "${#expected[@]}" ] || { echo "[error] shard manifest contains unexpected test files" >&2; exit 1; }
for ((i = 0; i < SHARD_COUNT; i++)); do
    [ "${counts[$i]}" -gt 0 ] || { echo "[error] shard $i is empty" >&2; exit 1; }
done
