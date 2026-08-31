setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/target.sh"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf -- "$WORK"
}

@test "validate_target accepts an existing git repository" {
    git -C "$WORK" init -q
    run validate_target "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORK" ]]
}

@test "validate_target rejects a non-existent path" {
    run validate_target "${WORK}/does-not-exist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "validate_target rejects a directory that is not a git repository" {
    mkdir -p "${WORK}/plain"
    run validate_target "${WORK}/plain"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a git repository"* ]]
}
