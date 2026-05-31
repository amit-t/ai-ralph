# Row 6 — Workspace-mode PR creation (ai-ralph)

**Status:** not started · **Repository:** `ai-ralph` (this clone) · **Owner:** new Claude session opened here

## TL;DR

Workspace continuous mode in ai-ralph **never pushes branches and never opens PRs**. Workers commit locally, mark tasks done, and exit — leaving N orphan local branches per dispatch that the user must push and PR by hand. This is the last unaddressed item in a multi-row series of `.ralph`/dispatch fixes; Rows 1, 2, 4, 5 already landed. Row 6 adds the missing push + PR step to the workspace executor for all three engines (claude, devin, codex).

---

## 1. Background — what already landed

This work is the upstream completion of a fix series that started from a workbench (`wb-gitlore`) hitting recurring failures. Series so far:

| Row | Repo | What | PRs |
|---|---|---|---|
| 1 | ai-ralph | `.ralph` scaffold guard + helper (`_ralph_dir_is_valid_target`) — stops `rpd.status`/stray runs from littering | inv #36, origin #77 (merged) |
| 2 | ai-workbench | `wb.ralph-enable-check` auto-heals benign empty root stubs | inv #75, origin #57 (merged) |
| 3 | (skipped — premise disproven) | git-boundary idea — turned out irrelevant once Row 1 + Row 2 landed | — |
| 4 | ai-ralph | `lib/parallel_spawn.sh` shell-quotes worker argv (descriptor with `|`/`**`/`;`/`()` no longer mangled by tab zsh) | inv #37, origin #79 (merged) |
| 5 | ai-ralph | Revert Row 1's workspace anchor — it broke `execute_devin_session:598` `${main_dir}/${LOG_DIR}` concat | inv #38, origin #80 (open at time of writing) |
| **6** | **ai-ralph** | **THIS DOC — workspace executor pushes + opens PR** | **TBD** |

Each prior PR included a regression test in `tests/unit/`. Follow the same convention.

---

## 2. The bug

### 2.1 Symptom

Run a workspace-mode continuous dispatch (e.g. via wb-gitlore's `wb.ralph-dispatch --parallel 3 --max-tasks 30 --no-tabs`). Workers execute tasks, commit work to per-task branches (`ralph-devin/<task-id>`, `ralph-claude/<task-id>`, `ralph-codex/<task-id>`), mark the fix_plan rows `[x]`, and exit clean. Then:

- `git -C repos/<repo> ls-remote origin "refs/heads/ralph-*"` → **empty**.
- `gh pr list --repo <owner>/<repo>` → **empty**.
- `git -C repos/<repo> branch | grep ralph-` → **N local branches**, never pushed.
- `repos/.ralph/logs/ralph.log` shows `[SUCCESS] [continuous] task complete (rc=0)` but **no** `git push`, **no** `gh pr create` lines anywhere.

Verified live in wb-gitlore on 2026-05-30: 8/8 succeeded, 8 local branches, 0 remote branches, 0 PRs.

### 2.2 Root cause

The workspace executor is a **thin wrapper that only marks completion**. It does not call into `lib/pr_manager.sh`.

**`devin/ralph_loop_devin.sh:1789-1806`** (`_continuous_workspace_executor`):

```bash
_continuous_workspace_executor() {
    local descriptor="$1"
    local repo_name task_id line_num task_desc
    repo_name=$(echo "$descriptor" | cut -d'|' -f1)
    task_id=$(echo "$descriptor" | cut -d'|' -f2)
    line_num=$(echo "$descriptor" | cut -d'|' -f3)
    task_desc=$(echo "$descriptor" | cut -d'|' -f4)

    local fix_plan="${RALPH_DIR}/fix_plan.md"

    if _workspace_execute_task "$repo_name" "$task_desc" "."; then
        mark_workspace_task_complete "$fix_plan" "$line_num"
        return 0
    else
        revert_workspace_task "$fix_plan" "$line_num"
        return 1
    fi
}
```

That's it. `_workspace_execute_task` runs the engine inside a worktree (worktree_manager handles isolation), commits the diff, and returns rc. Then the executor only ticks the fix_plan box. **No push. No PR.**

Compare the single-repo path (same file, lines 1885+), whose own comment says:

```bash
# _singlerepo_execute_task — single-repo executor wrapping execute_devin_session
# with worktree isolation, change detection, and PR creation.
```

— that one *does* call `pr_manager.sh`'s flow. The workspace equivalent never got the PR-creation step.

Same gap exists in:
- `ralph_loop.sh` (claude engine) — find the `_continuous_workspace_executor` definition there too.
- `codex/ralph_loop_codex.sh` (codex engine) — same.

### 2.3 Why this matters

- Every workspace dispatch produces orphan work. User must manually `git push -u origin <branch>` and `gh pr create` per task. 8 tasks → 16 manual commands. Doesn't scale.
- Tab-mode workspace dispatch has the same gap (both `_continuous_workspace_executor` paths use the same function).
- Workers DO commit, so the work is real — but it sits on local branches that nobody reviews/merges until the user notices and manually pushes.

---

## 3. Goal

After a workspace task succeeds and is committed to its per-task branch, the executor should:

1. **Push** the branch to the repo's origin (`git push origin <branch> --set-upstream`).
2. **Open a PR** against `PR_BASE_BRANCH` (from `.ralphrc`, default `main`) using `gh pr create`.
3. **Honor existing PR config** the same way `_singlerepo_execute_task` does:
   - `PR_ENABLED=false` → skip push + PR entirely, just mark complete.
   - `PR_DRAFT=true` → open as draft.
   - `PR_BASE_BRANCH` → target branch.
   - `MAX_QG_RETRIES` → quality-gate retry budget (already handled by worktree_manager).
4. **Don't fail the task on PR-creation failure.** The work is committed; if push or `gh pr create` errors, log warn + mark task complete anyway (so retry logic doesn't try the same task again). Surface the failure clearly so the user can intervene.
5. **Apply uniformly** to all three engines (claude, devin, codex) so behavior is consistent regardless of which engine the workspace runs.

---

## 4. Implementation plan

### 4.1 Setup

1. **Sync remotes** (per saved dual-remote workflow):
   ```bash
   git fetch --all --prune --no-tags
   ```
   Confirm `local main`, `origin/main`, `inv/main` heads. Note any divergence (origin/inv release-please diverge intentionally — **never force-align**).

2. **Branch off the freshest base.** Usually `inv/main` is upstream-of-record (workbench installer points to Invenco). Verify which is fresher:
   ```bash
   git rev-list --left-right --count origin/main...inv/main
   ```
   Base your working branch off whichever has the latest content:
   ```bash
   git checkout -b fix/workspace-pr-creation inv/main
   ```

### 4.2 Code changes

**Three files, same logical change in each.**

For each engine loop's `_continuous_workspace_executor`, insert the push + PR step between `_workspace_execute_task` returning success and `mark_workspace_task_complete`. The exact wiring depends on what `_workspace_execute_task` exposes — it currently handles the worktree internally but doesn't return the branch name. You'll need to either:

**Option A — extend `_workspace_execute_task` to expose branch name.**
Have it set a global `_WS_LAST_BRANCH` (or take an out-var by reference) so the executor knows which branch to push. Lower diff in the executor, but couples the helper.

**Option B — derive branch name from descriptor convention.**
Workers branch as `ralph-<engine>/<task-id>` (predictable). Compute the branch name in the executor from `$task_id` and `$RALPH_ENGINE`:
```bash
local branch_name="ralph-${RALPH_ENGINE}/${task_id}"
```
Then call into pr_manager with that name. Doesn't require touching `_workspace_execute_task`. Less coupling, more brittle if the worker ever renames.

**Recommendation:** Option B with a fallback. Compute the expected name; if it doesn't exist as a ref in the per-repo working tree, log warn and skip PR (don't crash). This keeps the change additive.

**Skeleton (devin shown; mirror to claude + codex):**

```bash
_continuous_workspace_executor() {
    local descriptor="$1"
    local repo_name task_id line_num task_desc
    repo_name=$(echo "$descriptor" | cut -d'|' -f1)
    task_id=$(echo "$descriptor" | cut -d'|' -f2)
    line_num=$(echo "$descriptor" | cut -d'|' -f3)
    task_desc=$(echo "$descriptor" | cut -d'|' -f4)

    local fix_plan="${RALPH_DIR}/fix_plan.md"

    if _workspace_execute_task "$repo_name" "$task_desc" "."; then
        # NEW: push + PR before marking complete. Push failure does NOT
        # block completion — work is committed; user can salvage manually.
        _workspace_push_and_pr "$repo_name" "$task_id" "$task_desc" || \
            log_status "WARN" "[continuous] task ${repo_name}/${task_id} completed but push/PR failed; branch left local"
        mark_workspace_task_complete "$fix_plan" "$line_num"
        return 0
    else
        revert_workspace_task "$fix_plan" "$line_num"
        return 1
    fi
}
```

And the helper (define once per loop file, or factor into a lib if claude/devin/codex versions are identical):

```bash
# Push the per-task branch and open a PR against PR_BASE_BRANCH. Honors
# PR_ENABLED=false. Returns 0 on success or graceful skip; non-zero on push
# or gh failure (caller logs but does not block task completion).
_workspace_push_and_pr() {
    local repo_name="$1"
    local task_id="$2"
    local task_desc="$3"

    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        log_status "INFO" "PR_ENABLED=false — skipping push + PR for ${repo_name}/${task_id}"
        return 0
    fi

    local repo_dir="$(pwd)/${repo_name}"   # workspace orchestrator CWD = repos/
    local branch_name="ralph-${RALPH_ENGINE}/${task_id}"

    # Branch must exist on the per-repo clone; the worker (in a worktree)
    # created and committed to it before exiting.
    if ! git -C "$repo_dir" rev-parse --verify --quiet "$branch_name" >/dev/null; then
        log_status "WARN" "branch '$branch_name' not found in $repo_dir; skipping PR"
        return 1
    fi

    log_status "INFO" "Pushing $branch_name to origin..."
    if ! git -C "$repo_dir" push -u origin "$branch_name" 2>&1 | tee -a "$LOG_DIR/ralph.log"; then
        log_status "ERROR" "git push failed for $branch_name"
        return 1
    fi

    local base="${PR_BASE_BRANCH:-main}"
    local pr_args=(--base "$base" --head "$branch_name" --title "$task_desc")
    [[ "${PR_DRAFT:-false}" == "true" ]] && pr_args+=(--draft)
    pr_args+=(--body "Authored by ralph-${RALPH_ENGINE} (workspace continuous mode). Task: ${task_id}.")

    log_status "INFO" "Opening PR for $branch_name (base=$base)..."
    local pr_url
    if pr_url=$(gh -R "$(git -C "$repo_dir" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+)\.git$#\1#')" \
                pr create "${pr_args[@]}" 2>&1); then
        log_status "SUCCESS" "PR opened: $pr_url"
        return 0
    else
        log_status "ERROR" "gh pr create failed: $pr_url"
        return 1
    fi
}
```

**Notes on the skeleton above (read carefully, don't copy-paste blindly):**

- `RALPH_ENGINE` is set near the top of each loop (line 42 in devin, similar in claude/codex).
- `pwd` in the workspace orchestrator is the workspace root (`repos/` from the workbench dispatcher's perspective). Each per-repo clone lives at `$(pwd)/<repo_name>`.
- The `gh -R <owner>/<repo>` form lets gh target the right repo when CWD isn't inside the per-repo clone.
- Title comes from `task_desc` (already trimmed of `[ ]`/`[~]`). Consider truncating if it's > 200 chars (some GH titles cap).
- Body wording is your call — keep it short.

### 4.3 Replicate to claude + codex loops

`ralph_loop.sh` (claude) and `codex/ralph_loop_codex.sh` have nearly identical `_continuous_workspace_executor` definitions. The same insertion + helper applies. The only per-engine differences:

- `RALPH_ENGINE` value (`"claude"` / `"devin"` / `"codex"`).
- Branch name prefix (`ralph-claude/...` / `ralph-devin/...` / `ralph-codex/...`).

The helper above uses `$RALPH_ENGINE` so it works unmodified in all three.

### 4.4 Worker side — leave alone (probably)

The workers create the branch inside a worktree and commit. They already work correctly — the gap is purely on the **orchestrator** side that calls the executor. Don't touch worktree_manager or the worker dispatch path. Verify by inspection that after `_workspace_execute_task` returns 0, the per-repo clone has a new branch at `ralph-<engine>/<task_id>` with the worker's commit.

If the worker's worktree cleanup deletes the branch reference before the executor runs `_workspace_push_and_pr`, you'll have to either (a) push from within the worktree before cleanup, or (b) ensure the worktree commits land on a regular ref in the per-repo clone (not just the worktree's HEAD). Inspect `lib/worktree_manager.sh` or `devin/lib/worktree_manager.sh` to confirm the commit lands on a regular branch. If it doesn't, that's an additional fix.

---

## 5. Tests

Add `tests/unit/test_workspace_pr_creation.bats`. Mirror the structure of `tests/unit/test_ralph_dir_scaffold_guard.bats` (load helper, override setup with empty temp dir, run engine binary with controlled env).

**Required assertions:**

1. **PR_ENABLED=false → skip cleanly.** Set `PR_ENABLED=false` in `.ralphrc`, run a workspace executor with a mock branch, assert no push attempt, exit 0.

2. **Mock branch present → push + PR called.** Stub `git push` and `gh` on PATH (mock binaries that record argv to a file). Run the executor. Assert the stub recorded a `push origin ralph-<engine>/<task_id>` and a `gh pr create --base main --head ralph-<engine>/<task_id> --title ...`.

3. **Missing branch → warn + return non-zero, but executor still marks complete.** No branch exists for the task; assert helper returns 1, but the outer executor still ticks the fix_plan row.

4. **PR_DRAFT=true → --draft passed.**

5. **One test per engine** (claude/devin/codex) for #2 to confirm the per-engine wiring.

Use the same mock pattern from `tests/unit/test_parallel_spawn_quoting.bats` (stub binaries that record argv via `printf '%s\n' "$@" > $OUT`).

**CI gates the test must pass:**

- `bash -n` on all changed `.sh` files.
- `shellcheck -S warning -x` (per `.github/workflows/lint.yml`). No new warnings beyond pre-existing SC2034 on `RALPH_ENGINE` / `bead_id`.
- Full unit suite (`./node_modules/.bin/bats tests/unit/`). Baseline before changes ≥ 1337 tests; your additions raise it. **Zero `not ok`** required.

---

## 6. Multi-remote PR workflow (mandatory)

ai-ralph is dual-homed. PRs go to **both** remotes. From the saved workflow memory:

| Remote | URL | gh account | SSH host |
|---|---|---|---|
| `origin` | `amit-t/ai-ralph` | `amit-t` (active by default) | `github.com-at` |
| `inv` | `Invenco-Cloud-Systems-ICS/ai-ralph` | `amit-tiwari_vnt` | `github.com-atv` |

Sequence:

1. Branch off `inv/main` → implement → test → commit on `fix/workspace-pr-creation`.
2. `git push -u inv fix/workspace-pr-creation` (SSH host `github.com-atv` handles auth — no gh switch needed for git push).
3. **Switch gh account for the inv PR:**
   ```bash
   gh auth switch -u amit-tiwari_vnt
   gh pr create --repo Invenco-Cloud-Systems-ICS/ai-ralph --base main \
       --head fix/workspace-pr-creation --title "..." --body "..."
   gh auth switch -u amit-t
   ```
4. Cherry-pick onto origin/main:
   ```bash
   git checkout -b fix/workspace-pr-creation-origin origin/main
   git cherry-pick <fix-commit-sha>
   git push -u origin HEAD:fix/workspace-pr-creation
   gh pr create --repo amit-t/ai-ralph --base main \
       --head fix/workspace-pr-creation --title "..." --body "..."
   ```
5. **Never force-align** divergent tags or release-please histories between origin and inv. Fetch with `--no-tags` if a tag clobber blocks a fetch (`v2.2.0` and similar diverge intentionally).

---

## 7. Definition of done

- [ ] All three loops have `_continuous_workspace_executor` calling `_workspace_push_and_pr` after success and before `mark_workspace_task_complete`.
- [ ] Helper `_workspace_push_and_pr` defined (per-loop or factored into `lib/`).
- [ ] `PR_ENABLED=false` short-circuits (verified by test).
- [ ] `bash -n` clean on all 3 loops + any lib changes.
- [ ] `shellcheck -S warning -x` clean (no new warnings).
- [ ] New `tests/unit/test_workspace_pr_creation.bats` added, all tests pass.
- [ ] Full unit suite green (no regressions).
- [ ] Two PRs open: one against `Invenco-Cloud-Systems-ICS/ai-ralph`, one against `amit-t/ai-ralph` — both with the same fix.
- [ ] PR bodies cross-reference each other and link back to this doc.
- [ ] Commit message follows Conventional Commits (`fix(loop): ...` or `feat(loop): ...`) — release-please reads these.

## 8. Out of scope (don't do here)

- Tab-mode workspace PR creation is a separate path (the tab worker spawns `ralph-* --workspace-task ...` and runs the per-task work in the tab; PR creation in that flow would live in the worker's dispatch in `ralph_loop_*.sh` near `run_workspace_task_worker`). If you fix only the in-process executor (recommended for Row 6), document tab-mode as a follow-up. The wb-gitlore workflow uses `--no-tabs` for visibility, so the in-process executor is the primary path.
- The `init_session_tracking: command not found` / `update_session_last_used: command not found` warnings in devin/codex are a separate missing-source issue (the functions are only defined in `ralph_loop.sh`'s session_continuity path). Out of scope.

---

## 9. Verification once merged

After the new Claude session ships Row 6 to both remotes and the PRs merge:

1. Owner of wb-gitlore (the parent of this work) will run `rp.install` from the freshly-pulled ai-ralph clone.
2. They'll run `wb.ralph-dispatch --parallel 3 --max-tasks 30 --no-tabs` against gitlore.
3. Expected: every successful task auto-pushes its branch and opens a PR on `amit-t/gitlore`. No more bulk-push step.

If that fails, surface it back to that wb-gitlore session.

---

## 10. Pointers (read these before you start)

- This file. Re-read fully.
- `devin/ralph_loop_devin.sh` line 1789 (`_continuous_workspace_executor`) and line 1885 (`_singlerepo_execute_task` for comparison).
- `ralph_loop.sh` and `codex/ralph_loop_codex.sh` — same two functions.
- `lib/pr_manager.sh` line 292+ (`create_pr` implementation, the model behavior).
- `lib/worktree_manager.sh` + `devin/lib/worktree_manager.sh` — to confirm where the worker's commit lands.
- `tests/unit/test_parallel_spawn_quoting.bats` — pattern for mocking binaries on PATH.
- `tests/unit/test_ralph_dir_scaffold_guard.bats` — pattern for engine-binary tests.

Good luck. Keep the change minimal and additive; the helper is the right factoring.
