setup() {
    load 'test_helper/common-setup'
    _common_setup
    TEST_ROOT="$(mktemp -d)"
}

teardown() {
    [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ] && rm -rf -- "$TEST_ROOT"
    true
}

@test "CI shard manifest covers every Bats file exactly once" {
    run bash "${REPO_ROOT}/scripts/validate-bats-shards.sh" \
        "${REPO_ROOT}/.github/ci/bats-shards.tsv" 2
    [ "$status" -eq 0 ]
}

@test "CI shard selection is deterministic and both shards are non-empty" {
    run bash "${REPO_ROOT}/scripts/select-bats-shard.sh" 0 2
    [ "$status" -eq 0 ]
    shard_zero="$output"
    [ -n "$shard_zero" ]

    run bash "${REPO_ROOT}/scripts/select-bats-shard.sh" 0 2
    [ "$status" -eq 0 ]
    [ "$output" = "$shard_zero" ]

    run bash "${REPO_ROOT}/scripts/select-bats-shard.sh" 1 2
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "CI shard validation rejects an omitted test file" {
    manifest="${TEST_ROOT}/bats-shards.tsv"
    grep -v $'\ttests/ci_sharding.bats$' "${REPO_ROOT}/.github/ci/bats-shards.tsv" > "$manifest"

    run bash "${REPO_ROOT}/scripts/validate-bats-shards.sh" "$manifest" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"omitted"* ]]
}
