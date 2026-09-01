#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${1:-test-results}"
shift || true

if [[ "$RESULTS_DIR" != /* ]]; then
    RESULTS_DIR="${ROOT}/${RESULTS_DIR}"
fi

cd "$ROOT"
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    files=(tests/*.bats)
fi

if [ "${#files[@]}" -eq 0 ] || [ ! -f "${files[0]}" ]; then
    echo "[error] no Bats test files selected" >&2
    exit 1
fi
for file in "${files[@]}"; do
    [ -f "$file" ] || { echo "[error] missing Bats test file: $file" >&2; exit 1; }
done

rm -rf -- "$RESULTS_DIR"
mkdir -p -- "$RESULTS_DIR"

bats_status=0
bats --timing --report-formatter junit --output "$RESULTS_DIR" "${files[@]}" || bats_status=$?

summary_status=0
node scripts/summarize-bats-junit.mjs \
    "$RESULTS_DIR/report.xml" \
    "$RESULTS_DIR/files.tsv" \
    "$RESULTS_DIR/tests.tsv" \
    "${files[@]}" || summary_status=$?

if [ -f "$RESULTS_DIR/files.tsv" ]; then
    printf '\nBats timings by file:\n'
    cat "$RESULTS_DIR/files.tsv"
fi

if [ "$bats_status" -ne 0 ]; then
    exit "$bats_status"
fi
exit "$summary_status"
