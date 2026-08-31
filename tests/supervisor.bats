setup() {
    load 'test_helper/common-setup'
    _common_setup
    SUP="${REPO_ROOT}/blueprint/.repomethod/scripts/supervisor.sh"
    WORK="$(mktemp -d)"
    HELPER="$(mktemp -d)"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.email t@e.x
    git -C "$WORK" config user.name T
    mkdir -p "${WORK}/.repomethod/scripts" "${WORK}/.repomethod/workflows" \
        "${WORK}/.repomethod/evidence" "${WORK}/specs" "${WORK}/src"
    cp "${REPO_ROOT}/blueprint/.repomethod/scripts/"*.sh "${WORK}/.repomethod/scripts/"
    cp "${REPO_ROOT}/blueprint/.repomethod/protected-zones.txt" "${WORK}/.repomethod/"
    chmod +x "${WORK}/.repomethod/scripts/"*.sh
    GRAPH="${WORK}/.repomethod/scripts/workflow-graph.sh"
    echo seed > "${WORK}/README.md"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
    STATE="${WORK}/.repomethod/workflows/demo.json"
    ( cd "$WORK" && "$GRAPH" init --feature demo --mode classic --state "$STATE" \
        --verify-command true >/dev/null )
    cat > "${WORK}/specs/demo.md" <<'EOF'
# Task: demo

## Scope

- `src/**`

## Akzeptanzkriterien

1. it works
EOF
}

teardown() {
    rm -rf -- "$WORK" "$HELPER"
}

drive_to_completed() {
    local ev="${WORK}/.repomethod/evidence"
    printf 'impl\n' > "${ev}/impl.txt"
    "$GRAPH" start --state "$STATE" --node implementation >/dev/null
    "$GRAPH" complete --state "$STATE" --node implementation --output "${ev}/impl.txt" --evidence "${ev}/impl.txt" >/dev/null
    "$GRAPH" verify --state "$STATE" --node verification --evidence "${ev}/verify.log" >/dev/null
    printf 'done\n' > "${ev}/done.txt"
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    "$GRAPH" complete --state "$STATE" --node completion --output "${ev}/done.txt" --evidence "${ev}/done.txt" >/dev/null
}

commit_plan_artifacts() {
    git -C "$WORK" add specs .repomethod/workflows .repomethod/evidence
    git -C "$WORK" commit -q -m "persist plan artifacts" || true
}

@test "the verification command does not run in a login shell" {
    run grep -rn -- 'bash -lc' \
        "${REPO_ROOT}/blueprint/.repomethod/scripts/supervisor.sh" \
        "${REPO_ROOT}/blueprint/.repomethod/scripts/workflow-graph.sh"
    [ "$status" -ne 0 ]
}

@test "check works after the repository is cloned to a new path" {
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "persist workflow state"
    clone="${HELPER}/clone"
    git clone -q "$WORK" "$clone"
    cstate="${clone}/.repomethod/workflows/demo.json"
    # the state was written on another machine: its recorded repo_root is a
    # path that does not exist in this checkout
    jq '.repo_root = "/nonexistent/original/checkout"' "$cstate" > "${cstate}.t"
    mv "${cstate}.t" "$cstate"
    run bash "$SUP" check --state "$cstate"
    [ "$status" -ne 1 ]
    [[ "$output" != *"repo_root from state does not exist"* ]]
}

@test "check on a fresh classic workflow returns continue with runnable implementation" {
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 10 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "continue" ]
    [ "$(jq -r '.next_dispatch.runnable[0]' <<< "$output")" = "implementation" ]
}

@test "check resolves the diff base without --base on a non-main fork branch" {
    # main carries the committed plan artifacts; feature-base adds an unrelated
    # root file; work forks from feature-base with an in-scope change. The
    # workflow is initialized on `work`, so init pins config.base_ref to the
    # fork point and the scope sub-check never diffs against main.
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "persist plan artifacts"
    git -C "$WORK" checkout -q -b feature-base
    echo unrelated > "${WORK}/feature-base-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "feature base file"
    git -C "$WORK" checkout -q -b work
    git -C "$WORK" config branch.work.remote .
    git -C "$WORK" config branch.work.merge refs/heads/feature-base
    echo impl > "${WORK}/src/app.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "in-scope work"
    rm -f "$STATE"
    ( cd "$WORK" && "$GRAPH" init --feature demo --mode classic --state "$STATE" \
        --verify-command true >/dev/null )
    run "$SUP" check --state "$STATE"
    [ "$(jq -r '.scope_ok' <<< "$output")" = "true" ]
}

@test "classic state pins base_ref and all state consumers use it" {
    # A on main ; B (out of scope) on feature-base ; origin/HEAD -> feature-base ;
    # work forks from feature-base with in-scope C. init on work pins base_ref=B.
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "A: plan artifacts"
    git -C "$WORK" checkout -q -b feature-base
    echo out > "${WORK}/feature-base-file.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "B: out of scope"
    b="$(git -C "$WORK" rev-parse HEAD)"
    git -C "$WORK" symbolic-ref refs/remotes/origin/HEAD refs/heads/feature-base
    git -C "$WORK" checkout -q -b work
    echo impl > "${WORK}/src/app.txt"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "C: in scope"
    cat > "${WORK}/specs/work.md" <<'EOF'
# Task: work

## Scope

- `src/**`

## Akzeptanzkriterien

1. it works
EOF
    wstate="${WORK}/.repomethod/workflows/work.json"
    ( cd "$WORK" && "$GRAPH" init --feature work --mode classic --state "$wstate" \
        --verify-command true >/dev/null )
    [ "$(jq -r '.config.base_ref' "$wstate")" = "$b" ]

    # a re-resolution would now pick main (A) and pull B into the diff
    git -C "$WORK" symbolic-ref -d refs/remotes/origin/HEAD

    run "$SUP" check --state "$wstate"
    [ "$(jq -r '.scope_ok' <<< "$output")" = "true" ]

    # verify-scope agrees when handed the same --state
    run bash -c "cd '$WORK' && '${WORK}/.repomethod/scripts/verify-scope.sh' --spec specs/work.md --state '$wstate' --repo ."
    [ "$status" -eq 0 ]
    [[ "$output" != *"feature-base-file.txt"* ]]
}

@test "supervisor falls back for a legacy state without base_ref" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    commit_plan_artifacts
    # legacy state written before config.base_ref existed
    jq 'del(.config.base_ref)' "$STATE" > "${STATE}.t" && mv "${STATE}.t" "$STATE"
    git -C "$WORK" add -A && git -C "$WORK" commit -q -m "legacy state without base_ref"
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    [ "$(jq -r '.scope_ok' <<< "$output")" = "true" ]
}

@test "check returns done once the workflow is completed with a clean handoff" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    commit_plan_artifacts
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    [ "$(jq -r '.scope_ok' <<< "$output")" = "true" ]
}

@test "check returns evidence-ignored when a plan artifact is gitignored" {
    printf '*.log\n' > "${WORK}/.gitignore"
    git -C "$WORK" add .gitignore && git -C "$WORK" commit -q -m "ignore logs"
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    # commit the spec, workflow state and handoff, but NOT the (ignored) evidence
    git -C "$WORK" reset -q -- .repomethod/evidence 2>/dev/null || true
    git -C "$WORK" add specs .repomethod/workflows "${STATE%.json}.handoff.json"
    git -C "$WORK" commit -q -m "persist plan artifacts without evidence"

    run "$SUP" check --state "$STATE"
    [ "$status" -eq 4 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "evidence-ignored" ]
    [ "$(jq -r '.verdict' <<< "$output")" != "done" ]
    [[ "$output" == *"EVIDENCE-IGNORED:"* ]]
    [[ "$output" == *".repomethod/evidence/verify.log"* ]]
}

@test "check ignores the evidence of a failed verification node" {
    # a `workflow-graph.sh fail --evidence` artifact is written under a
    # caller-chosen name and never staged; if it lands under a .gitignore rule
    # it must not pin evidence-ignored on every later check.
    printf 'failed-legacy.txt\n' > "${WORK}/.repomethod/evidence/.gitignore"
    git -C "$WORK" add .repomethod/evidence/.gitignore \
        && git -C "$WORK" commit -q -m "ignore the legacy fail artifact"
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    printf 'stack trace\n' > "${WORK}/.repomethod/evidence/failed-legacy.txt"
    jq '.nodes += [{id:"verification-legacy", type:"verification", status:"completed",
        outcome:"failed", attempt:1,
        evidence:["'"${WORK}"'/.repomethod/evidence/failed-legacy.txt"]}]' \
        "$STATE" > "${STATE}.t" && mv "${STATE}.t" "$STATE"
    commit_plan_artifacts

    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    [[ "$output" != *"EVIDENCE-IGNORED"* ]]
}

@test "check still returns done with committed .txt evidence" {
    local ev="${WORK}/.repomethod/evidence"
    printf 'impl\n' > "${ev}/impl.txt"
    "$GRAPH" start --state "$STATE" --node implementation >/dev/null
    "$GRAPH" complete --state "$STATE" --node implementation --output "${ev}/impl.txt" --evidence "${ev}/impl.txt" >/dev/null
    "$GRAPH" verify --state "$STATE" --node verification --evidence "${ev}/verification.txt" >/dev/null
    printf 'done\n' > "${ev}/done.txt"
    "$GRAPH" start --state "$STATE" --node completion >/dev/null
    "$GRAPH" complete --state "$STATE" --node completion --output "${ev}/done.txt" --evidence "${ev}/done.txt" >/dev/null
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    commit_plan_artifacts
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
}

@test "check does not return done while the plan artifacts are uncommitted" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    # spec, workflow state, handoff and evidence are all still untracked
    run "$SUP" check --state "$STATE"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" != "done" ]
    [ "$(jq -r '.plan_persisted' <<< "$output")" = "false" ]
    [[ "$(jq -r '.reason' <<< "$output")" == *"uncommitted"* ]]
}

@test "check returns done once the plan artifacts are committed" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    commit_plan_artifacts
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    [ "$(jq -r '.plan_persisted' <<< "$output")" = "true" ]
}

@test "two consecutive checks on an unchanged completed workflow both return done" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "none" --claim complete >/dev/null
    commit_plan_artifacts
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    # the first check wrote its own sidecar next to the state file; a second
    # check on the still-unchanged tree must not count that sidecar as an
    # uncommitted plan artifact and flip the verdict to continue.
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "done" ]
    [ "$(jq -r '.plan_persisted' <<< "$output")" = "true" ]
}

@test "check does not return done when the workflow is complete but no handoff exists" {
    drive_to_completed
    # no "$GRAPH" handoff call at all
    run "$SUP" check --state "$STATE"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" != "done" ]
    [ "$(jq -r '.handoff' <<< "$output")" = "missing" ]
    [[ "$(jq -r '.reason' <<< "$output")" == *"handoff is missing"* ]]
}

@test "check does not return done on a stale handoff" {
    "$GRAPH" handoff --state "$STATE" --node implementation --changed src/x --next "wire it" >/dev/null
    # backdate the handoff a full second before the state so "stale" does not
    # hinge on drive_to_completed crossing a wall-clock second boundary
    hf="${STATE%.json}.handoff.json"
    jq '.at = "2000-01-01T00:00:00Z"' "$hf" > "${hf}.t" && mv "${hf}.t" "$hf"
    drive_to_completed
    run "$SUP" check --state "$STATE"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" != "done" ]
    [ "$(jq -r '.handoff' <<< "$output")" = "stale" ]
}

@test "check returns needs_human when the handoff claims it" {
    "$GRAPH" handoff --state "$STATE" --node implementation --next "need a decision" \
        --blocker "auth model absent from spec" --claim needs_human >/dev/null
    run "$SUP" check --state "$STATE"
    [ "$status" -eq 3 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "needs_human" ]
}

@test "check returns blocked after K consecutive no-progress checks" {
    jq '.config.verification_command = "false"' "$STATE" > "${STATE}.t" && mv "${STATE}.t" "$STATE"
    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$(jq -r '.verdict' <<< "$output")" = "continue" ]
    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$status" -eq 2 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "blocked" ]
}

@test "a source change between checks resets the idle counter" {
    jq '.config.verification_command = "false"' "$STATE" > "${STATE}.t" && mv "${STATE}.t" "$STATE"
    "$SUP" check --state "$STATE" --max-idle-runs 1 >/dev/null || true
    echo "new work" > "${WORK}/src/feature.py"
    run "$SUP" check --state "$STATE" --max-idle-runs 1
    [ "$(jq -r '.verdict' <<< "$output")" = "continue" ]
    [ "$(jq -r '.progress' <<< "$output")" = "true" ]
}

@test "an open blocker in the handoff prevents a done verdict" {
    drive_to_completed
    "$GRAPH" handoff --state "$STATE" --node completion --changed "src/x" --next "resolve TODO" \
        --blocker "edge case unhandled" >/dev/null
    run "$SUP" check --state "$STATE"
    [ "$(jq -r '.verdict' <<< "$output")" != "done" ]
    [[ "$(jq -r '.reason' <<< "$output")" == *"blocker"* ]]
}

@test "check writes only its sidecar, never the workflow state" {
    before="$(sha256sum "$STATE" | awk '{print $1}')"
    "$SUP" check --state "$STATE" >/dev/null || true
    after="$(sha256sum "$STATE" | awk '{print $1}')"
    [ "$before" = "$after" ]
    [ -f "${WORK}/.repomethod/workflows/demo.supervisor.json" ]
    [ "$(jq -r '.schema_version' "${WORK}/.repomethod/workflows/demo.supervisor.json")" = "1" ]
}

@test "run without --agent-command performs a single check" {
    run "$SUP" run --state "$STATE"
    [ "$status" -eq 10 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "continue" ]
}

@test "run reports a failing agent command" {
    run bash "$SUP" run --state "$STATE" --agent-command "exit 7" --max-runs 1
    [[ "$output" == *"agent command exited 7"* ]]
}

@test "run without --agent-command is exactly one check" {
    run bash "$SUP" run --state "$STATE"
    check_rc="$status"; check_out="$output"
    run bash "$SUP" check --state "$STATE"
    [ "$status" -eq "$check_rc" ]
    [ "$(jq -r '.verdict' <<< "$check_out")" = "$(jq -r '.verdict' <<< "$output")" ]
}

write_stepping_agent() {
    cat > "${HELPER}/agent.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
STATE="$RM_STATE"
G="$(cd "$(dirname "$STATE")/../scripts" && pwd)/workflow-graph.sh"
EV="$(cd "$(dirname "$STATE")/../evidence" && pwd)"
next="$("$G" next --state "$STATE" | head -n1)"
case "$next" in
  implementation)
    printf x > "$EV/impl.txt"
    "$G" start --state "$STATE" --node implementation
    "$G" complete --state "$STATE" --node implementation --output "$EV/impl.txt" --evidence "$EV/impl.txt"
    "$G" verify --state "$STATE" --node verification --evidence "$EV/verify.log"
    "$G" handoff --state "$STATE" --node implementation --changed src/x --next "run completion"
    ;;
  completion)
    printf x > "$EV/done.txt"
    "$G" start --state "$STATE" --node completion
    "$G" complete --state "$STATE" --node completion --output "$EV/done.txt" --evidence "$EV/done.txt"
    "$G" handoff --state "$STATE" --node completion --changed src/x --next none --claim complete
    repo="$(cd "$(dirname "$STATE")/../.." && pwd)"
    git -C "$repo" add specs .repomethod/workflows .repomethod/evidence
    git -C "$repo" commit -q -m "persist plan artifacts" || true
    ;;
esac
EOS
    chmod +x "${HELPER}/agent.sh"
}

@test "run drives the agent command until the workflow completes" {
    write_stepping_agent
    run "$SUP" run --state "$STATE" --agent-command "${HELPER}/agent.sh" --max-runs 6
    [ "$status" -eq 0 ]
    [ "$(jq -r '.status' "$STATE")" = "completed" ]
    [[ "$output" == *'"verdict": "done"'* ]]
}

@test "run blocks and marks the workflow state when the agent makes no progress" {
    jq '.config.verification_command = "false"' "$STATE" > "${STATE}.t" && mv "${STATE}.t" "$STATE"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${HELPER}/noop.sh"
    chmod +x "${HELPER}/noop.sh"
    run "$SUP" run --state "$STATE" --agent-command "${HELPER}/noop.sh" --max-idle-runs 2 --max-runs 20
    [ "$status" -eq 2 ]
    [ "$(jq -r '.status' "$STATE")" = "blocked" ]
    [[ "$output" == *'"verdict": "blocked"'* ]]
}

@test "run escalates immediately on a needs_human handoff" {
    cat > "${HELPER}/escalate.sh" <<'EOS'
#!/usr/bin/env bash
set -e
STATE="$RM_STATE"
G="$(cd "$(dirname "$STATE")/../scripts" && pwd)/workflow-graph.sh"
"$G" handoff --state "$STATE" --node implementation --next "need a product decision" \
  --blocker "spec omits the auth model" --claim needs_human
EOS
    chmod +x "${HELPER}/escalate.sh"
    run "$SUP" run --state "$STATE" --agent-command "${HELPER}/escalate.sh" --max-runs 6
    [ "$status" -eq 3 ]
    [[ "$output" == *'"verdict": "needs_human"'* ]]
}

@test "run stops at --max-runs when no terminal verdict is reached" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "${HELPER}/noop.sh"
    chmod +x "${HELPER}/noop.sh"
    run "$SUP" run --state "$STATE" --agent-command "${HELPER}/noop.sh" --max-idle-runs 99 --max-runs 3
    [ "$status" -eq 1 ]
    [[ "$output" == *"max-runs"* ]]
}

@test "AGENTS.md documents the supervisor loop and the handoff-before-terminate rule" {
    agents="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    run grep -F "supervisor.sh check --state" "$agents"
    [ "$status" -eq 0 ]
    run grep -F "workflow-graph.sh handoff" "$agents"
    [ "$status" -eq 0 ]
    run grep -F "## Supervisor Loop" "$agents"
    [ "$status" -eq 0 ]
}

@test "classic-loop and graph-delivery skills require a handoff before ending a turn" {
    for skill in classic-loop graph-delivery; do
        f="${REPO_ROOT}/blueprint/.repomethod/skills/${skill}/SKILL.md"
        run grep -F "workflow-graph.sh handoff" "$f"
        [ "$status" -eq 0 ]
        run grep -F "supervisor.sh check" "$f"
        [ "$status" -eq 0 ]
    done
}

@test "docs require committing the plan artifacts so the handoff survives a fresh clone" {
    agents="${REPO_ROOT}/blueprint/.repomethod/AGENTS.md"
    run grep -F 'the plan artifacts are committed' "$agents"
    [ "$status" -eq 0 ]
    for skill in classic-loop graph-delivery; do
        f="${REPO_ROOT}/blueprint/.repomethod/skills/${skill}/SKILL.md"
        run grep -F "git add" "$f"
        [ "$status" -eq 0 ]
    done
    run grep -F 'evidence/supervisor-*.log' "${REPO_ROOT}/blueprint/.repomethod/gitignore.template"
    [ "$status" -eq 0 ]
}

@test "check refuses a state whose feature is not a slug" {
    # ../../outside climbs from .repomethod/workflows into ${WORK}/outside, a
    # pre-created dir with a sentinel: red then proves a real external write
    # (a sidecar landing there) rather than an incidental mktemp failure.
    mkdir -p "${WORK}/outside"
    echo sentinel > "${WORK}/outside/keep"
    jq '.feature = "../../outside/item"' "$STATE" > "${STATE}.new"
    mv "${STATE}.new" "$STATE"
    run bash "$SUP" check --state "$STATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid feature slug"* ]]
    [ ! -e "${WORK}/outside/item.supervisor.json" ]
    [ ! -e "${WORK}/outside/item.handoff.json" ]
    [ -f "${WORK}/outside/keep" ]
}

@test "check refuses a state whose directory is a symlink" {
    real="$(mktemp -d)"
    cp "$STATE" "${real}/demo.json"
    ln -s "$real" "${WORK}/.repomethod/linked"
    run bash "$SUP" check --state "${WORK}/.repomethod/linked/demo.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]
    [ ! -e "${real}/demo.supervisor.json" ]
    rm -rf -- "$real"
}

@test "check refuses a state file that is itself a symlink" {
    mv "$STATE" "${WORK}/.repomethod/workflows/real.json"
    ln -s "${WORK}/.repomethod/workflows/real.json" "$STATE"
    run bash "$SUP" check --state "$STATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]
}

@test "check refuses a state under a symlinked ancestor directory" {
    real="$(mktemp -d)"
    mkdir -p "${real}/wf"
    git -C "$real" init -q
    cp "$STATE" "${real}/wf/demo.json"
    ln -s "$real" "${WORK}/tree"
    run bash "$SUP" check --state "${WORK}/tree/wf/demo.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]
    rm -rf -- "$real"
}
