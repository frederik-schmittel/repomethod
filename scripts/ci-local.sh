#!/usr/bin/env bash
# ci-local.sh — complete local pre-push CI contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_git_modes() {
    local entry meta mode path failures=0
    local -a pathspecs=(
        install.sh
        update.sh
        uninstall.sh
        'scripts/*.sh'
        'blueprint/.repomethod/scripts/*.sh'
        'blueprint/.repomethod/skills/*/scripts/*.sh'
    )

    while IFS= read -r -d '' entry; do
        meta="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        read -r mode _ _ <<< "$meta"
        if [ "$mode" != "100755" ]; then
            echo "[ci-local] executable Git mode required: ${path} is ${mode}, expected 100755" >&2
            failures=$((failures + 1))
        fi
    done < <(git -C "$ROOT" ls-files --stage -z -- "${pathspecs[@]}")

    [ "$failures" -eq 0 ] || return 1
    echo "[ci-local] Git executable modes passed"
}

cd "$ROOT"

echo "[ci-local] quality"
bash scripts/ci-quality.sh

echo "[ci-local] Git modes"
check_git_modes

echo "[ci-local] shard manifest"
bash scripts/validate-bats-shards.sh .github/ci/bats-shards.tsv 2

echo "[ci-local] full Bats regression"
bash scripts/ci-tests.sh full test-results

echo "[ci-local] passed"
