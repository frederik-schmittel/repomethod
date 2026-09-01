#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
results_dir="${1:-test-results}"

if [[ "$results_dir" != /* ]]; then
    results_dir="${repo_root}/${results_dir}"
fi

mkdir -p "$results_dir"
rm -f -- "${results_dir}/report.xml" "${results_dir}/files.tsv" "${results_dir}/tests.tsv"

test_files=("${repo_root}"/tests/*.bats)

bats_status=0
bats --timing --report-formatter junit --output "$results_dir" "${test_files[@]}" || bats_status=$?

summary_status=0
node "${repo_root}/scripts/summarize-bats-junit.mjs" \
    "${results_dir}/report.xml" \
    "${results_dir}/files.tsv" \
    "${results_dir}/tests.tsv" \
    "${test_files[@]}" || summary_status=$?

if [[ -f "${results_dir}/files.tsv" ]]; then
    printf '\nBats timings by file:\n'
    cat "${results_dir}/files.tsv"
fi

if (( bats_status != 0 )); then
    exit "$bats_status"
fi

exit "$summary_status"
