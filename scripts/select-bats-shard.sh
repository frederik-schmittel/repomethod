#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARD="${1:?usage: select-bats-shard.sh <shard> [count] [manifest]}"
COUNT="${2:-2}"
MANIFEST="${3:-${ROOT}/.github/ci/bats-shards.tsv}"

"${ROOT}/scripts/validate-bats-shards.sh" "$MANIFEST" "$COUNT"
case "$SHARD" in ''|*[!0-9]*) echo "[error] invalid shard id: $SHARD" >&2; exit 1 ;; esac
[ "$SHARD" -lt "$COUNT" ] || { echo "[error] shard id out of range: $SHARD" >&2; exit 1; }
awk -F '\t' -v shard="$SHARD" '$1 == shard { print $2 }' "$MANIFEST"
