bats_require_minimum_version 1.5.0

setup() {
    load 'test_helper/common-setup'
    _common_setup
    source "${REPO_ROOT}/lib/common.sh"
}

@test "log_info writes to stderr with [info] prefix" {
    run --separate-stderr log_info "hello"
    [ "$status" -eq 0 ]
    [[ "$stderr" == "[info] hello" ]]
}

@test "die logs error and exits 1" {
    run die "boom"
    [ "$status" -eq 1 ]
    [[ "$output" == "[error] boom" ]]
}

@test "die aborts the caller even from a nested command-substitution call chain" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        inner() { die 'boom'; }
        outer() { local x; x=\$(inner); echo 'UNREACHABLE'; }
        result=\$(outer)
        echo \"UNREACHABLE2: \$result\"
    "
    [ "$status" -eq 1 ]
    [[ "$output" != *"UNREACHABLE"* ]]
}

@test "require_cmd succeeds for an existing command" {
    run require_cmd bash
    [ "$status" -eq 0 ]
}

@test "require_cmd dies for a missing command" {
    run require_cmd this-command-does-not-exist-xyz
    [ "$status" -eq 1 ]
    [[ "$output" == *"this-command-does-not-exist-xyz"* ]]
}

@test "require_bash_44 accepts 4.4 and newer" {
    run require_bash_44 4 4
    [ "$status" -eq 0 ]
    run require_bash_44 5 0
    [ "$status" -eq 0 ]
}

@test "require_bash_44 rejects anything older than 4.4" {
    run require_bash_44 3 2
    [ "$status" -eq 1 ]
    [[ "$output" == *"Bash 4.4 or newer"* ]]
    run require_bash_44 4 3
    [ "$status" -eq 1 ]
}

@test "make_temp_dir prints an existing directory path" {
    source "${REPO_ROOT}/lib/common.sh"
    register_cleanup_trap
    dir="$(make_temp_dir)"
    [ -d "$dir" ]
}

@test "cleanup_temp_dirs removes directories created by make_temp_dir" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        register_cleanup_trap
        dir=\$(make_temp_dir)
        echo \"\$dir\"
    "
    [ "$status" -eq 0 ]
    [ ! -d "$output" ]
}
