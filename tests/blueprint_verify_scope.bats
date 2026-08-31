setup() {
    load 'test_helper/common-setup'
    _common_setup
    SCRIPT="${REPO_ROOT}/blueprint/.repomethod/scripts/verify-scope.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q
    git -C "$WORK" config user.email test@example.com
    git -C "$WORK" config user.name test
    mkdir -p "${WORK}/.repomethod" "${WORK}/src/feature" "${WORK}/infra"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    echo "init" > "${WORK}/README.md"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m init
    git -C "$WORK" branch -q base
}

teardown() {
    rm -rf -- "$WORK"
}

write_spec() {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Kontext

x

## Scope

- `src/feature/**`

## Out of Scope

- everything else
EOF
}

@test "passes when only in-scope files changed" {
    write_spec
    echo "x" > "${WORK}/src/feature/a.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "fails when an out-of-scope file changed" {
    write_spec
    echo "x" > "${WORK}/other.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: other.txt"* ]]
}

@test "passes and counts an untracked in-scope file" {
    write_spec
    echo "x" > "${WORK}/src/feature/untracked.txt"
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 1 files in scope"* ]]
}

@test "fails when an untracked out-of-scope file exists" {
    write_spec
    echo "x" > "${WORK}/outside.txt"
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: outside.txt"* ]]
}

@test "managed workflow state evidence and project map are scope metadata" {
    write_spec
    mkdir -p "${WORK}/.repomethod/workflows" "${WORK}/.repomethod/evidence/run"
    printf '{}\n' > "${WORK}/.repomethod/workflows/example.json"
    printf 'verified\n' > "${WORK}/.repomethod/evidence/run/verification.log"
    printf '# Project map\n' > "${WORK}/.repomethod/project-map.md"

    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"

    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: 0 files in scope"* ]]
}

@test "unknown files under repomethod remain subject to Scope" {
    write_spec
    printf 'echo unsafe\n' > "${WORK}/.repomethod/unknown.sh"

    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"

    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: .repomethod/unknown.sh"* ]]
}

@test "fails when a staged out-of-scope file exists" {
    write_spec
    echo "x" > "${WORK}/staged.txt"
    git -C "$WORK" add staged.txt
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: staged.txt"* ]]
}

@test "fails when an unstaged tracked file is out of scope" {
    write_spec
    echo "changed" > "${WORK}/README.md"
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: README.md"* ]]
}

@test "fails when a protected zone file changed even if scope glob would match" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Kontext

x

## Scope

- `infra/**`

## Out of Scope

- n/a
EOF
    echo "x" > "${WORK}/infra/main.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/main.tf"* ]]
}

@test "passes on a protected zone file when explicitly listed as an exact scope line" {
    cat > "${WORK}/spec.md" <<'EOF'
# Task: example

## Kontext

x

## Scope

- `infra/main.tf`

## Out of Scope

- n/a
EOF
    echo "x" > "${WORK}/infra/main.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 0 ]
}

@test "--quick passes when no protected zone was touched" {
    echo "x" > "${WORK}/src/feature/a.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "--quick fails when a protected zone was touched with no spec to authorize it" {
    echo "x" > "${WORK}/infra/main.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/main.tf"* ]]
}

@test "--quick with no --base resolves the diff base (main fallback)" {
    git -C "$WORK" branch -q -f main base
    echo "x" > "${WORK}/src/feature/a.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change
    run "$SCRIPT" --quick --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"usage"* ]]
}

@test "fails closed when the base ref cannot be resolved" {
    write_spec
    echo "x" > "${WORK}/outside.txt"
    run "$SCRIPT" --spec "${WORK}/spec.md" --base does-not-exist --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot resolve base ref"* ]]
}

@test "quick mode fails closed when the base ref cannot be resolved" {
    run "$SCRIPT" --quick --base does-not-exist --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot resolve base ref"* ]]
}

@test "reports a missing spec file instead of parsing nothing" {
    run "$SCRIPT" --spec "${WORK}/absent.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"spec not found"* ]]
}

@test "root-level protected directories are protected" {
    write_spec
    mkdir -p "${WORK}/auth" "${WORK}/migrations"
    echo "x" > "${WORK}/auth/login.ts"
    echo "x" > "${WORK}/migrations/001.sql"
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"auth/login.ts"* ]]
    [[ "$output" == *"migrations/001.sql"* ]]
}

@test "a committed rename out of a protected zone is a violation" {
    write_spec
    echo "x" > "${WORK}/infra/secret.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m seed
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/src/feature"
    git -C "$WORK" mv infra/secret.tf src/feature/secret.tf
    git -C "$WORK" commit -q -m move
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/secret.tf"* ]]
}

@test "a staged rename out of a protected zone is a violation" {
    write_spec
    echo "x" > "${WORK}/infra/secret.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m seed
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/src/feature"
    git -C "$WORK" mv infra/secret.tf src/feature/secret.tf
    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/secret.tf"* ]]
}

@test "quick mode sees a committed rename out of a protected zone" {
    echo "x" > "${WORK}/infra/secret.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m seed
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/docs"
    git -C "$WORK" mv infra/secret.tf docs/secret.tf
    git -C "$WORK" commit -q -m move
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/secret.tf"* ]]
}

@test "quick mode sees a staged rename out of a protected zone" {
    echo "x" > "${WORK}/infra/secret.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m seed
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/docs"
    git -C "$WORK" mv infra/secret.tf docs/secret.tf
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/secret.tf"* ]]
}

@test "an unstaged move out of a protected zone is a violation" {
    echo "x" > "${WORK}/infra/secret.tf"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m seed
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/docs"
    mv "${WORK}/infra/secret.tf" "${WORK}/docs/secret.tf"
    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: infra/secret.tf"* ]]
}

@test "a path in scope-ignore.txt never produces a VIOLATION" {
    write_spec
    printf 'node_modules\nnode_modules/*\n*/node_modules\n*/node_modules/*\n' \
        > "${WORK}/.repomethod/scope-ignore.txt"
    git -C "$WORK" add .repomethod/scope-ignore.txt
    git -C "$WORK" commit -q -m ignore
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/frontend/x/node_modules/pkg"
    echo "x" > "${WORK}/frontend/x/node_modules/pkg/index.js"

    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"VIOLATION"* ]]
    [[ "$output" != *"node_modules"* ]]

    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 0 ]
}

@test "no --base with a non-main fork base yields zero false-positive scope violations (upstream path)" {
    write_spec
    git -C "$WORK" checkout -q -b feature-base
    echo x > "${WORK}/feature-base-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "feature base file"
    git -C "$WORK" checkout -q -b work
    git -C "$WORK" config branch.work.remote .
    git -C "$WORK" config branch.work.merge refs/heads/feature-base
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "in-scope work"
    run "$SCRIPT" --spec "${WORK}/spec.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"feature-base-file.txt"* ]]
    [[ "$output" != *"VIOLATION"* ]]
}

@test "no --base on a self-tracking pushed branch still catches an out-of-scope commit" {
    write_spec
    git -C "$WORK" branch -q -f main base
    bare="$(mktemp -d)"
    git -C "$bare" init -q --bare
    git -C "$WORK" remote add origin "$bare"
    # a slashed branch name pushed with -u: @{upstream} is origin/feature/foo,
    # so only the remote name ("origin/") may be stripped, not "feature/".
    git -C "$WORK" checkout -q -b feature/foo base
    echo x > "${WORK}/out-of-scope.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "out-of-scope committed work"
    git -C "$WORK" push -q -u origin feature/foo
    run "$SCRIPT" --spec "${WORK}/spec.md" --repo "$WORK"
    rm -rf -- "$bare"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: out-of-scope.txt"* ]]
    [[ "$output" != *"OK: 0 files in scope"* ]]
}

@test "no --base falls back to the literal main when nothing else resolves" {
    write_spec
    git -C "$WORK" branch -q -f main base
    git -C "$WORK" checkout -q -b work-mainfb
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "in-scope work"
    run "$SCRIPT" --spec "${WORK}/spec.md" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
    [[ "$output" != *"usage"* ]]
}

@test "an explicit --base that is not an ancestor of HEAD prints the diagnostic and still runs" {
    write_spec
    git -C "$WORK" checkout -q -b sibling base
    echo x > "${WORK}/sibling-file.txt"
    git -C "$WORK" add sibling-file.txt && git -C "$WORK" commit -q -m "sibling work"
    git -C "$WORK" checkout -q -b work base
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add src/feature/c.txt && git -C "$WORK" commit -q -m "in-scope work"
    run "$SCRIPT" --spec "${WORK}/spec.md" --base sibling --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not an ancestor of HEAD"* ]]
}

@test "--quick with an explicit non-ancestor --base prints the diagnostic" {
    git -C "$WORK" checkout -q -b sibling base
    echo x > "${WORK}/sibling-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "sibling work"
    git -C "$WORK" checkout -q -b work base
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "in-scope work"
    run "$SCRIPT" --quick --base sibling --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not an ancestor of HEAD"* ]]
}

@test "--state uses base_ref and missing base_ref falls back" {
    write_spec
    # feature-base carries an out-of-scope commit B; work forks from it with an
    # in-scope commit C.
    git -C "$WORK" checkout -q -b feature-base base
    echo x > "${WORK}/feature-base-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "B out of scope"
    b="$(git -C "$WORK" rev-parse HEAD)"
    git -C "$WORK" checkout -q -b work
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "C in scope"
    mkdir -p "${WORK}/.repomethod/workflows"
    st="${WORK}/.repomethod/workflows/s.json"

    # base_ref = B -> the diff is B...HEAD, feature-base-file.txt never appears
    printf '{"config":{"base_ref":"%s"}}\n' "$b" > "$st"
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "$st" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"feature-base-file.txt"* ]]
    [[ "$output" != *"VIOLATION"* ]]

    # missing base_ref -> resolve_base fallback. With main pinned at A the diff
    # widens to include B, so the out-of-scope file is flagged.
    git -C "$WORK" branch -q -f main base
    printf '{"config":{}}\n' > "$st"
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "$st" --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: feature-base-file.txt"* ]]
}

@test "--state with a non-object config falls back instead of crashing" {
    write_spec
    git -C "$WORK" checkout -q -b feature-base base
    echo x > "${WORK}/feature-base-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "B out of scope"
    git -C "$WORK" checkout -q -b work
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "C in scope"
    git -C "$WORK" branch -q -f main base
    mkdir -p "${WORK}/.repomethod/workflows"
    st="${WORK}/.repomethod/workflows/s.json"

    # a hand-edited / corrupt state whose .config is a scalar, not an object.
    # `.config.base_ref` cannot be indexed: this must degrade to resolve_base
    # (missing value), never abort the script with a raw jq error under set -e.
    printf '{"config":"corrupt-scalar"}\n' > "$st"
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "$st" --repo "$WORK"
    [[ "$output" != *"Cannot index"* ]]
    [[ "$output" != *"jq: error"* ]]
    # same outcome as the missing-base_ref fallback above: main is at A, so the
    # widened diff flags the out-of-scope file.
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: feature-base-file.txt"* ]]
}

@test "explicit --base wins over --state and keeps diagnostics" {
    write_spec
    git -C "$WORK" checkout -q -b sibling base
    echo x > "${WORK}/sibling-file.txt"
    git -C "$WORK" add sibling-file.txt && git -C "$WORK" commit -q -m "sibling work"
    git -C "$WORK" checkout -q -b work base
    echo x > "${WORK}/src/feature/c.txt"
    git -C "$WORK" add src/feature/c.txt && git -C "$WORK" commit -q -m "in-scope work"
    mkdir -p "${WORK}/.repomethod/workflows"
    st="${WORK}/.repomethod/workflows/s.json"
    printf '{"config":{"base_ref":"%s"}}\n' "$(git -C "$WORK" rev-parse base)" > "$st"

    # explicit --base is a non-ancestor: it must win over the (valid) state
    # base_ref AND still emit the ancestor diagnostic.
    run "$SCRIPT" --spec "${WORK}/spec.md" --base sibling --state "$st" --repo "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not an ancestor of HEAD"* ]]
}

@test "invalid state base_ref fails instead of falling back" {
    write_spec
    echo x > "${WORK}/src/feature/a.txt"
    mkdir -p "${WORK}/.repomethod/workflows"
    st="${WORK}/.repomethod/workflows/s.json"

    printf '{"config":{"base_ref":"not-a-valid-sha"}}\n' > "$st"
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "$st" --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid config.base_ref in state: not-a-valid-sha"* ]]

    # well-formed 40-hex but not a real commit: still a hard failure
    printf '{"config":{"base_ref":"0000000000000000000000000000000000000000"}}\n' > "$st"
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "$st" --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid config.base_ref in state"* ]]

    # --quick may not carry --state at all
    run "$SCRIPT" --quick --state "$st" --base base --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--state is only valid with --spec"* ]]

    # a --state path that is not a readable JSON file
    run "$SCRIPT" --spec "${WORK}/spec.md" --state "${WORK}/nope.json" --repo "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"state not found: ${WORK}/nope.json"* ]]
}

@test "a protected path in scope-ignore.txt is still a VIOLATION" {
    write_spec
    printf 'migrations/*\n*/migrations/*\n' > "${WORK}/.repomethod/scope-ignore.txt"
    git -C "$WORK" add .repomethod/scope-ignore.txt
    git -C "$WORK" commit -q -m ignore
    git -C "$WORK" branch -q -f base HEAD
    mkdir -p "${WORK}/migrations"
    echo "x" > "${WORK}/migrations/001.sql"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m change

    run "$SCRIPT" --spec "${WORK}/spec.md" --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: migrations/001.sql"* ]]

    run "$SCRIPT" --quick --base base --repo "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"VIOLATION: migrations/001.sql"* ]]
}
