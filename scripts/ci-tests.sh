#!/usr/bin/env bash
# ci-tests.sh — repository-owned Bats runner shared by local CI and GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_BATS="1.13.0"
LANE="${1:-full}"
RESULTS_DIR="${2:-test-results}"
SHARD="${3:-}"

command -v bats >/dev/null 2>&1 || {
    echo "[ci-tests] missing required command: bats ${EXPECTED_BATS}" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || {
    echo "[ci-tests] missing required command: node" >&2
    exit 1
}

bats_version="$(bats --version 2>/dev/null | awk '{print $2; exit}')"
if [ "$bats_version" != "$EXPECTED_BATS" ]; then
    echo "[ci-tests] bats version mismatch: expected ${EXPECTED_BATS}, got ${bats_version:-unknown}" >&2
    exit 1
fi

case "$LANE" in
    full|smoke)
        exec bash "$ROOT/scripts/run-bats-lane.sh" "$LANE" "$RESULTS_DIR"
        ;;
    shard)
        [ -n "$SHARD" ] || {
            echo "[ci-tests] shard lane requires a shard index" >&2
            exit 2
        }
        exec bash "$ROOT/scripts/run-bats-lane.sh" shard "$RESULTS_DIR" "$SHARD"
        ;;
    *)
        echo "[ci-tests] usage: ci-tests.sh <full|smoke|shard> [results-dir] [shard-index]" >&2
        exit 2
        ;;
esac
