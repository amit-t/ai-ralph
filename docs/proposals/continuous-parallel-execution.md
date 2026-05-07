# Upstream ralph V2: continuous parallel execution via `--max-tasks M`

Status: draft (design only, not implementation).
Audience: ai-ralph maintainers.
Author: ai-ralph team.
Date: 2026-05-07.

## 1. Problem statement

Today `ralph-devin --workspace --parallel N` (and the same flag on `ralph` and `ralph-codex`) executes a **single batch** of N tasks and exits. The batch picks one unclaimed task per repo, spawns N background workers, waits for all of them via `wait`, marks each `[x]` on success or reverts to `[ ]` on failure, then returns. To run the next batch the user re-invokes the command.

The orchestration is in `_run_workspace_parallel` (`ralph_loop_devin.sh:1537`) which calls `run_workspace_tasks_parallel` (`lib/workspace_manager.sh:595`). The wait loop:

```
for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null
    exit_codes+=($?)
done
```

is a fan-out / wait-all primitive. There is no respawn-on-completion logic.

For a workspace with R repos and a target of M tasks at concurrency N (where `N <= R`), end-to-end wall time is approximately:

```
T_total ≈ ⌈M / N⌉ × T_batch
```

where `T_batch` is dominated by the slowest task in each batch (heterogeneous tasks ⇒ many workers idle while one finishes). Empirically with `N=3` and tasks ranging 5–25 minutes, the wait-all pattern wastes 30–50% of theoretical compute.

The user wants to run M tasks at concurrency N **without re-invoking the command between batches** and **without leaving N−1 workers idle while the slowest finishes**. CPU is the binding constraint (each Devin session is a local agent process), so the user wants to keep N slots saturated until M total attempts are spent.

This doc proposes adding a `--max-tasks M` flag to `ralph` / `ralph-devin` / `ralph-codex` that, when combined with `--parallel N`, switches from the current batch model to a **bounded continuous worker pool**: keep ≤ N workers running, spawn a replacement as soon as one finishes, stop when M total attempts have completed.

## 2. Why batch is the V1 default

Three reasons batch shipped first:

1. **Simplicity.** A wait-all loop is ~5 lines of bash; a worker pool with replacement requires a "wait for ANY of these PIDs" primitive that bash 3.2 (macOS default) does not provide natively.
2. **Determinism.** Wait-all has well-defined start and end semantics. The user knows that after the command returns, all in-flight Devin sessions are finished.
3. **No skip-list needed.** A failed task in batch mode reverts to `[ ]` and is picked up on the next manual invocation. In continuous mode, the same failed task would be re-picked immediately within the same run, potentially burning all M attempts on a single broken task.

V2 needs to preserve (1) the simple batch path for back-compat and address (2) and (3) in the continuous path.

## 3. Proposed flags

Add to `ralph` / `ralph-devin` / `ralph-codex`:

```
--max-tasks M                   # total attempts before stopping (engages continuous mode)
--max-task-attempts K           # max retries per individual task within a run (default: 1)
--respawn-delay SEC             # optional cooldown between replacements (default: 0)
```

Semantics:

- `--max-tasks M` is the **engagement flag** for continuous mode. Without it, current batch behavior is unchanged.
- `--max-tasks M` requires `--parallel N`. Passing `--max-tasks` without `--parallel` is a parse error: `--max-tasks requires --parallel`.
- `M >= 1`. `M=0` is rejected with `--max-tasks must be >= 1`. Non-integer rejected.
- `M < N` is allowed (effectively bounds the run to fewer attempts than concurrency). Useful for "try at most M tasks, fail fast" scenarios.
- `M` may exceed available pending tasks. The orchestrator stops naturally when the queue empties.
- `--max-task-attempts K` defaults to `1`. A task that fails K times within a run is added to a per-run skip-list and never picked again on that run. `K >= 1`.
- `--respawn-delay SEC` defaults to `0`. Useful for engines that throttle concurrent session creation (e.g., Devin cloud handoff at high N).

Counting policy: **all attempts count toward M** (success and failure both decrement the remaining budget). Rationale, per user requirement: cost containment matters more than success containment. A flaky task that fails 3 times consumes 3 of the M budget. Users who hit this can re-run after addressing the flaky task.

In single-repo (non-workspace) mode the flag works the same way: pick from the top-level fix_plan.md, no per-repo cap, multiple tasks may run concurrently in the same repo (each in its own worktree branch via `worktree_create` keyed on `task_id`).

## 4. Interaction with existing flags

| Flag combination | Behavior |
|---|---|
| `--parallel N` (no `--max-tasks`) | Current batch behavior. Byte-identical output. |
| `--parallel N --max-tasks M` | Continuous worker pool, ≤ N concurrent, until M attempts. |
| `--workspace --parallel N --max-tasks M` | Continuous workspace mode, one task per repo at a time, ≤ N concurrent across repos. |
| `--task NUM` + `--max-tasks M` | Parse error: `--task and --max-tasks are mutually exclusive` (`--task` targets a single specific task). |
| `--qg` + `--max-tasks M` | Parse error: `--max-tasks does not apply to --qg mode` (`--qg` is a one-shot quality-gate fix). |
| `--max-tasks M` without `--parallel` | Parse error: `--max-tasks requires --parallel`. |
| `--parallel-bg N --max-tasks M` | Parse error: `--parallel-bg` spawns independent agents in separate terminals; continuous mode requires a single coordinator. Use `--parallel N --max-tasks M` instead. |

The continuous mode is engine-orthogonal: `--engine claude | devin | codex` continues to govern which model runs in each worker. Per-engine tuning recommendations:

| Engine | Suggested N for continuous | Rationale |
|--------|---------------------------|-----------|
| claude | 3–4 | Anthropic API tier-1 keys handle this comfortably; single-process Claude Code is moderate CPU. |
| devin  | 2–3 | Each Devin session is a local agent; CPU and disk-IO are the binding constraints, not API rate. |
| codex  | 2 | OpenAI org-key RPM is the bottleneck; conservative default. |

These are tuning hints in docs, not enforced in code. The user picks N based on their hardware and key tier.

## 5. Worker pool mechanics

The core orchestrator is a new function `run_continuous_worker_pool` in a new library file `lib/worker_pool.sh`. Signature (pseudo-bash):

```
run_continuous_worker_pool \
    <max_concurrent_N> \
    <max_total_attempts_M> \
    <max_attempts_per_task_K> \
    <respawn_delay_seconds> \
    <picker_fn>      # picks next task; output: opaque task descriptor or "" when none
    <executor_fn>    # runs a task; receives task descriptor; returns 0/non-zero
    <on_complete_fn> # post-completion hook; receives task descriptor + exit code
```

The orchestrator owns:

- **Slots.** An array `pids[]` of length up to N, plus a parallel array `tasks[]` mapping each slot to its current task descriptor.
- **Counters.** `completed` (attempts so far), `succeeded`, `failed`, `skipped` (tasks added to skip-list).
- **Skip-list.** A newline-separated list of task identifiers (line numbers for fix_plan.md tasks) that have hit `K` failures within this run.
- **Wait-for-any.** A portable helper `_wait_for_any pids[]` that returns the index of whichever PID exits first.

### 5.1 Wait-for-any portability

bash 4.3+ has `wait -n` which returns when any single child exits. bash 3.2 (macOS default, which the project explicitly supports per `AGENTS.md:116` and the `tr '[:upper:]' '[:lower:]'` pattern in `lib/wizard_utils.sh:39,53`) does not.

Implementation:

```bash
_wait_for_any() {
    local -n _pids=$1   # nameref to caller's pids array (bash 4.3+)
    # Polling fallback for bash 3.2: kill -0 each PID until one is dead
    while true; do
        for i in "${!_pids[@]}"; do
            local pid="${_pids[$i]}"
            [[ -z "$pid" ]] && continue
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                local rc=$?
                echo "$i $rc"
                return 0
            fi
        done
        sleep 0.5
    done
}
```

Fast path on bash 4.3+: detect `BASH_VERSINFO[0] >= 4 && BASH_VERSINFO[1] >= 3` and use `wait -n -p PID; ec=$?`. Polling fallback otherwise. Either way the API is the same.

The 0.5 s poll interval is a deliberate trade-off: shorter intervals waste CPU, longer intervals delay respawn. 0.5 s adds at most 500 ms of latency between completion and respawn — negligible compared to a 5–25 minute Devin session.

Bash 3.2 alternative considered: `wait -p` is bash 5.1+ only. SIGCHLD handler with `trap` plus a flag file is fragile (the trap fires inside subshells unpredictably). The polling loop is the cleanest portable answer.

### 5.2 Orchestration loop

The pseudocode below uses `attempts_by_task = {}` for clarity, but the actual implementation must use parallel arrays (newline-separated `task_id\tcount` strings) because bash 3.2 has no associative arrays. The pattern used by `pick_workspace_tasks_parallel` at `lib/workspace_manager.sh:487` (parallel arrays of repo names and task descriptors) is the reference implementation. `_atomic_inc_call_count` (§5.5) shows the same lock pattern that protects the in-memory state.

```
init pids[] (size N), tasks[] (size N), all empty
completed = 0
succeeded = 0
failed = 0
skipped = 0
skip_list = ""
attempts_by_task = {}   # implemented as parallel bash 3.2 arrays (see note above)

# Initial fill: start up to N workers
for slot in 0..N-1:
    if completed + len(in_flight) >= M: break
    task = picker_fn(skip_list)
    if task is empty: break
    spawn worker for task in slot, record pid + task

# Main loop: wait for any worker, pick a replacement
while any pids[] is non-empty:
    (slot, exit_code) = _wait_for_any(pids)
    completed += 1
    on_complete_fn(tasks[slot], exit_code)
    if exit_code == 0:
        succeeded += 1
    else:
        failed += 1
        attempts_by_task[tasks[slot]] += 1
        if attempts_by_task[tasks[slot]] >= K:
            add tasks[slot] to skip_list
            skipped += 1

    pids[slot] = ""
    tasks[slot] = ""

    # Should we respawn?
    if completed >= M: continue   # drain only, no new spawns
    if respawn_delay > 0: sleep respawn_delay
    next_task = picker_fn(skip_list)
    if next_task is empty: continue   # queue empty, drain only
    spawn worker for next_task in slot

# All slots empty, M reached or queue empty
print summary
return succeeded == completed ? 0 : 1
```

### 5.3 Picker abstraction

Two picker implementations plug into the orchestrator:

**Workspace picker** (in `lib/workspace_manager.sh`, new function `pick_workspace_task_for_pool`):

- Reuses `pick_workspace_task` (sequential single-task atomic picker) under its existing `.workspace_task_lock`.
- Skips tasks whose line numbers are in the skip-list.
- Returns the same `repo|task_id|line|desc` format.
- The "one task per repo at a time" rule is preserved: `pick_workspace_task` already skips repos with any `[~]`.

**Single-repo picker** (in `lib/task_sources.sh`, new function `pick_next_task_for_pool`):

- Reuses `pick_next_task` (`lib/task_sources.sh:749`) under its existing `.task_pick_lock`.
- Skips tasks whose line numbers are in the skip-list.
- Returns the same `task_id|line_num|bead_id` format (per the actual output at `lib/task_sources.sh:790`).
- No per-repo constraint (there is only one repo); concurrent workers in the same repo each get unique worktree branches via existing `worktree_create` task_id keying.

### 5.4 Executor abstraction

Workspace executor: `_workspace_execute_task` (already exists, exported, used by current batch path). Reused as-is.

Single-repo executor: needs a wrapper that calls `execute_devin_session` (or the engine equivalent) inside a worktree, with the same change-detection / quality-gates / PR / cleanup pipeline as the workspace executor. This wrapper is a refactor of the current `main()` body in `ralph_loop_devin.sh:973` extracted into a standalone function `_singlerepo_execute_task`. Without continuous mode the single-repo path stays in `main()` unchanged; the new function is only called by the worker pool path.

### 5.5 Counter atomicity

The call counter `$CALL_COUNT_FILE` is incremented inline today (no `update_call_tracking` wrapper exists). The pattern lives in `execute_devin_session` at `devin/ralph_loop_devin.sh:517-518` and `:846`:

```bash
calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
calls_made=$((calls_made + 1))
# ...later...
echo "$calls_made" > "$CALL_COUNT_FILE"
```

Multiple workers writing concurrently can lose increments. Today's batch mode has the same race; it's tolerated because the counter is hourly-reset and approximate.

Continuous mode amplifies the race (more total writes per unit time, all in parallel). Cheap fix: introduce a new helper `_atomic_inc_call_count` (in `lib/date_utils.sh` or a new `lib/atomic_counter.sh`) that wraps the increment in an mkdir-based atomic lock — the same pattern already used by `_acquire_task_lock` in `lib/task_sources.sh`:

```bash
_atomic_inc_call_count() {
    local lock_dir="${RALPH_DIR}/.call_count_lock"
    while ! mkdir "$lock_dir" 2>/dev/null; do sleep 0.05; done
    local n
    n=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    n=$((n + 1))
    echo "$n" > "$CALL_COUNT_FILE"
    rmdir "$lock_dir" 2>/dev/null
    echo "$n"
}
```

The continuous path replaces both inline `cat`/`echo` sites with a single call to `_atomic_inc_call_count`. The batch path stays as-is for byte-identical back-compat — the inline pattern is left untouched outside the continuous code path.

## 6. Failure handling and the skip-list

A worker exits non-zero in three cases:

1. **No-op revert.** Devin produced 0 file changes. Existing logic in `_workspace_execute_task` reverts the task to `[ ]` and returns 1.
2. **Engine error.** Devin/Claude/Codex CLI crashed, timed out, or returned a non-zero exit. Task reverts to `[ ]`.
3. **Quality-gate fail with PR creation success.** Today this still returns 0 (PR is created with the `quality-gates-failed` label). Continuous mode preserves this — the task is marked complete `[x]`, the worker exits 0, the task counts as a success.

In cases 1 and 2, `attempts_by_task[task_id]` is incremented. If it reaches `K` (default 1), the task line is added to the skip-list and not picked again on this run. The task stays at `[ ]` in fix_plan.md so the next manual run can attempt it.

A failed task that hits the skip-list is **not** re-marked. It returns to `[ ]` so the user can fix the underlying issue (broken test, network glitch, etc.) and re-run. If users want a "burned" marker like `[!]` for "tried and failed too many times this run," that is a separate proposal — see §13.

The skip-list is in-memory only, scoped to a single orchestrator process. It does not persist across runs.

Edge case: a task picked into the skip-list could also be hand-picked via `--task NUM` in a separate ralph invocation. That is fine; `--task` is mutually exclusive with `--max-tasks` in the same invocation.

## 7. Stop conditions and signal handling

The orchestrator stops when any of these become true:

| Condition | Behavior |
|---|---|
| `completed >= M` | Drain only — wait for in-flight workers to finish, do not spawn replacements. |
| Queue empty (picker returns "" for all slots) | Drain only. |
| User sends `SIGINT` (Ctrl+C) | Drain only. Existing `cleanup` trap is reused. In-flight workers complete naturally; their tasks settle to `[x]` or `[ ]` according to the executor's normal logic. |
| User sends `SIGTERM` | Same as SIGINT. |
| Circuit breaker opens for engine | Drain only. Same drain behavior. The orchestrator records the trip in the final summary. |

Hard-kill behavior (sending SIGKILL to ralph itself, or `kill -9` on the orchestrator PID): the in-flight Devin processes become orphans, their `[~]` task marks remain in fix_plan.md, no PR is created. This is the same behavior as today's batch mode under hard-kill; recovery is manual (clear `[~]` to `[ ]` in fix_plan.md).

The orchestrator does not attempt SIGINT-then-revert: aborting a Devin session mid-run produces partial work and inconsistent worktree state. Drain-and-finish is the only sane policy.

## 8. Telemetry and final summary

While running, the orchestrator emits a status line on every completion:

```
[continuous] completed=4/20 succeeded=3 failed=1 skipped=0 in_flight=3 pending=12
```

And a heartbeat line every 30 s while in steady state:

```
[continuous] heartbeat: 4/20 attempts, 3 in flight, 12 pending (M=20 N=3)
```

Final summary on exit:

```
╔════════════════════════════════════════════════════════════╗
║              Continuous Execution Summary                  ║
╠════════════════════════════════════════════════════════════╣
║  Mode:            continuous (workspace)                   ║
║  Concurrency:     N=3                                      ║
║  Target:          M=20 attempts                            ║
║  Completed:       18 attempts (90%)                        ║
║  Succeeded:       15 (PRs created)                         ║
║  Failed:          3                                        ║
║  Skipped:         2 (hit max-attempts limit)              ║
║  Wall time:       1h 23m                                   ║
║  Avg per task:    4m 36s                                   ║
║  Stop reason:     queue empty                              ║
╚════════════════════════════════════════════════════════════╝
```

Stop reason is one of: `target reached (M)`, `queue empty`, `user interrupt`, `circuit breaker open`, `fatal error`. Wall time and avg-per-task are computed from epoch start/end captured at orchestrator entry/exit.

**Summary log persistence.** On orchestrator exit, the summary block is also appended to `.ralph/logs/continuous-summary.log` (one entry per run, separated by a timestamped header line). This gives users a historical record without having to `tee` themselves. The log is append-only; rotation is left to the user (or a future follow-up).

The status JSON file (`.ralph/status.json`, per `devin/ralph_loop_devin.sh:43`) gains four new fields when continuous mode is active: `mode: "continuous"`, `target_M`, `concurrency_N`, `attempts_completed`. Existing consumers (the monitor) ignore unknown fields.

## 9. Default values

`--max-tasks M` has no default — it is the engagement flag and must be passed (or `RALPH_MAX_TASKS` set in env) to opt into continuous mode. This preserves the principle that absent flags ⇒ unchanged behavior.

`--max-task-attempts K` defaults to `1` (per §15 Q1). `--respawn-delay SEC` defaults to `0`. Both apply only when continuous mode is engaged.

Env overrides:

| Env var | Equivalent flag |
|---|---|
| `RALPH_MAX_TASKS` | `--max-tasks` |
| `RALPH_MAX_TASK_ATTEMPTS` | `--max-task-attempts` |
| `RALPH_RESPAWN_DELAY` | `--respawn-delay` |

Resolution order (first match wins): CLI flag > env var > unset (continuous mode disabled). `.ralphrc` does not currently expose these knobs in this proposal — adding them is a follow-up if usage justifies it.

## 10. Back-compat

Hard requirement: invocations that do not pass `--max-tasks` and do not set `RALPH_MAX_TASKS` must produce **byte-identical** behavior to V1.

This is achieved by:

- The continuous code path is gated on a single boolean `CONTINUOUS_MODE=true` set only when `--max-tasks` is present (or env is set).
- When `CONTINUOUS_MODE=false`, all dispatch goes through the existing functions: `_run_workspace_parallel` for workspace+parallel, `main` for single-repo, `spawn_parallel_agents` for non-workspace `--parallel`.
- The new `lib/worker_pool.sh` and `lib/continuous_recovery.sh` are sourced unconditionally (cheap; ~230 lines combined) but their functions are only called from the new path — except `sweep_stale_continuous_state`, which runs at the top of every ralph startup. **This is intentional:** the sweeper is a no-op when `.ralph/.continuous_state` does not exist (single `[[ -f ... ]]` test, then return). It only takes action after a hard-killed continuous run, never affecting batch users.
- Logging output for the batch path is unchanged. Continuous runs add a new `[continuous]` log prefix on orchestrator events. The sweeper logs a single `log_info` line per recovered task; if no recovery is needed (the common case), it is silent.

CLI back-compat:

- All existing flags continue to work unchanged.
- `--max-tasks` is purely additive.
- The error messages for invalid combinations (`--max-tasks` without `--parallel`, with `--task`, with `--qg`, with `--parallel-bg`) are new but cannot break any V1 invocation since those combinations were not previously meaningful.

## 11. Single-repo vs workspace details

### Workspace continuous mode

`ralph-devin --workspace --parallel 3 --max-tasks 20`

- Discovery: same as today (`discover_workspace_repos`).
- Initial spawn: pick up to 3 tasks across 3 different repos via `pick_workspace_task` called 3 times (each call atomic, one task per repo).
- Replacement: when slot K finishes, call `pick_workspace_task_for_pool` (new wrapper that respects skip-list) to grab the next eligible task. The "one task per repo at a time" rule is preserved: a repo with an in-flight `[~]` is skipped by the existing picker logic.
- If all repos currently have an in-flight task and slot K finishes its repo first, the repo just freed becomes immediately eligible. The picker will return its next pending task (if any) on the same scan.

Concurrency cap: effective concurrency is `min(N, |repos with pending tasks|)`. If a workspace has 2 repos with pending tasks and `N=5`, only 2 workers ever run concurrently. This is the existing behavior of `get_workspace_parallel_limit`.

### Single-repo continuous mode

`ralph-devin --parallel 3 --max-tasks 20`

- Discovery: just the current cwd, must be a Ralph project (`PROMPT.md`/`.ralph/` present).
- Initial spawn: pick up to 3 tasks via `pick_next_task` called 3 times. No per-repo constraint, since there is only one repo. Each pick is atomic under `.task_pick_lock`; each task gets a unique worktree branch via `worktree_create $loop_count $task_id`.
- Replacement: same picker, skip-list aware.
- Concurrency cap: effective concurrency is `min(N, |pending tasks|)`.

Single-repo collisions: two workers in the same repo touching different files are safe (worktree isolation). Two workers touching the same files produce a merge conflict on PR. The `quality-gates-failed` PR label is the existing safety net for the second PR; the user resolves manually. This is a known trade-off of single-repo parallelism, not a new risk introduced by this proposal — the same risk exists today with `--parallel-bg N` in single-repo mode (each independent ralph picks one task; worktree branches don't collide but file-level conflicts still require manual merge).

### Per-engine wrapper wiring

The same flag set lands in three places:

- `ralph_loop.sh` — Claude
- `devin/ralph_loop_devin.sh` — Devin
- `codex/ralph_loop_codex.sh` — Codex

Each gains:

```bash
--max-tasks)
    if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: --max-tasks requires a positive integer"
        exit 1
    fi
    MAX_TASKS="$2"
    CONTINUOUS_MODE=true
    shift 2
    ;;
--max-task-attempts)
    ...
--respawn-delay)
    ...
```

And dispatch:

```bash
if [[ "$CONTINUOUS_MODE" == "true" ]]; then
    if [[ "$WORKSPACE_MODE" == "true" ]]; then
        run_continuous_workspace "$MAX_TASKS" "$PARALLEL_COUNT" ...
    else
        run_continuous_singlerepo "$MAX_TASKS" "$PARALLEL_COUNT" ...
    fi
    exit $?
fi
# ...existing batch / single-repo paths unchanged...
```

The two `run_continuous_*` wrappers in each engine script call `run_continuous_worker_pool` from the new lib with the engine-appropriate executor and picker.

## 12. Library layout

New files:

- `lib/worker_pool.sh` — generic continuous orchestrator. ~180 lines. Exports:
  - `run_continuous_worker_pool` — main entry
  - `_wait_for_any` — portable wait-for-any helper
  - `_atomic_inc_call_count` — race-free counter increment
  - `init_continuous_state`, `record_inflight`, `clear_inflight`, `cleanup_continuous_state` — state-file lifecycle for §16

- `lib/continuous_recovery.sh` — startup sweeper. ~50 lines. Exports:
  - `sweep_stale_continuous_state` — invoked at top of every ralph entry point

Modified files:

- `lib/workspace_manager.sh` — add `pick_workspace_task_for_pool` (skip-list aware wrapper). ~30 lines.
- `lib/task_sources.sh` — add `pick_next_task_for_pool` (skip-list aware wrapper). ~30 lines.
- `lib/date_utils.sh` — add `_atomic_inc_call_count` helper if not placed in a separate file.
- `ralph_loop.sh` — CLI parsing for `--max-tasks` / `--max-task-attempts` / `--respawn-delay` + dispatch + extracted `_singlerepo_execute_task` + `sweep_stale_continuous_state` call at top of `main()`. ~85 lines.
- `devin/ralph_loop_devin.sh` — same. ~85 lines.
- `codex/ralph_loop_codex.sh` — same. ~85 lines.

Aliases (each engine's `ALIASES.sh` gets a new shortcut):

```bash
# devin/ALIASES.sh
rpd.cont() { ralph-devin --parallel "${1:?Usage: rpd.cont <N> <M>}" --max-tasks "${2:?Usage: rpd.cont <N> <M>}"; }
rpd.ws.cont() { ralph-devin --workspace --parallel "${1:?Usage: rpd.ws.cont <N> <M>}" --max-tasks "${2:?Usage: rpd.ws.cont <N> <M>}"; }
```

Same pattern for `rpc.cont` (Claude, in `ALIASES.sh`) and `rpcx.cont` (Codex, in `codex/ALIASES.sh`). Naming follows existing convention: Claude uses the `rpc.*` namespace, Devin uses `rpd.*`, Codex uses `rpx.*` (note: not `rpcx.*` — verify against `codex/ALIASES.sh:56` which shows `rpx.int.p()`). The alias prefix should be **`rpx.cont`**, not `rpcx.cont`.

New artifacts written by continuous mode:

- `.ralph/.continuous_state` — orchestrator state file (§16). Created on entry, deleted on clean exit, swept on startup if stale.
- `.ralph/.call_count_lock/` — mkdir-based lock dir for `_atomic_inc_call_count` (§5.5). Transient.
- `.ralph/logs/continuous-summary.log` — append-only summary log (§8). Persists across runs.

Total touched LOC estimate: ~700 lines added, ~30 lines moved (singlerepo executor extraction), 0 lines removed.

## 13. Test coverage

New bats tests required (`tests/unit/test_worker_pool.bats`):

| Test | Scope | Asserts |
|------|-------|---------|
| `--max-tasks` flag parses | unit | M=1, M=20 accepted; M=0 errors; non-int errors; without `--parallel` errors |
| `--max-task-attempts` flag parses | unit | K=1 default; K=3 accepted; K=0 errors |
| `--respawn-delay` flag parses | unit | SEC=0 default; SEC=5 accepted; non-numeric errors |
| `--max-tasks` rejected with `--task` | unit | error message names both flags |
| `--max-tasks` rejected with `--qg` | unit | error message names both flags |
| `--max-tasks` rejected with `--parallel-bg` | unit | error message points to `--parallel` |
| `--max-tasks` requires `--parallel` | unit | error message |
| Env override `RALPH_MAX_TASKS` | unit | env=10 with no flag ⇒ M=10 |
| CLI flag wins over env | unit | flag=20 with env=10 ⇒ M=20 |
| `_wait_for_any` returns first-finishing slot | unit | spawn 3 sleepers with different durations; verify shortest returns first |
| `_wait_for_any` returns correct exit code | unit | spawn worker that returns 7; assert returned (slot, 7) |
| Atomic call counter under concurrency | unit | 10 parallel `_atomic_inc_call_count` calls; final value is exactly 10 |
| Picker respects skip-list (workspace) | unit | pre-mark line 5 in skip-list; picker returns line 7 next |
| Picker respects skip-list (single-repo) | unit | same |
| Failed task adds to skip-list at K=1 | unit | mock executor returns 1; assert task in skip-list, attempts++ |
| Failed task NOT added to skip-list at K=2, attempt 1 | unit | mock executor returns 1 once, then 0; task not skipped |
| M reached ⇒ drain only | integration | M=4, N=3, 6 tasks pending; assert 4 attempts, 2 unpicked |
| Queue empty ⇒ drain only | integration | M=20, N=3, 5 tasks pending; assert 5 attempts, exit clean |
| SIGINT during continuous run | integration | send SIGINT mid-run; assert in-flight workers complete, no replacement spawned |
| Workspace continuous: one task per repo | integration | 3 repos × 2 tasks each, N=5, M=20; assert ≤ 3 concurrent at any moment |
| Single-repo continuous concurrency | integration | 1 repo × 10 tasks, N=3, M=10; assert exactly 3 worktrees alive at peak |
| Final summary line counts | integration | run with mocked executor, assert summary numbers match captured exits |
| Back-compat: --parallel without --max-tasks | integration | run existing batch test; output byte-identical to before |
| Sweeper: no-op when state file absent | unit | `sweep_stale_continuous_state` returns 0 with no side effects when `.ralph/.continuous_state` does not exist |
| Sweeper: skip when orchestrator PID alive | unit | write state with `$$` as orch_pid; assert sweeper does not modify fix_plan.md or delete state file |
| Sweeper: revert `[~]` when orchestrator PID dead | integration | write state with a known-dead PID and 2 in_flight lines; assert both `[~]` revert to `[ ]` and state file is removed |
| Sweeper: missing jq → graceful degrade | unit | mock `command -v jq` to fail; sweeper logs warning and returns 0 without touching files |
| Summary log: appended on clean exit | integration | run continuous mode to completion; assert `.ralph/logs/continuous-summary.log` has exactly one new entry with timestamp header |
| Summary log: appended on SIGINT drain | integration | send SIGINT mid-run; assert log has one entry with `Stop reason: user interrupt` |
| State file: lifecycle | integration | assert state file exists during run with correct PID, has in_flight entries during work, is deleted on clean exit |

`npm test` (the existing bats runner used by the project) continues to pass.

## 14. Rollout plan

Three-phase ship inside ai-ralph:

**Phase A (feature merged behind explicit flag, one minor release).**
- Implementation lands. No behavior change without `--max-tasks`. Users opt in.
- Docs (README, AGENTS.md, ALIASES.sh comments) call out the flag with examples.
- Telemetry (if added later): count usage and per-engine M/N distributions.

**Phase B (deprecate manual re-invoke pattern, next minor).**
- Help text for `--parallel N` (without `--max-tasks`) gains a tip line: "tip: pair with `--max-tasks M` to keep slots saturated."
- README example workflows updated to prefer `--parallel N --max-tasks M` for multi-task runs.
- `--max-tasks` remains opt-in; no auto-defaulting.

**Phase C (optional, only if usage data justifies).**
- Consider adding `RALPH_MAX_TASKS` and `RALPH_MAX_TASK_ATTEMPTS` to `.ralphrc` template so workbench / per-project configs can default the value. Out of scope for V2.

If Phase A uncovers issues with the polling `_wait_for_any` (CPU usage, latency), the bash-version detection path can be tightened or the poll interval tuned without a flag-surface change.

## 15. Resolved design decisions

The following questions were raised during proposal review and resolved as listed. The body of this proposal already reflects each decision; this section is the one-line audit trail.

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Default `K` (max-task-attempts) | **K=1** | K=2 doubles worst-case M-budget burn on a single broken task. Users who want a transient-failure retry can pass `--max-task-attempts 2` explicitly. |
| 2 | Should single-repo continuous mode require `--workspace`? | **No, allowed in single-repo too** | At the end the orchestrator solves `fix_plan.md` regardless of workspace mode. File-collision risk in single-repo parallelism already exists today via `--parallel-bg` and is mitigated by worktree branching + `quality-gates-failed` PR labels. Gating it would be timid. |
| 3 | Stale `[~]` markers on hard-kill | **Auto-recovery via PID-tracked state file (§16)** | "Manual cleanup" is poor UX. A startup sweeper that runs in any ralph mode, gated by a state file containing the orchestrator's PID + line numbers, auto-reverts stale `[~]` lines to `[ ]` on the next ralph startup. |
| 4 | Persist final summary to a log file? | **Yes, append to `.ralph/logs/continuous-summary.log`** | ~5 lines of code. Continuous runs are long; users will want history without `tee`-ing themselves. |
| 5 | Heartbeat interval tunable? | **No, hardcoded 30s in V2** | Tune later if usage data justifies. |
| 6 | Cross-engine flag honoring (e.g., codex `--respawn-delay 0` may hit RPM throttling) | **Warn and honor** | User's explicit choice wins; ralph prints a warning to stderr but does not override or refuse. |

## 16. Stale `[~]` marker recovery (resolves Q3)

When the orchestrator process dies hard (SIGKILL, panic, machine reboot), in-flight tasks retain their `[~]` marker in `fix_plan.md`. Today the user has to hand-edit the file. V2 makes recovery automatic.

**State file:** `.ralph/.continuous_state` (JSON-ish single line, written by the orchestrator):

```
{
  "orchestrator_pid": 12345,
  "started_at": 1715080000,
  "in_flight": [
    {"line": 42, "task_id": "T-101", "worker_pid": 12346},
    {"line": 57, "task_id": "T-105", "worker_pid": 12347}
  ]
}
```

**Lifecycle:**

1. On orchestrator entry (continuous mode, both workspace and single-repo): write the file with the orchestrator PID and an empty `in_flight` list.
2. After each successful pick (`pick_workspace_task` or `pick_next_task` returns a task), append `{line, task_id, worker_pid}` to `in_flight` under the same `.workspace_task_lock` / `.task_pick_lock` that the picker already holds.
3. After each completion (`_wait_for_any` returns), remove the entry for the finished slot.
4. On clean exit (target reached, queue empty, SIGINT drained), `rm -f .ralph/.continuous_state`.

**Sweeper:** a new helper `sweep_stale_continuous_state` runs at the very top of every ralph entry point (Claude / Devin / Codex `main()`):

```bash
sweep_stale_continuous_state() {
    local state_file="${RALPH_DIR}/.continuous_state"
    [[ -f "$state_file" ]] || return 0
    local orch_pid
    orch_pid=$(jq -r '.orchestrator_pid // empty' "$state_file" 2>/dev/null) || return 0
    if [[ -n "$orch_pid" ]] && kill -0 "$orch_pid" 2>/dev/null; then
        return 0   # Orchestrator still alive — leave state alone.
    fi
    # Orchestrator is dead. Revert each in-flight [~] to [ ].
    local fix_plan="${WORKSPACE_FIX_PLAN:-${RALPH_DIR}/fix_plan.md}"
    while IFS=$'\t' read -r line_num task_id; do
        [[ -z "$line_num" ]] && continue
        sed -i.bak "${line_num}s/\[~\]/[ ]/" "$fix_plan" && rm -f "${fix_plan}.bak"
        log_info "Reverted stale [~] at line $line_num (task $task_id) from dead orchestrator $orch_pid"
    done < <(jq -r '.in_flight[] | "\(.line)\t\(.task_id)"' "$state_file" 2>/dev/null)
    rm -f "$state_file"
}
```

**Properties:**

- Runs unconditionally on every ralph startup (not just continuous mode), so a user who runs `ralph --task 5` after a crash also gets recovery.
- A live orchestrator's PID is preserved by `kill -0`; the sweeper will not touch state owned by a running process. Two concurrent ralph invocations are fine.
- `jq` is already a soft dependency in ai-ralph (used by `lib/response_analyzer.sh` JSON parsing). If `jq` is missing, the sweeper logs a warning and skips — no recovery, but no crash either. `command -v jq` is checked at the top.
- Cost: a single `stat`/`jq` per ralph startup when no state file exists (negligible). When recovery runs, one `sed -i.bak` per stale line (typically ≤ N lines).

**PID-collision note:** if the system reboots and a new process happens to take the dead orchestrator's PID, the sweeper would think the orchestrator is alive and skip recovery. Mitigation: the state file also stores `started_at` (epoch). The sweeper can additionally check that the live PID's start time matches via `ps -o lstart= -p $orch_pid`, but this is platform-specific (Linux vs macOS `ps` flags differ). Deferred to a follow-up — PID collisions across reboots are rare enough that one stale `[~]` requiring manual edit is an acceptable failure mode for V2.

**No new flag.** The sweeper runs automatically. Users who want explicit manual recovery can still hand-edit `fix_plan.md` or delete `.ralph/.continuous_state` themselves. A `ralph --sweep-stale` standalone subcommand is left as a follow-up if usage warrants.

## 17. Future-work follow-ups

The following items were raised during review and explicitly deferred:

1. **`.ralphrc` exposure of `RALPH_MAX_TASKS` / `RALPH_MAX_TASK_ATTEMPTS`.** Out of scope for V2 (covered in §10). Add if usage data justifies a per-project default.
2. **Heartbeat interval env override (`RALPH_HEARTBEAT_INTERVAL`).** Hardcoded 30s in V2 (Q5). Add when there is a concrete user request for tuning.
3. **`ralph --sweep-stale` standalone subcommand.** Auto-sweep in §16 covers the common case. Add only if users hit a scenario the auto-sweep misses (e.g., PID collision after reboot, or wanting to pre-clean before another tool runs).
4. **`[!]` "burned task" marker for tasks that hit `K` failures within a run.** Today they revert to `[ ]`. Cleaner UX for re-runs, but a separate proposal because it changes the fix_plan.md vocabulary.
5. **PID-collision-safe sweeper.** Add `started_at` epoch comparison via `ps -o lstart=` once the platform-specific flag handling is paved (see §16's "PID-collision note").
