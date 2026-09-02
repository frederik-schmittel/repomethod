setup() {
    bats_require_minimum_version 1.5.0
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    SRC="${REPO_ROOT}/blueprint/.repomethod/scripts"
    LEDGER="${SRC}/descope-ledger.sh"
    GRAPH="${SRC}/workflow-graph.sh"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email t@e.x
    git -C "$WORK" config user.name T
    printf 'seed\n' > "$WORK/seed"
    git -C "$WORK" add seed
    git -C "$WORK" commit -q -m seed
    mkdir -p "$WORK/.repomethod/workflows"
    # State lives where a real workflow keeps it; descope sidecars sit beside it.
    STATE="${WORK}/.repomethod/workflows/demo.json"
    printf '{"feature":"demo","repo_root":"%s"}\n' "$WORK" > "$STATE"
    LEDGER_FILE="$WORK/.repomethod/workflows/demo.descopes.jsonl"
    CHECKPOINT_FILE="$WORK/.repomethod/workflows/demo.descopes.checkpoint.json"
}

teardown() { rm -rf -- "$WORK"; }
init_ledger() { "$LEDGER" init --state "$STATE" >/dev/null; }
add_descope() {
    "$LEDGER" add --state "$STATE" --id "$1" --plan-ref "$2" \
        --description "omit $1" --rationale bounded --owner implementer >/dev/null
}

@test "ledger is feature scoped and derives multiple descopes" {
    init_ledger
    [ -f "$LEDGER_FILE" ]
    [ -f "$CHECKPOINT_FILE" ]
    [ ! -e "$REPO_ROOT/blueprint/.repomethod/descoped.md" ]
    add_descope descope.zeta obl.zeta
    add_descope descope.alpha obl.alpha
    run "$LEDGER" state --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.descopes | map(.id) | join(",")' <<< "$output")" = "descope.alpha,descope.zeta" ]
    [ "$(jq -r '.blocking_ids | join(",")' <<< "$output")" = "descope.alpha,descope.zeta" ]
}

@test "required fields stable identities and duplicate ids fail closed" {
    init_ledger
    run "$LEDGER" add --state "$STATE" --id bad --plan-ref obl.api --description omit --rationale later --owner dev
    [ "$status" -ne 0 ]
    run "$LEDGER" add --state "$STATE" --id descope.api --plan-ref bad --description omit --rationale later --owner dev
    [ "$status" -ne 0 ]
    run "$LEDGER" add --state "$STATE" --id descope.api --plan-ref obl.api --description omit --rationale later
    [ "$status" -ne 0 ]
    add_descope descope.api obl.api
    run "$LEDGER" add --state "$STATE" --id descope.api --plan-ref obl.api --description again --rationale later --owner dev
    [ "$status" -ne 0 ]; [[ "$output" == *"already exists"* ]]
}

@test "reviews append and latest status governs delivery state" {
    init_ledger; add_descope descope.api obl.api
    first="$(sed -n '1p' "$LEDGER_FILE")"
    "$LEDGER" review --state "$STATE" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    [ "$(sed -n '1p' "$LEDGER_FILE")" = "$first" ]
    [ "$(wc -l < "$LEDGER_FILE" | tr -d ' ')" = 2 ]
    run "$LEDGER" state --state "$STATE"
    [ "$(jq -r '.accepted_ids[0]' <<< "$output")" = descope.api ]
    "$LEDGER" review --state "$STATE" --id descope.api --status rejected --rationale reconsidered --owner reviewer >/dev/null
    run "$LEDGER" state --state "$STATE"
    [ "$(jq -r '.blocking_ids[0]' <<< "$output")" = descope.api ]
}

@test "tampering truncation and malformed events are detected" {
    init_ledger; add_descope descope.api obl.api
    "$LEDGER" review --state "$STATE" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    cp "$LEDGER_FILE" "$WORK/saved"
    { jq -cS '.description="tampered"' < <(sed -n '1p' "$WORK/saved"); sed -n '2p' "$WORK/saved"; } > "$LEDGER_FILE"
    run "$LEDGER" state --state "$STATE"
    [ "$status" -ne 0 ]; [[ "$output" == *"hash mismatch"* ]]
    head -n 1 "$WORK/saved" > "$LEDGER_FILE"
    run "$LEDGER" state --state "$STATE"
    [ "$status" -ne 0 ]; [[ "$output" == *"event count does not match"* ]]
    printf '{bad json}\n' > "$LEDGER_FILE"
    run "$LEDGER" state --state "$STATE"
    [ "$status" -ne 0 ]; [[ "$output" == *"invalid JSON event"* ]]
}

@test "workflow init and handoff use canonical descope state" {
    repo="$WORK/repo"; mkdir -p "$repo/.repomethod/workflows"
    git -C "$repo" init -q -b main; git -C "$repo" config user.email t@e.x; git -C "$repo" config user.name T
    echo seed > "$repo/seed"; git -C "$repo" add seed; git -C "$repo" commit -q -m seed
    state="$repo/.repomethod/workflows/feature.json"
    (cd "$repo" && "$GRAPH" init --feature feature --mode classic --state "$state" --verify-command true --base HEAD >/dev/null)
    "$LEDGER" add --state "$state" --id descope.accepted --plan-ref obl.accepted --description omit --rationale bounded --owner dev >/dev/null
    "$LEDGER" review --state "$state" --id descope.accepted --status accepted --rationale approved --owner reviewer >/dev/null
    "$LEDGER" add --state "$state" --id descope.open --plan-ref obl.open --description omit --rationale bounded --owner dev >/dev/null
    "$GRAPH" handoff --state "$state" --node implementation --changed src/a.py --next continue >/dev/null
    handoff="$repo/.repomethod/workflows/feature.handoff.json"
    [ "$(jq -r '.open_descope_ids[0]' "$handoff")" = descope.open ]
    [ "$(jq -r '.descopes[] | select(.id=="descope.accepted") | .status' "$handoff")" = accepted ]
}

@test "stateful delivery blocks unreviewed and rejected descopes and fails on tamper" {
    bin="$WORK/bin"; mkdir -p "$bin"; cp "$SRC/deliver.sh" "$SRC/descope-ledger.sh" "$bin/"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/agent-gate.sh"
    printf '#!/usr/bin/env bash\nprintf '\''{"verdict":"done","reason":"workflow complete"}\\n'\''\n' > "$bin/supervisor.sh"
    chmod +x "$bin/"*.sh
    droot="$WORK/delivery-repo"; mkdir -p "$droot/.repomethod/workflows"; git -C "$droot" init -q -b main
    dstate="$droot/.repomethod/workflows/delivery.json"
    printf '{"feature":"delivery","repo_root":"%s"}\n' "$droot" > "$dstate"
    dledger="$droot/.repomethod/workflows/delivery.descopes.jsonl"
    "$bin/descope-ledger.sh" init --state "$dstate" >/dev/null
    "$bin/descope-ledger.sh" add --state "$dstate" --id descope.api --plan-ref obl.api --description omit --rationale bounded --owner dev >/dev/null
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 1 ]; [[ "$output" == *"descope.api (unreviewed)"* ]]
    "$bin/descope-ledger.sh" review --state "$dstate" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 0 ]; [ "$output" = "DELIVERY: done — workflow complete" ]
    "$bin/descope-ledger.sh" review --state "$dstate" --id descope.api --status rejected --rationale reopened --owner reviewer >/dev/null
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 1 ]; [[ "$output" == *"descope.api (rejected)"* ]]
    sed 's/bounded/tampered/' "$dledger" > "$dledger.tmp" && mv "$dledger.tmp" "$dledger"
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 1 ]; [[ "$output" == *"hash mismatch"* ]]
}

@test "ledger works from a linked git worktree" {
    git -C "$WORK" worktree add -q "$WORK/wt" -b wt
    [ -f "$WORK/wt/.git" ]   # a linked worktree's .git is a file, not a directory
    mkdir -p "$WORK/wt/.repomethod/workflows"
    wstate="$WORK/wt/.repomethod/workflows/feature.json"
    printf '{"feature":"feature","repo_root":"%s"}\n' "$WORK/wt" > "$wstate"

    run "$LEDGER" init --state "$wstate"
    [ "$status" -eq 0 ]
    "$LEDGER" add --state "$wstate" --id descope.api --plan-ref obl.api \
        --description omit --rationale bounded --owner dev >/dev/null
    run "$LEDGER" state --state "$wstate"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.blocking_ids[0]' <<< "$output")" = descope.api ]
    [ -f "$WORK/wt/.repomethod/workflows/feature.descopes.jsonl" ]
}

@test "a workflow with no ledger yields empty canonical state and lazily initializes" {
    [ ! -e "$LEDGER_FILE" ]
    run "$LEDGER" state --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.descopes | length' <<< "$output")" = 0 ]
    [ "$(jq -r '.blocking_ids | length' <<< "$output")" = 0 ]

    add_descope descope.api obl.api
    [ -f "$LEDGER_FILE" ]
    [ -f "$CHECKPOINT_FILE" ]
    run "$LEDGER" state --state "$STATE"
    [ "$(jq -r '.blocking_ids[0]' <<< "$output")" = descope.api ]
}
