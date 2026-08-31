# Gate & Skill UX Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix six concrete UX defects in the blueprint gate scripts and skills that a 3-way bake-off (quick-mvp / classic / graph, each in its own worktree on a non-`main` base branch) surfaced, plus two small related observations.

**Architecture:** All changes live under `blueprint/.repomethod/` (scripts, skills, one new config file) and `blueprint/AGENTS.md`. Blueprint scripts stay standalone and fork-safe — no shared library; where logic must be identical across scripts it is duplicated byte-for-byte and pinned by identical test vectors (the established `evidence_file_ok` pattern). Only script exit status is trusted. The bilingual (EN/DE) section headers stay. Already-written specs stay valid — no per-spec invariant is added.

**Tech Stack:** Bash 4.4, `git`, `jq`, `awk`, `sed`, `grep` (host `grep` is ugrep → always `grep -E` / `grep -F --`). Tests are `bats` under `tests/`.

**Spec:** the user's "Fix-Prompt für repomethod" (six numbered fixes + two optional observations), reproduced per-task below.

## Global Constraints

- `VERSION` stays `0.0.1`. No tag, no `npm publish`, no push. `release` branch untouched. Do not commit `RELEASE-BACKLOG.md` or the untracked planning `*.md` / `*.txt` files at the repo root.
- Strict TDD per task: write the test first, watch it fail (red), minimal implementation, watch it pass (green). Behaviour-preserving edges use characterization-first (assert current behaviour, stays green across the change).
- **STREAMLINED (user directive, 2026-08-30):** per task, run ONLY the focused bats files for the
  scripts the task touches, plus `shellcheck` on the touched scripts. Do NOT run the full
  `bats tests/*.bats` per task, and do NOT run `npm pack --dry-run` per task (no remaining task changes
  packaging). Commit once the focused tests + focused shellcheck are green. The FULL gate
  (`bats tests/*.bats` — baseline **405 ok / 0 not ok** at `4ee149b`; `shellcheck` over all listed
  scripts; `npm pack --dry-run`) runs ONCE at the end, before the final whole-branch review; any
  breakage that surfaces there is a fix wave, not a per-task gate.
- **Do not edit any file under `blueprint/` while the bats suite is running.** Finish all `blueprint/` edits, then run the full suite; iterate with focused bats files.
- Blueprint scripts source nothing. Any helper a blueprint script needs lives inside that script. A helper needed by N scripts is copied verbatim into all N, and every copy is covered by the identical test-vector list.
- Bash 4.4 entry guard in `lib/common.sh` untouched.
- One commit per task, Conventional-Commit style, trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`. Each task adds its entry under `## [Unreleased]` in `CHANGELOG.md` (`### Fixed` for these — they are defect fixes) in the same commit.
- No new runtime dependencies.
- A new blueprint file (Task 1's `scope-ignore.txt`) is picked up automatically by `blueprint_list_files` / the manifest inventory — no installer change needed. Confirm `tests/npm_cli.bats` / install round-trips stay green.

## Execution order

1 → 2 → 3 → 4 → 5 → 6. Collisions to re-anchor against the working tree:
- `verify-scope.sh`: Task 1 and Task 4.
- `feature-workflow.sh`: Task 2 and Task 3.
- `workflow-graph.sh`: Task 2 and Task 5.
- `supervisor.sh`: Task 4, Task 5, Task 6.
- `verify-acceptance.sh`: Task 6 only.

Line numbers in this plan are current as of HEAD `2fc1000`; re-derive after each task.

---

### Task 1: `scope-ignore.txt` — a "don't evaluate this path" list for verify-scope.sh

**Fix-Prompt #3.** Symptom: a `frontend/agent-ui/node_modules` symlink does not match the `.gitignore` rule `node_modules/` (trailing slash = directories only), so `git ls-files --others` lists it → `VIOLATION`. In a linked worktree `.git/info/exclude` is the shared common-dir (out of reach) and editing `.gitignore` is itself out of scope, so classic + graph had to list `frontend/agent-ui/node_modules` in the spec's `## Scope` with an apologetic comment.

**Files:**
- Create: `blueprint/.repomethod/scope-ignore.txt`
- Modify: `blueprint/.repomethod/scripts/verify-scope.sh` (both the `--quick` branch loop ~60-73 and the full-mode loop ~149-194; the change-set enumeration is `changed_in_repo()` ~40-47 / `changed_raw` at ~59 and ~144)
- Test: `tests/blueprint_verify_scope.bats`

**Interfaces:**
- Produces: `.repomethod/scope-ignore.txt` — one shell glob per line, `#` comments and blanks skipped, matched with the same `case "$file" in $pattern)` bash-glob semantics as `protected-zones.txt` (`*` matches `/`, no globstar, list patterns both root-anchored and nested). A path matching any line is removed from the changed/untracked set **before** scope and protected-zone evaluation. **`protected-zones.txt` wins:** a path that matches a protected zone is still reported as a `VIOLATION` even if it also matches `scope-ignore.txt`.

- [ ] **Step 1 — failing tests** in `tests/blueprint_verify_scope.bats`:
  - "a path listed in scope-ignore.txt never produces a VIOLATION" — fixture repo with a base branch, an untracked `frontend/x/node_modules/pkg/index.js` and a `.repomethod/scope-ignore.txt` containing `**/node_modules` and `**/node_modules/**` (note: bash `case` has no `**`; use `*/node_modules` and `*/node_modules/*` plus `node_modules` / `node_modules/*` — the default file must contain the working patterns, adjust the plan text to whatever actually matches under `case`). Assert `verify-scope.sh --spec … --base …` exits 0 and prints no `VIOLATION` for that path. Also assert the `--quick` mode path.
  - "a protected path in scope-ignore.txt is still a VIOLATION" — put `migrations/*` (a protected zone) into `scope-ignore.txt`, change `migrations/001.sql`, assert `VIOLATION` and exit 1.
- [ ] **Step 2 — run, expect fail** (`scope-ignore.txt` unread today).
- [ ] **Step 3 — implement:** load `${repo}/.repomethod/scope-ignore.txt` into an array the same way `protected_patterns` is loaded; add a helper `is_scope_ignored(file)` mirroring `matches_pattern`; in both the quick loop and the full loop, `continue` early when `is_scope_ignored "$f"` **and** the path does not match any `protected_patterns` entry. Ship `blueprint/.repomethod/scope-ignore.txt` with a header comment (mirror `protected-zones.txt`'s) and the two working `node_modules` globs. Keep the bilingual header comment style.
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/blueprint_verify_scope.bats`.
- [ ] **Step 5 — full gate** (background bats, shellcheck, npm pack).
- [ ] **Step 6 — CHANGELOG `### Fixed`** + commit `fix(verify-scope): honour .repomethod/scope-ignore.txt, protected zones still win`.

**Acceptance:** a path listed in `scope-ignore.txt` never produces a `VIOLATION` (tracked or untracked, in or out of scope). A protected-zone path listed in `scope-ignore.txt` is still reported.

---

### Task 2: `complete` auto-starts a runnable node; baseline-green runs on a dirty tree

Two independent "remove the special-case" fixes in the workflow scripts. **One commit.**

**Fix-Prompt #5** (auto-start). Symptom: `workflow-graph.sh complete --node completion` → `node is not in progress: completion`. `verify` already auto-starts a `pending` node (`workflow-graph.sh` ~856-859); `complete` does not (~808-809 `die "node is not in progress"`). Inconsistent; classic + graph both hit the terse error on a fresh graph.

**Fix-Prompt #6** (baseline on dirty tree). Symptom: `feature-workflow.sh … init` prints `[baseline] working tree not clean — baseline check skipped` (`assert_baseline_green` ~17-20). The check that would catch an already-red gate is skipped exactly in the normal case (dirty tree once work has started), as a quiet info line.

**Files:**
- Modify: `blueprint/.repomethod/scripts/workflow-graph.sh` — the `complete)` case (~799-809, the `[ "$current_status" = "in_progress" ] || die` guard)
- Modify: `blueprint/.repomethod/scripts/feature-workflow.sh` — `assert_baseline_green` (~14-24)
- Test: `tests/workflow_graph.bats`, `tests/workflow_baseline.bats`

**Interfaces:**
- Produces: `complete --node <id>` on a node whose status is `pending` (or the runnable-but-not-started equivalent) auto-starts it first — same rule `verify` uses — writing an `[auto-start] <id>` note to stderr and a start timestamp to the audit/events log, then proceeds. `verification` and `completion`-guard rules are unchanged (a `verification` node still `die`s: "use verify"; the completion-invariant `jq -e` still runs).
- Produces: `assert_baseline_green` runs `verify.sh` regardless of tree cleanliness; it returns early **only** when `.repomethod/verify-command` is absent or comment/blank-only; a non-zero `verify.sh` still `exit 1`s `init`.

- [ ] **Step 1 — failing tests:**
  - `workflow_graph.bats`: "complete auto-starts a pending node" — fresh graph, drive every work node to done, then `workflow-graph.sh complete --node completion --output … --evidence …` **without** a prior `start`; assert exit 0, and that the state/events carry both a start and a complete entry for `completion`, and stderr shows `[auto-start] completion`.
  - `workflow_baseline.bats`: "baseline-green runs on a dirty tree and aborts on red" — configure `.repomethod/verify-command` to `false`, dirty the tree (`echo x > junk`), run `feature-workflow.sh classic init …`, assert exit 1 and the `[baseline] gate is red …` message; then set verify-command to `true`, still dirty, assert init proceeds.
- [ ] **Step 2 — run, expect fail** (complete dies "not in progress"; baseline prints "skipped" and init proceeds on a red gate).
- [ ] **Step 3 — implement:**
  - `complete)` case: before the `in_progress` guard, read the node status; if it is `pending` (mirror `verify`'s exact runnable check), call `start_node "$node"` and `echo "[auto-start] ${node}" >&2`. Then keep the existing `in_progress` assertion (now satisfied) and the rest of the branch unchanged.
  - `assert_baseline_green`: delete the `git status --porcelain` / "working tree not clean — skipped" branch entirely. Keep the `cmd_file` unset/empty early-return and the `verify.sh … || { echo …; exit 1; }`.
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/workflow_graph.bats tests/workflow_baseline.bats`.
- [ ] **Step 5 — full gate.**
- [ ] **Step 6 — CHANGELOG `### Fixed`** (two bullets) + commit `fix(workflow): complete auto-starts a runnable node; baseline check runs on a dirty tree`.

**Acceptance:** on a fresh graph, `complete --node completion` succeeds with no prior `start`, and state/audit carry start + complete times. `feature-workflow.sh <mode> init` on a dirty tree runs the baseline `verify-command` and aborts on exit ≠ 0.

---

### Task 3: verify.sh runs every non-comment line; init warns on uncovered frontend changes

**Fix-Prompt #2.** Symptom: `.repomethod/verify-command` was python-only; `verify.sh` reads only the first non-comment line (`head -n 1`, ~47). `--quick` and the full gate went green without running a single changed line. No path forces frontend coverage — pure author discipline.

**Files:**
- Modify: `blueprint/.repomethod/scripts/verify.sh` (~42-51: `command_line` extraction + the final `eval`)
- Modify: `blueprint/.repomethod/scripts/feature-workflow.sh` — add a one-shot heuristic warning in the `init` paths (after `assert_baseline_green`, in the `classic`/`graph` `init` branches ~55-70)
- Modify: `blueprint/AGENTS.md` — the verify-command description (search for "non-comment line" / "verify-command")
- Modify: `blueprint/.repomethod/scripts/verify.sh` header comment
- Test: `tests/blueprint_verify_command.bats`, `tests/workflow_baseline.bats` (or wherever init is exercised)

**Interfaces:**
- Produces: `verify.sh` evaluates **every** non-comment / non-blank line of `.repomethod/verify-command` in order, each with `(cd "$dir" && eval "$line")`; the first non-zero exit fails the script with that status; all-zero succeeds. The `fail_unconfigured` path (no file, or comments/blanks only) is unchanged. Each line is echoed as `[verify] <line>` before it runs.
- Produces: `feature-workflow.sh … init` prints, once, `WARN: change touches frontend files but verify-command runs no JS check` when `git diff --name-only <base>` (base resolved as today — Task 4 will unify it; for now use the same value `init` already has) contains a path ending `.ts` / `.tsx` / `.js` / `.jsx` **and** no line of `.repomethod/verify-command` contains any of the tokens `pnpm` / `npm` / `npx` / `vitest` / `jest` / `tsc` / `eslint`. Warning only — never changes the exit code.

- [ ] **Step 1 — failing tests:**
  - `blueprint_verify_command.bats`: "verify.sh runs all non-comment lines and fails if any fails" — a two-line `verify-command` (`true` then `false`) → exit non-zero, and both `[verify]` echoes present; a two-line (`true` then `true`) → exit 0.
  - init warning test: python-only `verify-command`, a changed `.tsx` file vs base, assert stderr contains the `WARN:` line and init still exits 0; then add a `pnpm test` line to `verify-command`, assert the warning is gone.
- [ ] **Step 2 — run, expect fail** (`head -n 1` only runs line 1).
- [ ] **Step 3 — implement:** replace the single-line extraction + `eval` with a `while IFS= read -r line` over `grep -Ev '^[[:space:]]*(#|$)'`, `echo "[verify] $line" >&2`, `(cd "$dir" && eval "$line") || exit $?`. Update the header comment and `AGENTS.md` to the "every non-comment line, all must pass" rule. Add the heuristic warning block to the two `init` branches (a small `_warn_frontend_uncovered` shell function local to `feature-workflow.sh`).
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/blueprint_verify_command.bats tests/workflow_baseline.bats tests/blueprint_agent_gate.bats`.
- [ ] **Step 5 — full gate.**
- [ ] **Step 6 — CHANGELOG `### Fixed`** + commit `fix(verify): run every verify-command line; warn on uncovered frontend changes at init`.

**Acceptance:** a 2-line `verify-command` runs both commands and fails if either fails. `init` on a frontend diff with a python-only `verify-command` prints the `WARN:` line and still proceeds.

---

### Task 4: unified `--base` resolution + wrong-base diagnostic

**Fix-Prompt #1.** Symptom: `agent-gate.sh` (`BASE="main"`, ~16), `supervisor.sh` (`base="main"`, ~74), and the skill/AGENTS example commands call `--spec <spec>` with no `--base`. When the fork point is not `main` (stacked / release / worktree branch), `verify-scope.sh` diffs against `main` and reports unrelated files as `VIOLATION` with no hint that the base is wrong. All three bake-off agents had to splice `--base` into the verify-command string by hand.

**Files:**
- Modify: `blueprint/.repomethod/scripts/agent-gate.sh` (`BASE="main"` default + arg loop)
- Modify: `blueprint/.repomethod/scripts/verify-scope.sh` (`base=""` default + `require_base_ref` ~29-32 + the two mode entry points)
- Modify: `blueprint/.repomethod/scripts/supervisor.sh` (`base="main"` ~74 + arg loop)
- Modify: `blueprint/.repomethod/skills/classic-loop/SKILL.md`, `blueprint/.repomethod/skills/graph-delivery/SKILL.md`, `blueprint/.repomethod/AGENTS.md` — remove `--base` from example commands; state that base is auto-resolved and `--base` is an override
- Test: `tests/blueprint_verify_scope.bats`, `tests/blueprint_agent_gate.bats`, `tests/supervisor.bats`

**Interfaces:**
- Produces: a function `resolve_base()` — **duplicated byte-for-byte** into `agent-gate.sh`, `verify-scope.sh`, and `supervisor.sh` (standalone constraint; identical test vectors in each script's bats file). Resolution order, first that yields a commit-ish that is an ancestor of `HEAD`:
  1. an explicit `--base <ref>` value (used verbatim, **not** ancestor-filtered — an explicit wrong base is the user's choice and drives the diagnostic below);
  2. `git merge-base HEAD @{upstream}` (only if `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}` succeeds);
  3. `git merge-base HEAD "$(git symbolic-ref --short refs/remotes/origin/HEAD)"` (only if that ref resolves);
  4. the literal `main` (only if `git rev-parse --verify --quiet main^{commit}` succeeds);
  5. else: error `cannot resolve a base ref — pass --base <ref>` and exit 1.
  The resolved value is what each script already passes on as `--base` / uses in `changed_in_repo`.
- Produces: `verify-scope.sh` — after resolving/receiving `base`, if `git -C "$repo" merge-base --is-ancestor "$base" HEAD` fails, print `base <ref> is not an ancestor of HEAD — wrong --base?` to stderr **before** any `VIOLATION` line (do not abort — still run the check; the diagnostic is the signal).
- No skill or doc mentions `--base` in a happy-path command any more.

- [ ] **Step 1 — failing tests:**
  - `blueprint_verify_scope.bats`: "no --base, base branch is not main → zero false-positive scope violations" — fixture: `git init`, commit on `main`, branch `feature-base` off `main`, commit, branch `work` off `feature-base` with an in-scope change; from `work`, run `verify-scope.sh --spec <s>` (no `--base`); assert exit 0 and no `VIOLATION` (before the fix it diffs vs `main` and flags `feature-base`'s file). Set `origin/HEAD` or `@{upstream}` in the fixture so resolution has something to find, plus the `main` fallback case.
  - "explicit wrong --base prints the diagnostic" — pass `--base <a sibling branch not an ancestor>`, assert stderr contains `is not an ancestor of HEAD`.
  - `blueprint_agent_gate.bats` / `supervisor.bats`: mirror the "no --base on a non-main base" happy path through the aggregate / through `supervisor.sh check`.
- [ ] **Step 2 — run, expect fail** (today defaults to `main`).
- [ ] **Step 3 — implement:** add `resolve_base()` (identical text) to the three scripts; call it once after arg parsing, feeding the result into the existing `BASE` / `base` variable. In `agent-gate.sh` change `BASE="main"` → `BASE=""` and resolve. In `supervisor.sh` same. In `verify-scope.sh` keep `base=""`, resolve when empty, keep `require_base_ref`, add the `merge-base --is-ancestor` diagnostic just before each mode's change-set loop. Strip `--base` from the three docs and add one sentence: "base is auto-resolved from `@{upstream}` / `origin/HEAD` / `main`; pass `--base <ref>` to override".
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/blueprint_verify_scope.bats tests/blueprint_agent_gate.bats tests/supervisor.bats`.
- [ ] **Step 5 — full gate.**
- [ ] **Step 6 — CHANGELOG `### Fixed`** + commit `fix(gate): auto-resolve the diff base; diagnose a non-ancestor --base`.

**Acceptance:** from a branch that forks off a non-`main` branch, `agent-gate.sh --spec <s>` with no `--base` produces zero false-positive scope violations. A deliberately wrong `--base` prints the diagnostic line.

---

### Task 5: evidence survives `.gitignore`; `reverify` regenerates it on a green node

**Fix-Prompt #4.** Symptom: `workflow-graph.sh verify` writes evidence to the caller's `--evidence` path (skill example: `.repomethod/evidence/<feature>-verification.log`, `classic-loop/SKILL.md:23`); a root `.gitignore` `*.log` / `*.tmp.*` rule silently ignores it → `git add .repomethod/evidence` stages nothing → `supervisor.sh check` (which greps `git status --porcelain`, never showing ignored files) reports `plan_persisted: true` / `done` even though a fresh clone would lack the evidence and `verify-evidence.sh` would then fail. `verify` cannot be re-run on a passed node to regenerate under a committable name. Workaround was `git add -f`.

**Files:**
- Modify: `blueprint/.repomethod/skills/classic-loop/SKILL.md`, `blueprint/.repomethod/skills/graph-delivery/SKILL.md` — `.log` → `.txt` in every evidence example path
- Modify: `blueprint/.repomethod/scripts/workflow-graph.sh` — the `verify)` case (~854-880+): after writing `"$evidence"`, `git add -f -- "$evidence"` (best-effort, `2>/dev/null || true`, from `repo_root`); add the `reverify` subcommand
- Modify: `blueprint/.repomethod/scripts/supervisor.sh` — the `plan_dirty` / `plan_persisted` block (~183-190): replace the `git status --porcelain | grep` persistence check with a per-artifact `git check-ignore -q` probe and a distinct non-`done` verdict
- Modify: `blueprint/AGENTS.md` — mention `.txt` evidence and `reverify`
- Test: `tests/workflow_graph.bats`, `tests/supervisor.bats`, `tests/workflow_handoff.bats`

**Interfaces:**
- Produces: skill examples name evidence files `*.txt` (e.g. `.repomethod/evidence/<feature>-verification.txt`).
- Produces: `workflow-graph.sh verify` runs `git -C "$repo_root" add -f -- "$evidence"` after the evidence file is written (before or after the pass/fail state update — pick one, keep it best-effort so a non-repo target still works).
- Produces: `workflow-graph.sh reverify --state <file> --node <verification-id> --evidence <file>` — re-runs the configured `verification_command` for a verification node whose status is already `completed` with `outcome == "passed"`, rewrites `"$evidence"`, `git add -f`s it, and records a `reverified` event (no new fix/verify nodes, no state-machine transition, node stays `completed`/`passed`). Any other node status → `die`. This is not a fix loop.
- Produces: `supervisor.sh` `plan_persisted` — for each required plan artifact path (spec, workflow state, handoff, and each evidence file referenced by a completed verification node), if `git -C "$repo_root" check-ignore -q -- "$path"` succeeds, set a new verdict `EVIDENCE-IGNORED` (non-`done`, its own exit code — reuse `blocked`'s `2` or add a code; keep the JSON `verdict` string `evidence-ignored`) and print `EVIDENCE-IGNORED: <path> is covered by a .gitignore rule — rename it or add a negation`. The existing "committed?" logic (uncommitted tracked plan files → `plan_persisted:false` → not `done`) stays.

- [ ] **Step 1 — failing tests:**
  - `workflow_graph.bats`: "verify commits its evidence even under a matching .gitignore rule" — target repo with `.gitignore` = `*.log`, run `verify` with a `*.log` evidence path, assert `git status --porcelain` shows it staged (`A  …`) — proves `add -f`. Then repeat with the new `.txt` default and assert no `-f` needed.
  - "reverify regenerates evidence on a passed node" — drive a verification node to `passed`, delete its evidence file, `reverify --node … --evidence <new .txt>`, assert exit 0, file recreated + staged, node still `completed`/`passed`, a `reverified` event present, and no new nodes.
  - "reverify refuses a non-passed node" — `die` on `pending` / `in_progress` / `failed`.
  - `supervisor.bats`: "check returns EVIDENCE-IGNORED when a plan artifact is gitignored" — commit spec+state+handoff, evidence file matches a `.gitignore` rule; assert verdict is not `done`, output contains `EVIDENCE-IGNORED: <path>`.
- [ ] **Step 2 — run, expect fail.**
- [ ] **Step 3 — implement** the four pieces above. For `reverify`, factor the shared "run verification_command into $evidence, derive repo_root from the state file" body out of the `verify)` case into a local function both cases call (still one script, allowed). Keep the `verify)` fix-loop transitions only in `verify)`.
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/workflow_graph.bats tests/supervisor.bats tests/workflow_handoff.bats tests/blueprint_verify_evidence.bats`.
- [ ] **Step 5 — full gate.**
- [ ] **Step 6 — CHANGELOG `### Fixed`** + commit `fix(workflow): keep evidence out of .gitignore's reach; add reverify; supervisor flags ignored artifacts`.

**Acceptance:** `verify` produces a non-ignored, committed evidence file by default. `supervisor.sh check` prints `EVIDENCE-IGNORED` (not `done`) when a plan artifact is gitignored. `reverify` works on a green verification node without faking a fix loop.

---

### Task 6: strict-token search skips planning artifacts; supervisor skips its own sidecar

Two small observations from the bake-off (not part of the six, folded in per the user's "der alles umfasst").

**(a)** `verify-acceptance.sh` strict-token search greps the token against **every** file under `.repomethod/evidence/` — so it also matches the agent's own `plan.md` / spec if that was dropped there, giving a false pass. Restrict to real test-report artifacts.

**(b)** `supervisor.sh` `plan_persisted` already excludes `.repomethod/evidence/supervisor-*` but not its own `<feature>.supervisor.json` sidecar → a second consecutive `check` can flip to `continue` because the sidecar it just wrote is now an uncommitted `.repomethod/` file. (Verify against the current `plan_dirty` grep — the sidecar lives next to the state file, path `${state_dir}/${feature}.supervisor.json`, which may or may not be under a `grep`ed prefix; only fix if the repro is real.)

**Files:**
- Modify: `blueprint/.repomethod/scripts/verify-acceptance.sh` — the `*)` test-id branch `find .repomethod/evidence -type f` (~205-211)
- Modify: `blueprint/.repomethod/scripts/supervisor.sh` — the `plan_dirty` grep chain (~184-186)
- Test: `tests/blueprint_verify_acceptance.bats`, `tests/supervisor.bats`

**Interfaces:**
- Produces (a): the test-id `find` excludes files whose basename is a known planning/spec artifact — `plan.md`, `spec.md`, `task_plan.md`, `findings.md`, `progress.md` — via `-not -name`. Evidence directories legitimately holding test output are unaffected. Keep `evidence_tree_ok` (from the earlier fix wave) unchanged.
- Produces (b): the `plan_dirty` grep also `grep -vF`s `.supervisor.json` (and `.dispatch.md`, already git-ignored per the header comment but harmless to exclude), so the supervisor's own sidecars never count against `plan_persisted`.

- [ ] **Step 1 — failing tests:**
  - `blueprint_verify_acceptance.bats`: "a strict test-id token in plan.md does not satisfy the check" — put the token only in `.repomethod/evidence/plan.md`, assert `STRICT-MISSING` (not a pass).
  - `supervisor.bats`: "two consecutive checks on an unchanged completed workflow both return done" — run `check` twice, assert the second is still `done` (today it can flip to `continue`). If this does not reproduce, record why in the task report and drop (b).
- [ ] **Step 2 — run, expect fail** (or, for (b), record non-repro).
- [ ] **Step 3 — implement** (a) always; (b) only if step 1 reproduced it.
- [ ] **Step 4 — run, expect pass.** Focused: `bats tests/blueprint_verify_acceptance.bats tests/supervisor.bats`.
- [ ] **Step 5 — full gate.**
- [ ] **Step 6 — CHANGELOG `### Fixed`** + commit `fix(verify-acceptance): ignore planning artifacts in the test-id search; supervisor skips its own sidecar`.

**Acceptance:** a strict test-id present only in `plan.md` yields `STRICT-MISSING`. Two consecutive `supervisor.sh check` runs on an unchanged completed workflow both return `done` (or (b) is documented as non-repro and skipped).

---

## Self-review

- **Spec coverage:** Fix-Prompt #1 → Task 4. #2 → Task 3. #3 → Task 1. #4 → Task 5. #5 → Task 2. #6 → Task 2. Optional (a)/(b) → Task 6. All covered.
- **Placeholder scan:** Task 1 step 1 flags that `**` is not valid in bash `case` — the implementer must use the working `*/node_modules` forms and put those in the shipped file; this is an explicit instruction, not a placeholder. Task 6(b) is conditional on reproduction, with a defined fallback (document + drop). No "TBD"/"add error handling"/"similar to Task N".
- **Type/name consistency:** `resolve_base()` (Task 4) — same name, byte-identical body in three scripts. `is_scope_ignored` (Task 1), `_warn_frontend_uncovered` (Task 3), `reverify` subcommand + shared verify-body function (Task 5) — each defined where used, no cross-task references. Verdict string `evidence-ignored` / label `EVIDENCE-IGNORED` used consistently in Task 5.
- **Constraint check:** all edits under `blueprint/` → finish before the full bats run each task; standalone scripts → `resolve_base` duplicated with identical vectors; only exit status trusted (diagnostics go to stderr, never change exit codes except Task 5's new verdict code); bilingual headers untouched; existing specs stay valid (no new per-spec invariant — Task 3 adds a repo-level heuristic warning, not a gate).
