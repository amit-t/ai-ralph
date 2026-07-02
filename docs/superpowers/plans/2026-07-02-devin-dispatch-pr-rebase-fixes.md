# Devin Dispatch PR/Rebase Failure Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three verified defects in Ralph's PR workflow: (1) gh error text mistaken for an existing PR URL (skips PR creation, then label-add fails), (2) rebase failures misreported as "conflict" with all stderr suppressed (dirty tracked `.ralph/**` artifacts block rebase silently), (3) continuous mode marks fix-plan tasks `[x]` even when push/PR/rebase failed.

**Architecture:** All PR/rebase logic lives in `lib/pr_manager.sh` (engine-agnostic, sourced by all three engine loops). Continuous-mode completion marking lives in per-engine executor functions in `ralph_loop.sh`, `devin/ralph_loop_devin.sh`, `codex/ralph_loop_codex.sh` (structurally identical). Fixes: rc-checked PR lookup helper; rewritten `_pr_rebase_onto_base` that distinguishes DIRTY / CONFLICT / FAILED, snapshots-and-restores dirty tracked `.ralph/**` files, logs real git stderr, and exposes an optional `worktree_resolve_rebase_conflicts` hook; executors that only mark `[x]` when push+PR state is known good.

**Tech Stack:** Bash (existing files stay bash — do NOT convert to zsh), bats + plain-bash test harnesses, shellcheck, gh CLI, git.

## Global Constraints

- Never modify the stamped workbench (`~/.per.ralph/`, `workbench-bio-exam-admin`) — all fixes land here, installed later via `ralph.upgrade`.
- Existing `.sh` files stay bash (`#!/bin/bash` / `#!/usr/bin/env bash`); zsh preference applies only to brand-new standalone scripts, which this plan does not create.
- Commit messages use Conventional Commits (`fix:` / `feat:` / `test:`) — release-please derives versions from them.
- Line numbers below are as of commit `4540609`; re-anchor with the given grep patterns before editing.
- Run `shellcheck <file>` on every touched `.sh` file; keep existing `# shellcheck disable` comment style.
- Branch off `main`; PR targets `amit-t/ai-ralph` `main` (never upstream `frankbria/ralph-claude-code`).
- `log_status` writes to stderr + log file only (verified `devin/ralph_loop_devin.sh:305-339`), so it is safe inside `$(...)` captures.

## Verified Root Causes (evidence)

1. **Phantom "PR already exists".** `_pr_gh_try` (`lib/pr_manager.sh:70-120`) runs `out=$(gh "$@" 2>&1)` and always prints `$out`. Caller `lib/pr_manager.sh:639` does `existing_pr=$(_pr_gh_try pr view ... 2>/dev/null)` — the trailing `2>/dev/null` is useless (gh's stderr was already merged to stdout inside the helper) — then line 640 tests `[[ -n "$existing_pr" ]]`, ignoring rc. gh's failure text `no pull requests found for branch ...` is non-empty → creation skipped → later `gh pr edit --add-label` (line 682) fails → the observed `[WARN] Could not add 'quality-gates-failed' label to PR`. Same pattern at line 823 (fallback path). Field evidence: branch `ralph-devin/add-a-forbidden-field-hard-gate-test-over-the-loca` pushed, no PR, log claims "PR already exists".
2. **Rebase misreport.** `_pr_rebase_onto_base` (`lib/pr_manager.sh:300`) runs `git rebase ... >/dev/null 2>&1`; any failure → caller logs "conflicted". The auto-commit excludes `.ralph/**` (line 540), and `worktree_run_quality_gates` writes `$workdir/.ralph/.quality_gate_results` (`lib/worktree_manager.sh:607`) *after* that commit — if the target repo tracks `.ralph/` (bio-admin does), the file is a dirty tracked file and `git rebase` refuses to start ("cannot rebase: You have unstaged changes"), which is not a merge conflict. Field evidence: 3 local-only branches abandoned with "conflicted — stopping".
3. **Continuous mode swallows failure.** Workspace executor: `devin/ralph_loop_devin.sh:1833-1835` — `_workspace_push_and_pr ... || log WARN` then `mark_workspace_task_complete` unconditionally. Inner task fn: line 1785 `workspace_repo_commit_and_pr ... || true`, returns 0 always. Single-repo executor: line 1988 `worktree_commit_and_pr ... || true`, returns 0. Identical patterns in `ralph_loop.sh` (3097-3099, 3296-3319) and `codex/ralph_loop_codex.sh` (1875-1877, 2039-2062). Field evidence: `task complete (rc=0)` logged after `[ERROR] Rebase ... conflicted`. Worker pool (`lib/worker_pool.sh:509-527`) already handles executor rc≠0: bounded K-attempt retry, then skip-list — the fix can safely return 1.

Non-continuous ad-hoc path (`devin/ralph_loop_devin.sh:1300-1316`) already handles `pr_result` correctly — no change there.

## File Structure

| File | Change |
|---|---|
| `lib/pr_manager.sh` | New `_pr_lookup_existing_pr`, `_pr_restore_ralph_snapshot`; rewrite `_pr_rebase_onto_base`; rc-checked call sites; label stderr logging; task-state summary line |
| `devin/ralph_loop_devin.sh` | `_workspace_execute_task` propagates PR failure (rc 2); `_continuous_workspace_executor` + `_singlerepo_execute_task` fail-open |
| `ralph_loop.sh` | Same executor changes (claude engine) |
| `codex/ralph_loop_codex.sh` | Same executor changes (codex engine) |
| `tests/test_pr_manager.sh` | Tests for lookup helper, phantom-PR regression, label stderr |
| `tests/unit/test_pr_rebase.bats` | NEW — real-git rebase tests (dirty-ralph, DIRTY, CONFLICT, hook) |
| `tests/unit/test_continuous_pr_completion.bats` | NEW — workspace executor completion semantics, 3 engines |
| `tests/unit/test_singlerepo_executor.bats` | New branch: PR step fails → rc 1 |
| `docs/user-guide/04-advanced-features.md` | Document new semantics + hook |

---

### Task 1: rc-checked PR existence lookup

**Files:**
- Modify: `lib/pr_manager.sh` (helper after `_pr_gh_try`, i.e. after line 120; call sites at 638-641 and 822-825 — anchor: `existing_pr=$(_pr_gh_try pr view`)
- Test: `tests/test_pr_manager.sh` (append before the final summary block at file end)

**Interfaces:**
- Consumes: `_pr_gh_try` (unchanged).
- Produces: `_pr_lookup_existing_pr <branch>` — prints PR URL + returns 0 ONLY when a PR exists; prints nothing + returns 1 otherwise. Used by Task 4's state line (`state_pr`).

- [ ] **Step 1: Write failing tests**

Append to `tests/test_pr_manager.sh` (before any final exit/summary lines):

```bash
# ── _pr_lookup_existing_pr: gh failure text must not count as a PR ───────────
out=$(
    gh() {
        if [[ "$1" == "pr" ]]; then echo 'no pull requests found for branch "b1"' >&2; return 1; fi
        return 0
    }
    _pr_lookup_existing_pr "b1"
)
rc=$?
run_test "lookup: gh error text yields empty stdout" "" "$out"
run_test "lookup: gh error text yields rc 1" "1" "$rc"

out=$(
    gh() {
        if [[ "$1" == "pr" ]]; then echo "https://github.com/o/r/pull/7"; return 0; fi
        return 0
    }
    _pr_lookup_existing_pr "b1"
)
rc=$?
run_test "lookup: real URL passes through" "https://github.com/o/r/pull/7" "$out"
run_test "lookup: real URL yields rc 0" "0" "$rc"

# ── Regression: pr view stderr text does NOT skip pr create ──────────────────
# (was: _pr_gh_try merged gh stderr into stdout; non-empty capture skipped
#  creation, then the quality-gates-failed label edit failed on a missing PR)
WT_DIR_P=$(mktemp -d)
(
    cd "$WT_DIR_P" || exit
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
    echo "source diff for phantom PR path" >> work.txt
)
_WT_CURRENT_PATH="$WT_DIR_P"
_WT_CURRENT_BRANCH="ralph-claude/T-phantom"
_WT_MAIN_DIR="$WT_DIR_P"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
PR_ENABLED="true"
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then
        echo "no pull requests found for branch \"ralph-claude/T-phantom\"" >&2
        return 1
    fi
    if [[ "$1" == "pr" && "$2" == "create" ]]; then
        touch "$WT_DIR_P/.pr_create_called"
        echo "https://github.com/o/r/pull/1"
        return 0
    fi
    return 0
}
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-P" "Phantom PR test" "true" "1"
phantom_rc=$?
run_test "phantom PR: pr create WAS called" "1" \
    "$([[ -f "$WT_DIR_P/.pr_create_called" ]] && echo 1 || echo 0)"
run_test "phantom PR: workflow returns 0" "0" "$phantom_rc"
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR_P"
```

Note: the marker-file pattern (not a variable) is required — `_pr_gh_try` invokes the gh mock inside `$(...)`, so variable writes are lost to the subshell.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_pr_manager.sh`
Expected: `lookup:` tests FAIL (function not defined → empty output but rc 127-ish mismatch on rc tests), `phantom PR: pr create WAS called` FAIL (`expected: '1', got: '0'`).

- [ ] **Step 3: Implement**

Insert after `_pr_gh_try` (after `lib/pr_manager.sh:120`):

```bash
# ── _pr_lookup_existing_pr ────────────────────────────────────────────────────
# Args: $1=branch. Prints the existing PR's URL and returns 0 ONLY when a PR
# exists. _pr_gh_try merges gh's stderr into its stdout, so "no pull requests
# found" error text arrives on stdout — callers must never treat non-empty
# output alone as proof of a PR. Gate on BOTH rc==0 and URL shape.
_pr_lookup_existing_pr() {
    local branch="$1"
    local out
    if out=$(_pr_gh_try pr view "$branch" --json url --jq '.url') \
       && [[ "$out" =~ ^https?:// ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}
```

Replace call site at `lib/pr_manager.sh:638-641` (inside `worktree_commit_and_pr`):

```bash
        local existing_pr
        if existing_pr=$(_pr_lookup_existing_pr "$_WT_CURRENT_BRANCH"); then
            log_status "INFO" "PR already exists for $_WT_CURRENT_BRANCH: $existing_pr. Skipping creation."
        else
```

Replace call site at `lib/pr_manager.sh:822-825` (inside `worktree_fallback_branch_pr`):

```bash
        local existing_pr
        if existing_pr=$(_pr_lookup_existing_pr "$FALLBACK_BRANCH"); then
            log_status "INFO" "PR already exists for $FALLBACK_BRANCH: $existing_pr"
        else
```

(The `if/else` shape replaces the old `[[ -n "$existing_pr" ]]` test; the `else` bodies are unchanged.)

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/test_pr_manager.sh`
Expected: all PASS, including the pre-existing `existing PR skips gh pr create` test (URL mock still short-circuits creation).

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/pr_manager.sh
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "fix(pr): gate PR-exists check on gh exit code and URL shape

gh 'no pull requests found' stderr text was captured as the PR URL,
skipping creation and leaving pushed branches with no PR."
```

---

### Task 2: surface `gh pr edit` stderr on label failure

**Files:**
- Modify: `lib/pr_manager.sh:680-684` and `860-864` (anchor: `--add-label "quality-gates-failed"`)
- Test: `tests/test_pr_manager.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: sets local `state_label` ("applied"/"failed") — Task 4 reads it; if Task 4 is not yet applied, the assignments are harmless locals.

- [ ] **Step 1: Write failing test**

Append to `tests/test_pr_manager.sh`:

```bash
# ── Label-add failure logs gh's stderr ───────────────────────────────────────
WT_DIR_L=$(mktemp -d)
(
    cd "$WT_DIR_L" || exit
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
    echo "source diff for label log path" >> work.txt
)
_WT_CURRENT_PATH="$WT_DIR_L"
_WT_CURRENT_BRANCH="ralph-claude/T-label-log"
_WT_MAIN_DIR="$WT_DIR_L"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
LABEL_LOG_CAPTURE=""
log_status() { LABEL_LOG_CAPTURE+="[$1] $2"$'\n'; }
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then echo "https://github.com/o/r/pull/9"; return 0; fi
    if [[ "$1" == "pr" && "$2" == "edit" ]]; then echo "HTTP 422: label rejected by server" >&2; return 1; fi
    return 0
}
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-L" "Label log test" "false" "1"
run_test "label failure log includes gh stderr" "1" \
    "$([[ "$LABEL_LOG_CAPTURE" == *"HTTP 422: label rejected by server"* ]] && echo 1 || echo 0)"
log_status() { :; }
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR_L"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_pr_manager.sh`
Expected: new test FAIL (old code discards stderr with `2>/dev/null`).

- [ ] **Step 3: Implement**

Replace `lib/pr_manager.sh:680-684`:

```bash
        if [[ "$gate_passed" == "false" ]]; then
            _pr_ensure_label "quality-gates-failed" "d93f0b" "Ralph: quality gates did not pass" || true
            local label_out state_label="applied"
            if ! label_out=$(gh pr edit "$_WT_CURRENT_BRANCH" --add-label "quality-gates-failed" 2>&1); then
                state_label="failed"
                log_status "WARN" "Could not add 'quality-gates-failed' label to PR: $label_out"
            fi
        fi
```

Replace `lib/pr_manager.sh:860-864` (fallback path) identically, with `$FALLBACK_BRANCH` instead of `$_WT_CURRENT_BRANCH`.

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/test_pr_manager.sh` — all PASS.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/pr_manager.sh
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "fix(pr): log gh stderr when quality-gates-failed label add fails"
```

---

### Task 3: rebase — dirty-vs-conflict detection, stderr logging, `.ralph/**` snapshot, resolution hook

**Files:**
- Modify: `lib/pr_manager.sh:288-312` (`_pr_rebase_onto_base`), caller blocks at 572-594 (`worktree_commit_and_pr` Step 1c) and 781-796 (fallback; anchor: `fb_rebase_status`)
- Create: `tests/unit/test_pr_rebase.bats`

**Interfaces:**
- Consumes: `log_status` (stderr-only — safe inside `$(...)`).
- Produces:
  - `_pr_rebase_onto_base <base_branch>` — stdout one of `CHANGED|UNCHANGED|SKIPPED` (rc 0), `DIRTY` (rc 2), `CONFLICT` (rc 1), `FAILED` (rc 3).
  - `_pr_restore_ralph_snapshot <dir>` — restores snapshotted `.ralph/**` contents into cwd, removes `<dir>`; always rc 0.
  - Optional hook: if a function `worktree_resolve_rebase_conflicts <base_branch>` is defined (by an engine loop or `.ralphrc`), it is called once mid-conflict; rc 0 means it resolved and completed the rebase (`git add` + `git rebase --continue`). A hook-resolved rebase moves the tip → status `CHANGED` → the existing caller logic re-runs quality gates (lib/pr_manager.sh:583-592) with no extra code.

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_pr_rebase.bats`:

```bash
#!/usr/bin/env bats
# _pr_rebase_onto_base: dirty-vs-conflict detection, .ralph snapshot/restore,
# stderr surfacing, worktree_resolve_rebase_conflicts hook.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"
    export LOG_DIR="${RALPH_DIR}/logs"
    export RALPH_ENGINE="claude"

    log_status() { echo "[$1] $2" >&2; }
    export -f log_status
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    ORIGIN="${TEST_DIR}/origin.git"
    git init -q --bare "$ORIGIN"
    WORK="${TEST_DIR}/work"
    git clone -q "$ORIGIN" "$WORK" 2>/dev/null
    cd "$WORK"
    git config user.email "t@t"
    git config user.name "T"
    echo base > src.txt
    mkdir -p .ralph
    echo "initial gate state" > .ralph/.quality_gate_results
    git add -A && git commit -qm base
    git branch -M main
    git push -q origin main
    git checkout -qb feature
    echo feature-work > feature.txt
    git add feature.txt && git commit -qm feature
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Advance origin/main from a second clone. $1=file $2=content
advance_main() {
    local other="${TEST_DIR}/other"
    rm -rf "$other"
    git clone -q "$ORIGIN" "$other" 2>/dev/null
    (cd "$other" && git config user.email "t@t" && git config user.name "T" \
        && echo "$2" > "$1" && git add "$1" && git commit -qm advance \
        && git push -q origin main)
}

@test "dirty tracked .ralph file no longer blocks rebase; content restored" {
    advance_main upstream.txt one
    echo "live gate output" > .ralph/.quality_gate_results
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHANGED"* ]]
    grep -q "live gate output" .ralph/.quality_gate_results
    git merge-base --is-ancestor origin/main HEAD
}

@test "dirty tracked file outside .ralph → DIRTY rc 2, named in log, no rebase" {
    advance_main upstream.txt one
    echo "local uncommitted edit" >> src.txt
    tip_before=$(git rev-parse HEAD)
    run _pr_rebase_onto_base main
    [ "$status" -eq 2 ]
    [[ "$output" == *"DIRTY"* ]]
    [[ "$output" == *"src.txt"* ]]
    [ "$(git rev-parse HEAD)" = "$tip_before" ]
}

@test "real conflict → CONFLICT rc 1, files + git stderr logged, rebase aborted" {
    advance_main feature.txt "conflicting upstream content"
    tip_before=$(git rev-parse HEAD)
    run _pr_rebase_onto_base main
    [ "$status" -eq 1 ]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"feature.txt"* ]]
    [ "$(git rev-parse HEAD)" = "$tip_before" ]
    [ -z "$(git status --porcelain)" ]   # abort left the tree clean
}

@test "worktree_resolve_rebase_conflicts hook resolves → rc 0 CHANGED" {
    advance_main feature.txt "conflicting upstream content"
    worktree_resolve_rebase_conflicts() {
        echo "resolved content" > feature.txt
        git add feature.txt
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
    }
    export -f worktree_resolve_rebase_conflicts
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHANGED"* ]]
    git merge-base --is-ancestor origin/main HEAD
}

@test "no remote base ref → SKIPPED unchanged" {
    git remote remove origin
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/unit/test_pr_rebase.bats`
Expected: tests 1-4 FAIL (old code: test 1 returns rc 1 because rebase refuses on the dirty tracked file; 2 lacks DIRTY; 3 lacks CONFLICT text; 4 has no hook). Test 5 PASSES (existing behavior — keeps it locked).

- [ ] **Step 3: Implement**

Replace `_pr_rebase_onto_base` (`lib/pr_manager.sh:288-312`) and add the restore helper directly above it:

```bash
# ── _pr_restore_ralph_snapshot ────────────────────────────────────────────────
# Restore .ralph/** file contents snapshotted before a rebase, then delete the
# snapshot dir. $1="" is a no-op. Always returns 0.
_pr_restore_ralph_snapshot() {
    local snapshot_dir="$1"
    [[ -z "$snapshot_dir" || ! -d "$snapshot_dir" ]] && return 0
    cp -pR "$snapshot_dir/." . 2>/dev/null || true
    rm -rf "$snapshot_dir" 2>/dev/null || true
    return 0
}

# ── _pr_rebase_onto_base ──────────────────────────────────────────────────────
# Rebase the branch checked out in the CURRENT working tree onto origin/BASE.
# Must run from inside the working tree that holds the branch.
# Args: $1=base_branch
# Prints exactly one status word and returns:
#   CHANGED   rc 0  tip moved (caller re-runs quality gates)
#   UNCHANGED rc 0  already up to date
#   SKIPPED   rc 0  no remote base ref
#   DIRTY     rc 2  uncommitted tracked changes outside .ralph/ — NOT a conflict
#   CONFLICT  rc 1  real merge conflict (aborted unless the
#                   worktree_resolve_rebase_conflicts hook resolved it)
#   FAILED    rc 3  rebase failed before producing conflict state
# Dirty tracked .ralph/** files (gate results are written after the
# auto-commit, which excludes .ralph/**, and some target repos track .ralph/)
# are snapshotted, reset to HEAD for the rebase, and restored afterwards.
_pr_rebase_onto_base() {
    local base_branch="$1"

    if ! git fetch origin "$base_branch" >/dev/null 2>&1; then
        echo "SKIPPED"; return 0
    fi
    if ! git rev-parse --verify --quiet "refs/remotes/origin/$base_branch" >/dev/null 2>&1; then
        echo "SKIPPED"; return 0
    fi

    local -a ralph_dirty=() other_dirty=()
    local _f
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        if [[ "$_f" == .ralph/* ]]; then
            ralph_dirty+=("$_f")
        else
            other_dirty+=("$_f")
        fi
    done < <(git diff --name-only HEAD -- 2>/dev/null)

    if [[ ${#other_dirty[@]} -gt 0 ]]; then
        log_status "ERROR" "Rebase blocked by uncommitted tracked changes (not a merge conflict): ${other_dirty[*]}"
        echo "DIRTY"
        return 2
    fi

    local snapshot_dir=""
    if [[ ${#ralph_dirty[@]} -gt 0 ]]; then
        snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/ralph-rebase-snap.XXXXXX")
        for _f in "${ralph_dirty[@]}"; do
            mkdir -p "$snapshot_dir/$(dirname "$_f")"
            cp -p "$_f" "$snapshot_dir/$_f" 2>/dev/null || true
        done
        git checkout -- "${ralph_dirty[@]}" 2>/dev/null || true
        log_status "INFO" "Stashed dirty tracked ralph artifacts for rebase: ${ralph_dirty[*]}"
    fi

    local before after rebase_out rebase_rc=0
    before=$(git rev-parse HEAD 2>/dev/null)
    rebase_out=$(git rebase "origin/$base_branch" 2>&1) || rebase_rc=$?

    if [[ $rebase_rc -ne 0 ]]; then
        local git_dir status_word="FAILED" status_rc=3
        git_dir=$(git rev-parse --git-dir 2>/dev/null)
        log_status "ERROR" "git rebase origin/$base_branch failed (rc=$rebase_rc): $rebase_out"
        if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
            status_word="CONFLICT"; status_rc=1
            log_status "ERROR" "Conflicted files: $(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
            log_status "ERROR" "Worktree status: $(git status --short 2>/dev/null | tr '\n' ';' )"
            if declare -F worktree_resolve_rebase_conflicts >/dev/null 2>&1 \
               && worktree_resolve_rebase_conflicts "$base_branch"; then
                log_status "INFO" "Rebase conflict resolved by worktree_resolve_rebase_conflicts hook"
                status_word=""; status_rc=0
            else
                git rebase --abort >/dev/null 2>&1 || true
            fi
        fi
        if [[ $status_rc -ne 0 ]]; then
            _pr_restore_ralph_snapshot "$snapshot_dir"
            echo "$status_word"
            return $status_rc
        fi
    fi

    after=$(git rev-parse HEAD 2>/dev/null)
    _pr_restore_ralph_snapshot "$snapshot_dir"

    if [[ "$before" != "$after" ]]; then
        echo "CHANGED"
    else
        echo "UNCHANGED"
    fi
    return 0
}
```

Update the worktree caller (`lib/pr_manager.sh:578-582`, inside `worktree_commit_and_pr` Step 1c) — replace the single ERROR line:

```bash
        local rebase_rc=$?
        if [[ $rebase_rc -ne 0 ]]; then
            case "$rebase_status" in
                DIRTY)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH blocked by uncommitted tracked changes (see log above) — not a merge conflict" ;;
                CONFLICT)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH onto origin/$base_branch hit a real merge conflict — conflicted files logged above; resolve in $_WT_CURRENT_PATH and re-run" ;;
                *)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH onto origin/$base_branch failed — git output logged above" ;;
            esac
            return 1
        fi
```

Update the fallback caller (`lib/pr_manager.sh:784-789`, anchor `fb_rebase_rc`) with the same `case` on `$fb_rebase_status` (branch name `$FALLBACK_BRANCH`, no worktree path in the message).

- [ ] **Step 4: Run tests to verify pass**

Run: `bats tests/unit/test_pr_rebase.bats` — 5/5 PASS.
Run: `bash tests/test_pr_manager.sh` — all PASS (call sites still return 1 on rebase failure; existing tests hit SKIPPED because fixtures have no `origin`).

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/pr_manager.sh
git add lib/pr_manager.sh tests/unit/test_pr_rebase.bats
git commit -m "fix(pr): distinguish dirty worktree from rebase conflict, log git stderr

- snapshot/restore dirty tracked .ralph/** so gate-result files no longer
  abort the pre-push rebase as a phantom 'conflict'
- DIRTY/CONFLICT/FAILED statuses with conflicted-file + status logging
- optional worktree_resolve_rebase_conflicts hook; hook-resolved rebases
  re-run quality gates via the existing CHANGED path"
```

---

### Task 4: canonical task-state summary line

**Files:**
- Modify: `lib/pr_manager.sh` — `worktree_commit_and_pr` (lines 509-693) and `worktree_fallback_branch_pr` end
- Test: `tests/test_pr_manager.sh`

**Interfaces:**
- Consumes: locals already present in `worktree_commit_and_pr`: `gate_passed`, `rebase_status` (Task 3), `state_label` (Task 2).
- Produces: `_pr_log_task_state <branch> <gates> <rebase> <pushed> <pr> <label>` → one `log_status INFO` line: `task-state branch=<b> quality_gates=<g> rebase=<r> pushed=<p> pr=<pr> failure_label=<l>`. Grep-able marker: `task-state `.

- [ ] **Step 1: Write failing test**

Append to `tests/test_pr_manager.sh`:

```bash
# ── task-state summary line ──────────────────────────────────────────────────
WT_DIR_S=$(mktemp -d)
(
    cd "$WT_DIR_S" || exit
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "work" > work.txt && git add . && git commit -q -m "initial work"
    echo "source diff for state line path" >> work.txt
)
_WT_CURRENT_PATH="$WT_DIR_S"
_WT_CURRENT_BRANCH="ralph-claude/T-state"
_WT_MAIN_DIR="$WT_DIR_S"
RALPH_PR_PUSH_CAPABLE="true"
RALPH_PR_GH_CAPABLE="true"
STATE_LOG_CAPTURE=""
log_status() { STATE_LOG_CAPTURE+="[$1] $2"$'\n'; }
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then return 1; fi
    if [[ "$1" == "pr" && "$2" == "create" ]]; then echo "https://github.com/o/r/pull/3"; return 0; fi
    return 0
}
git() { [[ "$1" == "push" ]] && return 0; command git "$@"; }
worktree_commit_and_pr "T-S" "State line test" "true" "1"
run_test "task-state line emitted with pr=created" "1" \
    "$([[ "$STATE_LOG_CAPTURE" == *"task-state branch=ralph-claude/T-state quality_gates=true rebase=SKIPPED pushed=true pr=created failure_label=n/a"* ]] && echo 1 || echo 0)"
log_status() { :; }
unset -f gh git
RALPH_PR_PUSH_CAPABLE="false"
RALPH_PR_GH_CAPABLE="false"
rm -rf "$WT_DIR_S"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_pr_manager.sh` — new test FAIL.

- [ ] **Step 3: Implement**

Add helper near the top of `lib/pr_manager.sh` (after `_pr_ensure_label`):

```bash
# ── _pr_log_task_state ────────────────────────────────────────────────────────
# One canonical, grep-able line summarising the PR workflow outcome.
# Args: $1=branch $2=gates $3=rebase $4=pushed $5=pr $6=label
_pr_log_task_state() {
    log_status "INFO" "task-state branch=$1 quality_gates=$2 rebase=$3 pushed=$4 pr=$5 failure_label=$6"
}
```

In `worktree_commit_and_pr`, after the `base_branch` resolution (line ~530), initialize:

```bash
    local state_rebase="SKIPPED" state_pushed="false" state_pr="skipped" state_label="n/a"
```

Wire the states (small edits at existing points):
- Step 1c: after `rebase_status=$(...)`, add `state_rebase="${rebase_status:-FAILED}"`. Inside the failure `case`, before `return 1`, add `_pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"`.
- Step 2: after `log_status "SUCCESS" "Branch pushed..."` succeeds (i.e. after the `push_result` check passes), set `state_pushed="true"`; in the `push_result -ne 0` branch, emit the state line before `return 1`.
- Step 3: set `state_pr="exists"` in the existing-PR branch; `state_pr="created"` after `log_status "SUCCESS" "PR created..."`; `state_pr="failed"` + emit state line before the `return 1` in the create-failure branch; leave `"skipped"` in the zero-commits early return and emit the line there too.
- Step 4 (Task 2's block): remove the `local` from `state_label` there (it is now function-scoped; the block just assigns).
- Immediately before the final `return 0` (line ~692), emit the state line.

In `worktree_fallback_branch_pr`, add the same four locals after its base-branch resolution and emit one state line immediately before its final `return 0`, using `$FALLBACK_BRANCH`.

- [ ] **Step 4: Run tests to verify pass**

Run: `bash tests/test_pr_manager.sh` — all PASS.
Run: `bats tests/unit/test_pr_rebase.bats` — still 5/5 (helper untouched).

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck lib/pr_manager.sh
git add lib/pr_manager.sh tests/test_pr_manager.sh
git commit -m "feat(pr): emit canonical task-state summary line per PR workflow run"
```

---

### Task 5: continuous mode must not mark tasks `[x]` on push/PR failure

**Files:**
- Modify: `devin/ralph_loop_devin.sh` — `_workspace_execute_task` (anchor: `workspace_repo_commit_and_pr "$repo_path"`, line 1785), `_continuous_workspace_executor` (line 1825-1841), `_singlerepo_execute_task` (line 1984-1998)
- Modify: `ralph_loop.sh` — same three functions (anchors identical; `_workspace_push_and_pr` call at 3097, singlerepo PR block at 3296)
- Modify: `codex/ralph_loop_codex.sh` — same three functions (1875, 2039)
- Create: `tests/unit/test_continuous_pr_completion.bats`
- Modify: `tests/unit/test_singlerepo_executor.bats`

**Interfaces:**
- Consumes: `_workspace_push_and_pr` (unchanged, `lib/workspace_continuous_pr.sh`), `mark_workspace_task_complete`, `revert_workspace_task`, worker-pool retry semantics (`lib/worker_pool.sh:509-527`: executor rc≠0 → K bounded retries → skip-list; row stays un-`[x]`d).
- Produces: `_workspace_execute_task` rc contract: `0` = implemented AND inner push/PR ok-or-skipped; `2` = implemented but push/PR failed; `1` = implementation failed. Executor only marks `[x]` when rc 0, or rc 2 salvaged by the safety net.

**Design note (regression guard):** `_workspace_push_and_pr` guesses the branch as `ralph-<engine>/<task_id>`; real branches are description slugs, so on the happy path (rc 0) its failure stays a WARN — never blocks completion. Only when the inner PR step *reported failure* (rc 2) does safety-net failure leave the task open.

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_continuous_pr_completion.bats`:

```bash
#!/usr/bin/env bats
# Continuous workspace executors must not mark a fix-plan row [x] when the
# push/PR pipeline reported failure (rc 2 from _workspace_execute_task) and
# the safety net could not salvage it.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"
    export LOG_DIR="${RALPH_DIR}/logs"
    printf -- '- [~] repo1 task one\n' > "${RALPH_DIR}/fix_plan.md"
    : > "${TEST_DIR}/.calls"
    log_status() { echo "[$1] $2"; }
    export -f log_status
}

teardown() { cd /; rm -rf "$TEST_DIR"; }

_load_fn() {  # $1=script $2=function name
    local fn_text
    fn_text=$(awk "/^$2\\(\\) \\{/,/^}/" "$1")
    [[ -n "$fn_text" ]] || fail "cannot extract $2 from $1"
    eval "$fn_text"
}

_mock_marking() {
    mark_workspace_task_complete() { echo marked >> "${TEST_DIR}/.calls"; }
    revert_workspace_task() { echo reverted >> "${TEST_DIR}/.calls"; }
    export -f mark_workspace_task_complete revert_workspace_task
}

# ── devin ─────────────────────────────────────────────────────────────────────

@test "devin ws executor: exec ok → marked complete even if safety net warns" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 0; }
    _workspace_push_and_pr()  { return 1; }   # branch-name guess miss — must not block
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

@test "devin ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    ! grep -q marked "${TEST_DIR}/.calls"
    grep -q reverted "${TEST_DIR}/.calls"
}

@test "devin ws executor: PR failed (rc 2), safety net salvages → marked complete" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

# ── claude ────────────────────────────────────────────────────────────────────

@test "claude ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    ! grep -q marked "${TEST_DIR}/.calls"
}

@test "claude ws executor: PR failed (rc 2), safety net salvages → marked" {
    _load_fn "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

# ── codex ─────────────────────────────────────────────────────────────────────

@test "codex ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    ! grep -q marked "${TEST_DIR}/.calls"
}

@test "codex ws executor: PR failed (rc 2), safety net salvages → marked" {
    _load_fn "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}
```

Append to `tests/unit/test_singlerepo_executor.bats` (after the Branch-4 tests; the setup's default mocks and gitignored fixture files are reused):

```bash
# =============================================================================
# Branch 5: engine ok + files changed, but PR workflow fails → return 1
# (task left open for the pool's K-retry/skip-list — never a silent [x])
# =============================================================================

@test "claude executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_claude_code worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "devin executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
    execute_devin_session() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_devin_session worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "codex executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"
    execute_codex_session() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_codex_session worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/unit/test_continuous_pr_completion.bats tests/unit/test_singlerepo_executor.bats`
Expected: all "NOT marked"/"PR step fails" tests FAIL (executors currently swallow and return 0/mark complete); pre-existing tests PASS.

- [ ] **Step 3: Implement — devin**

In `devin/ralph_loop_devin.sh` `_workspace_execute_task`, replace lines 1781-1794:

```bash
    # ── PR creation ───────────────────────────────────────────────
    local pr_rc=0
    if [[ "${PR_ENABLED:-true}" != "false" ]]; then
        local gate_flag="true"
        [[ $gate_result -ne 0 ]] && gate_flag="false"
        workspace_repo_commit_and_pr "$repo_path" "$task_id" "$task_desc" "$gate_flag" || pr_rc=$?
    fi

    # ── Cleanup ───────────────────────────────────────────────────
    if [[ "$ws_worktree_active" == "true" ]]; then
        workspace_repo_cleanup "$repo_path"
    fi

    if [[ $pr_rc -ne 0 ]]; then
        echo "Task implemented in [$repo_name] but push/PR failed (rc=$pr_rc)" >&2
        return 2
    fi
    echo "Task completed in [$repo_name]"
    return 0
```

Replace `_continuous_workspace_executor` body lines 1825-1840:

```bash
    _workspace_execute_task "$repo_name" "$task_desc" "."
    local exec_rc=$?
    if [[ $exec_rc -eq 0 ]]; then
        # Row 6 safety net (best effort): the inner helper already confirmed
        # push/PR (or an intentional skip). A safety-net miss here can be a
        # branch-name guess mismatch — warn, never block completion.
        _workspace_push_and_pr "$repo_name" "$task_id" "$task_desc" || \
            log_status "WARN" "[continuous] safety-net push/PR could not verify ${repo_name}/${task_id} — inner PR step succeeded, continuing"
        mark_workspace_task_complete "$fix_plan" "$line_num"
        return 0
    elif [[ $exec_rc -eq 2 ]]; then
        # Implementation succeeded but push/PR failed. Try the safety net;
        # only mark [x] when a push/PR actually succeeded. Otherwise leave
        # the row open (pool retries K times, then skip-lists) so no task is
        # silently [x]'d with no remote branch and no PR.
        if _workspace_push_and_pr "$repo_name" "$task_id" "$task_desc"; then
            mark_workspace_task_complete "$fix_plan" "$line_num"
            return 0
        fi
        log_status "ERROR" "[continuous] ${repo_name}/${task_id} NOT marked complete — work is committed locally; salvage: git -C <repo> push origin <branch> && gh pr create"
        revert_workspace_task "$fix_plan" "$line_num"
        return 1
    else
        revert_workspace_task "$fix_plan" "$line_num"
        return 1
    fi
```

In `_singlerepo_execute_task`, replace lines 1984-1998:

```bash
    local pr_rc=0
    if [[ "${PR_ENABLED:-true}" != "false" ]]; then
        local gate_flag="true"
        [[ $gate_result -ne 0 ]] && gate_flag="false"
        if worktree_is_active; then
            worktree_commit_and_pr "$task_id" "$task_desc" "$gate_flag" "1" || pr_rc=$?
        else
            worktree_fallback_branch_pr "$task_id" "$task_desc" "1" "$gate_flag" || pr_rc=$?
        fi
    fi

    if [[ "$sr_worktree_active" == "true" ]]; then
        worktree_cleanup "false" 2>/dev/null || true
    fi

    if [[ $pr_rc -ne 0 ]]; then
        log_status "ERROR" "[continuous] PR workflow failed for ${task_id} — task left open; branch preserved for manual salvage"
        return 1
    fi
    return 0
```

(Gate failure alone still returns 0 — a gate-fail PR with the label is the designed outcome; only push/PR-pipeline failure blocks completion.)

- [ ] **Step 4: Implement — claude and codex**

Apply the exact same three replacements to `ralph_loop.sh` (anchors: `workspace_repo_commit_and_pr "$repo_path"`; `_workspace_push_and_pr "$repo_name"` at 3097; singlerepo PR block at 3296) and `codex/ralph_loop_codex.sh` (1875, 2039). The function bodies are structurally identical; only surrounding comments differ.

- [ ] **Step 5: Run tests to verify pass**

Run: `bats tests/unit/test_continuous_pr_completion.bats tests/unit/test_singlerepo_executor.bats tests/unit/test_worker_pool.bats tests/unit/test_workspace_pr_creation.bats`
Expected: all PASS (worker-pool and workspace-PR suites guard against regressions in shared plumbing).

- [ ] **Step 6: shellcheck + commit**

```bash
shellcheck devin/ralph_loop_devin.sh ralph_loop.sh codex/ralph_loop_codex.sh
git add devin/ralph_loop_devin.sh ralph_loop.sh codex/ralph_loop_codex.sh \
        tests/unit/test_continuous_pr_completion.bats tests/unit/test_singlerepo_executor.bats
git commit -m "fix(continuous): never mark fix-plan task [x] when push/PR failed

Executor propagates rc 2 (implemented, push/PR failed); safety net gets
one salvage attempt; otherwise the row stays open for K-retry/skip-list
instead of a silent [x] with no remote branch and no PR."
```

---

### Task 6: documentation

**Files:**
- Modify: `docs/user-guide/04-advanced-features.md` (append section)

- [ ] **Step 1: Append section**

```markdown
## PR Workflow Failure Semantics (v2.5+)

Every PR workflow run emits one grep-able summary line to `.ralph/logs/ralph.log`:

    task-state branch=<b> quality_gates=<t|f> rebase=<CHANGED|UNCHANGED|SKIPPED|DIRTY|CONFLICT|FAILED> pushed=<t|f> pr=<created|exists|skipped|failed> failure_label=<applied|failed|n/a>

Behavioral guarantees:

- **PR existence** is decided by `gh pr view`'s exit code plus a URL-shaped
  response — gh error text can no longer masquerade as an existing PR.
- **Pre-push rebase** distinguishes three failures: `DIRTY` (uncommitted
  tracked changes outside `.ralph/` — not a conflict), `CONFLICT` (real merge
  conflict; conflicted files and `git status --short` are logged, then the
  rebase is aborted and the branch preserved), `FAILED` (anything else; raw
  git output is logged). Dirty tracked `.ralph/**` artifacts (e.g.
  `.quality_gate_results` in repos that track `.ralph/`) are snapshotted,
  reset for the rebase, and restored — they never block a rebase.
- **Conflict-resolution hook:** define a function
  `worktree_resolve_rebase_conflicts <base_branch>` (e.g. exported from your
  `.ralphrc`) and Ralph calls it once mid-conflict inside the worktree. Return
  0 after `git add` + `git rebase --continue` to signal resolution; quality
  gates re-run automatically because the tip moved.
- **Continuous mode** only marks a fix-plan row `[x]` when the branch push and
  PR state are confirmed. On push/PR failure the row stays open, the worker
  pool retries up to K times and then skip-lists it, and the log carries a
  salvage command. Quality-gate failure alone still completes the task — the
  PR is created with gate output in the body and the `quality-gates-failed`
  label.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-guide/04-advanced-features.md
git commit -m "docs: PR workflow failure semantics, task-state line, rebase hook"
```

---

### Final verification (whole plan)

- [ ] Run full local suite:

```bash
bash tests/test_pr_manager.sh
bats tests/unit/
```

Expected: 0 failures.

- [ ] Push branch and open PR:

```bash
git push origin <branch>
gh auth switch --user amit-t
gh pr create --repo amit-t/ai-ralph --base main --head <branch> \
  --title "fix: PR-exists false positive, rebase misreport, continuous completion" \
  --body "..."
```

- [ ] After merge: run `ralph.upgrade` in the stamped workbench, then retry the failed dispatches (`workbench-bio-exam-admin`). The three abandoned local branches in `repos/bio-admin` are salvageable manually (push + `gh pr create`) — separate user decision.

## Deferred (explicitly out of scope)

- **AI-driven conflict resolution** (engine invocation inside a conflicted rebase): the hook seam ships in Task 3; wiring Devin/Claude/Codex into it needs its own brainstorm/design (permission mode, timeout, prompt shape, safety around `--permission-mode dangerous`). Follow-up plan.
- Session-end flush paths (`devin/ralph_loop_devin.sh:1062`, `codex/ralph_loop_codex.sh:1103` — `worktree_commit_and_pr "" "" ... || true`): best-effort cleanup by design; unchanged.
- Sequential (non-continuous) workspace paths (`ralph_loop.sh:2864/2866` area): different marking flow, no observed failure; audit separately if it recurs.
- Salvaging the three existing local-only `ralph-devin/*` branches in the workbench: manual user action, not code.
