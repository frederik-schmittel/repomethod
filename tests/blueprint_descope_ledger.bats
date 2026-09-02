setup() {
    bats_require_minimum_version 1.5.0
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    SRC="${REPO_ROOT}/blueprint/.repomethod/scripts"
    LEDGER="${SRC}/descope-ledger.sh"
    GRAPH="${SRC}/workflow-graph.sh"
    WORK="$(mktemp -d)"
    STATE="${WORK}/demo.json"
    printf '{"feature":"demo"}\n' > "$STATE"
}

teardown() { rm -rf -- "$WORK"; }
init_ledger() { "$LEDGER" init --state "$STATE" >/dev/null; }
add_descope() {
    "$LEDGER" add --state "$STATE" --id "$1" --plan-ref "$2" \
        --description "omit $1" --rationale bounded --owner implementer >/dev/null
}

@test "ledger is feature scoped and derives multiple descopes" {
    init_ledger
    [ -f "$WORK/demo.descopes.jsonl" ]
    [ -f "$WORK/demo.descopes.checkpoint.json" ]
    [ ! -e "$REPO_ROOT/blueprint/.repomethod/descoped.md" ]
    add_descope descope.zeta obl.zeta
    add_descope descope.alpha obl.alpha
    run "$LEDGER" state --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.descopes | map(.id) | join(",")' <<< "$output")" = "descope.alpha,descope.zeta" ]
    [ "$(jq -r '.blocking_ids | join(",")' <<< "$output")" = "descope.alpha,descope.zeta" ]
}

@test "required fields and stable identities fail closed" {
    init_ledger
    run "$LEDGER" add --state "$STATE" --id bad --plan-ref obl.api --description omit --rationale later --owner dev
    [ "$status" -ne 0 ]
    run "$LEDGER" add --state "$STATE" --id descope.api --plan-ref bad --description omit --rationale later --owner dev
    [ "$status" -ne 0 ]
    run "$LEDGER" add --state "$STATE" --id descope.api --plan-ref obl.api --description omit --rationale later
    [ "$status" -ne 0 ]
}

@test "reviews append and latest status governs delivery state" {
    init_ledger; add_descope descope.api obl.api
    first="$(sed -n '1p' "$WORK/demo.descopes.jsonl")"
    "$LEDGER" review --state "$STATE" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    [ "$(sed -n '1p' "$WORK/demo.descopes.jsonl")" = "$first" ]
    [ "$(wc -l < "$WORK/demo.descopes.jsonl" | tr -d ' ')" = 2 ]
    run "$LEDGER" state --state "$STATE"
    [ "$(jq -r '.accepted_ids[0]' <<< "$output")" = descope.api ]
    "$LEDGER" review --state "$STATE" --id descope.api --status rejected --rationale reconsidered --owner reviewer >/dev/null
    run "$LEDGER" state --state "$STATE"
    [ "$(jq -r '.blocking_ids[0]' <<< "$output")" = descope.api ]
}

@test "tampering and truncation are detected" {
    init_ledger; add_descope descope.api obl.api
    "$LEDGER" review --state "$STATE" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    cp "$WORK/demo.descopes.jsonl" "$WORK/saved"
    { jq -cS '.description="tampered"' < <(sed -n '1p' "$WORK/saved"); sed -n '2p' "$WORK/saved"; } > "$WORK/demo.descopes.jsonl"
    run "$LEDGER" state --state "$STATE"
    [ "$status" -ne 0 ]; [[ "$output" == *"hash mismatch"* ]]
    head -n 1 "$WORK/saved" > "$WORK/demo.descopes.jsonl"
    run "$LEDGER" state --state "$STATE"
    [ "$status" -ne 0 ]; [[ "$output" == *"event count does not match"* ]]
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

@test "stateful delivery blocks until accepted and fails on tamper" {
    bin="$WORK/bin"; mkdir -p "$bin"; cp "$SRC/deliver.sh" "$SRC/descope-ledger.sh" "$bin/"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/agent-gate.sh"
    printf '#!/usr/bin/env bash\nprintf '\''{"verdict":"done","reason":"workflow complete"}\\n'\''\n' > "$bin/supervisor.sh"
    chmod +x "$bin/"*.sh
    dstate="$WORK/delivery.json"; printf '{"feature":"delivery"}\n' > "$dstate"
    "$bin/descope-ledger.sh" init --state "$dstate" >/dev/null
    "$bin/descope-ledger.sh" add --state "$dstate" --id descope.api --plan-ref obl.api --description omit --rationale bounded --owner dev >/dev/null
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 1 ]; [[ "$output" == *"descope.api (unreviewed)"* ]]
    "$bin/descope-ledger.sh" review --state "$dstate" --id descope.api --status accepted --rationale approved --owner reviewer >/dev/null
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 0 ]; [ "$output" = "DELIVERY: done — workflow complete" ]
    sed -i 's/bounded/tampered/' "$WORK/delivery.descopes.jsonl"
    run "$bin/deliver.sh" --spec specs/x.md --state "$dstate"
    [ "$status" -eq 1 ]; [[ "$output" == *"hash mismatch"* ]]
}
