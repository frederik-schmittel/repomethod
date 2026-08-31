setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
    source "${REPO_ROOT}/lib/args.sh"
}

@test "parse_install_args sets ARG_TARGET" {
    parse_install_args --target /tmp/foo
    [ "$ARG_TARGET" = "/tmp/foo" ]
    [ "$ARG_DRY_RUN" = "false" ]
}

@test "--profile is no longer accepted" {
    run parse_install_args --target /tmp/foo --profile core
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag: --profile"* ]]
}

@test "parse_install_args sets ARG_DRY_RUN true" {
    parse_install_args --target /tmp/foo --dry-run
    [ "$ARG_DRY_RUN" = "true" ]
}

@test "parse_install_args accepts --offline as a compatibility no-op" {
    run parse_install_args --target /tmp/foo --offline
    [ "$status" -eq 0 ]
}

@test "parse_install_args sets ARG_PRESERVE true" {
    parse_install_args --target /tmp/foo --preserve
    [ "$ARG_PRESERVE" = "true" ]
    [ "$ARG_BACKUP" = "false" ]
    [ "$ARG_FORCE" = "false" ]
}

@test "parse_install_args rejects the retired --merge flag as unknown" {
    run parse_install_args --target /tmp/foo --merge
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag: --merge"* ]]
}

@test "parse_install_args rejects combining --preserve and --force" {
    run parse_install_args --target /tmp/foo --preserve --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "parse_install_args dies without --target" {
    run parse_install_args --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"--target"* ]]
}

@test "parse_install_args dies on unknown flag" {
    run parse_install_args --target /tmp/foo --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"--bogus"* ]]
}

@test "parse_install_args dies on --profile web as an unknown flag" {
    run parse_install_args --target /tmp/foo --profile web
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag: --profile"* ]]
}

@test "parse_install_args dies on removed flags as unknown" {
    run parse_install_args --target /tmp/foo --with-speckit
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown flag: --with-speckit"* ]]
}
