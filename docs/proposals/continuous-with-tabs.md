# Continuous parallel execution with per-worker terminal tabs

Status: **implemented** (lib/worker_pool_tabs.sh; tabs default for `--parallel N M` when supported).
Audience: ai-ralph maintainers.
Author: ai-ralph team.
Date: 2026-05-10.

## Implementation note

The implemented design differs from the proposal in one key way: instead of
gating tabs behind a `--tabs` opt-in flag (Option A in the original proposal),
**tabs is now the default for `--parallel N M`** when the terminal supports
them (`tabs_supported_by_terminal()`). The opt-out is `--no-tabs` or
`RALPH_DISABLE_TABS=true`. The single-pane orchestrator in
`lib/worker_pool.sh` is the automatic fallback for plain terminals.

All other design decisions (completion-file protocol, heartbeat sweep,
SIGINT drain, status.json hook) were implemented as described below.

## Problem

The current `--parallel N M` continuous mode runs all N workers as background
subprocesses of a single orchestrator. All stdout streams interleave into one
terminal pane. Users who reach for `rpd.p N M` expecting iTerm2-style
per-agent terminal tabs (the V1 batch behavior) get a single-pane experience
instead — surprising and harder to debug per-worker.

Existing modes by comparison:

| Mode | Concurrency | Tabs? | Auto-respawn until M? | Single coordinator? |
|---|---|---|---|---|
| `--parallel N` (V1 batch) | N independent agents | ✅ via `spawn_parallel_agents` | ❌ each agent runs its own loop | ❌ N detached processes |
| `--parallel N M` (V2 continuous) | N background workers | ❌ single pane | ✅ orchestrator respawns | ✅ one parent process |
| **This proposal: `--parallel N M --tabs`** | N per-tab workers | ✅ iTerm2/IDE | ✅ orchestrator respawns | ✅ orchestrator + tabs |

The goal is to give continuous mode the visual structure of V1 batch — one tab
per active worker — while preserving the orchestrator-level guarantees of V2
continuous: skip-list, attempt cap, `attempts_completed` tracking,
SIGINT-safe drain, status.json updates, crash recovery.

## Goals

1. **Per-task visual isolation.** Each in-flight task runs in its own
   terminal tab/window. Closing the tab when the task completes is fine; the
   orchestrator picks the next task and opens a fresh tab.
2. **Orchestrator-driven respawn.** When a tab completes (success, failure,
   or "no changes"), the orchestrator detects it and spawns a replacement
   tab on the next pending task — until M total attempts are spent.
3. **Skip-list, attempt cap, status.json — all preserved.** Existing
   continuous-mode features keep working unchanged.
4. **Bounded N.** Same `--parallel` cap of 10 applies; event volume is
   small, no need for inotify scaling.
5. **Opt-in.** Default `--parallel N M` keeps current single-pane behavior;
   tab mode engages explicitly via a flag or env var.

## Non-goals

- Closing user-visible tabs automatically when a task completes. (Tab close
  policy is up to the user / terminal; the orchestrator only spawns new
  ones.)
- Cross-machine or remote-tab support (e.g., spawning tabs on a different
  host).
- Tab support for Codex or Claude beyond what `spawn_parallel_agents`
  already provides (iTerm2, VS Code/Windsurf/Cursor IDE terminals).
- Per-tab live progress bars or rich UI. Output is whatever the AI CLI
  natively writes.

## Architecture

### High level

```
┌─────────────────────────────────────────────────────────────┐
│  Orchestrator (long-lived parent in user's main terminal)    │
│  - Picks tasks via pick_*_task_for_pool (atomic, locked)     │
│  - Maintains skip_list / attempts_per_task / status.json     │
│  - Polls .ralph/.continuous_completions/ every ~0.5s         │
│  - Spawns replacement tabs as completions are detected       │
│  - Catches SIGINT/SIGTERM: stops spawning, waits for tabs    │
└──────────────┬──────────────────────────────────────────────┘
               │ spawns via spawn_parallel_agents
               ↓
   ┌─────────────────────┐   ┌─────────────────────┐
   │  Tab worker #1      │   │  Tab worker #2  ... │
   │  ralph-devin        │   │  ralph-devin        │
   │  --continuous-worker│   │  --continuous-worker│
   │    <wid> <task>     │   │    <wid> <task>     │
   │                     │   │                     │
   │  On exit:           │   │  On exit:           │
   │  write              │   │  write              │
   │  .completions/      │   │  .completions/      │
   │   <wid>-<rc>.json   │   │   <wid>-<rc>.json   │
   └─────────────────────┘   └─────────────────────┘
```

### Completion protocol

Each worker writes a single JSON file on exit to:

```
.ralph/.continuous_completions/<worker_id>-<timestamp>.json
```

Schema:

```json
{
  "worker_id": "ws-3-1715080000",
  "task_id": "fix-login",
  "line_num": 42,
  "rc": 0,
  "started_at": 1715080000,
  "ended_at": 1715080047,
  "tab_pid": 12345,
  "changes_detected": true
}
```

Atomic write via write-to-`.tmp` then `mv` (rename) — POSIX-atomic on the
same filesystem. Orchestrator only reads files whose names don't end in
`.tmp`.

### Orchestrator state machine

```
state = STARTING
attempt_count = 0
in_flight = {}    # worker_id → task descriptor
skip_list = []

while attempt_count < M and not interrupted:
    # Fill up to N
    while len(in_flight) < N:
        task = pick_next_task(skip_list)
        if not task:
            break
        worker_id = generate_id()
        spawn_tab(worker_id, task)
        in_flight[worker_id] = task

    if not in_flight:
        stop_reason = "queue empty"
        break

    # Wait for any completion (poll .completions/ dir)
    completion = wait_for_any_completion(timeout=0.5s)
    if completion:
        attempt_count += 1
        record_completion(completion)
        update_status_json()
        if completion.rc != 0:
            attempts[completion.task_id] += 1
            if attempts[completion.task_id] >= K:
                skip_list += [completion.task_id]
        del in_flight[completion.worker_id]
        # loop top will spawn replacement

# Drain on interrupt or M reached
state = DRAINING
while in_flight:
    completion = wait_for_any_completion(timeout=0.5s)
    if completion:
        del in_flight[completion.worker_id]
        record_completion(completion)

state = STOPPED
emit_summary()
update_status_json("stopped", exit_reason=stop_reason)
```

This is the same logic as `run_continuous_worker_pool` today, with two
substitutions: spawn → tab spawn, wait → completion-file poll.

### Worker tab lifecycle

Each tab is launched via `spawn_parallel_agents` (or a slimmed
single-tab version) with the command:

```bash
ralph-devin --task <task_id> --continuous-worker-id <worker_id>
```

The `--continuous-worker-id` flag is new. It is a hook that:

1. Captures `worker_id`, `started_at`, `pre_exec_sha` (for change detection)
2. Runs the existing `--task` path (single-task execution: worktree create,
   AI invoke, change detect, quality gates, PR creation, task marking)
3. On exit (any rc), writes the completion JSON atomically

The worker has no knowledge of the orchestrator beyond writing to the
completion directory. Decoupled enough that:

- An orphaned worker (orchestrator died) still completes its task and
  writes its completion.
- Multiple orchestrator instances would collide on the completion dir —
  same single-orchestrator guard as today (`init_continuous_state`
  refuses if another orchestrator is alive).

### Tab-close detection / stale heartbeat

If the user closes a tab manually (or the OS kills it), no completion
file is written. The orchestrator must detect this to avoid blocking on
phantom in-flight workers forever.

Two-tier detection:

1. **Heartbeat file.** Each worker, every 10s, touches
   `.ralph/.continuous_heartbeats/<worker_id>` (mtime-update).
2. **Stale-heartbeat sweep.** Orchestrator on each poll cycle checks: for
   each `in_flight` worker, if heartbeat mtime is older than 60s, declare
   the worker dead, revert the task to `[ ]`, increment failed counter,
   apply skip-list rule if K-attempts reached.

A separate `.ralph/.continuous_completions/<worker_id>-dead.json` is
synthesized by the orchestrator when this happens, for symmetry with
the regular completion path.

### Failure modes & recovery

| Scenario | Behavior |
|---|---|
| Worker exits cleanly | Writes completion file. Orchestrator processes it. |
| Worker crashes (segfault, OOM) | No completion file. Heartbeat goes stale → orchestrator declares dead. |
| Worker stuck (hung AI call) | Heartbeat keeps ticking until ralph's internal timeout fires. Worker either completes (writes completion) or exits non-zero. |
| User closes tab | No completion file, heartbeat goes stale → orchestrator declares dead, reverts task. |
| Orchestrator SIGINT | Stops spawning new tabs. Existing tabs continue. Orchestrator drains: waits for in-flight completions (or stale heartbeats) before exiting. |
| Orchestrator SIGKILL | All in-flight tabs orphaned. Next ralph startup: `sweep_stale_continuous_state` reverts `[~]` markers. Completed completion files remain in dir; could be GC'd. |
| Two orchestrators | Second `init_continuous_state` returns 2 → refuse to start (existing guard). |

## CLI surface

The current `--parallel N M` is established as the single-pane variant in
the merged PR. We don't want to silently change its behavior. Options:

### Option A: New `--tabs` flag

```bash
ralph-devin --parallel N M --tabs            # tab mode, continuous
ralph-devin --parallel N M                    # single-pane, continuous (today)
```

Plus aliases:
```bash
rpd.p.tabs N M       # opt-in tab mode
rpd.p N M            # unchanged single-pane
```

Pros: backward-compatible, explicit, easy to document.
Cons: another flag in an already-busy `--parallel` neighborhood.

### Option B: Env var `RALPH_CONTINUOUS_TABS=true`

```bash
RALPH_CONTINUOUS_TABS=true rpd.p N M
```

Pros: zero new CLI surface, opt-in per shell.
Cons: less discoverable, easy to forget.

### Option C: Auto-detect by terminal env

If `TERM_PROGRAM=iTerm.app` or `TERM_PROGRAM=vscode`, default to tabs; else
single-pane. Add `--no-tabs` to opt out.

Pros: "does the right thing" for the common case.
Cons: behavior depends on context, surprising. Existing users of
single-pane in iTerm2 would suddenly see tabs.

### Recommendation

**Option A** is the cleanest: explicit `--tabs` flag plus dedicated
alias. Mirrors how V1 batch already separates `rpd.p` (auto-tab via
spawn_parallel_agents) from `rpd.p.b` (force-background). Backward
compat is preserved. Discovery is via README + `--help`.

## Feasibility confidence

| Component | Confidence | Notes |
|---|---|---|
| Tab spawning | **HIGH** | `spawn_parallel_agents` is battle-tested for iTerm2 / VS Code / Windsurf / Cursor / background. Just need a single-tab variant. |
| Atomic task picking | **HIGH** | `pick_*_task_for_pool` already does this with `_acquire_task_lock`. Zero changes needed. |
| Skip-list & attempts | **HIGH** | Stays in orchestrator memory like today. Zero changes. |
| status.json hook | **HIGH** | `_continuous_update_status` already wired; just call from the new orchestrator. |
| Completion file protocol | **HIGH** | Standard atomic-write pattern; `mktemp` + `mv` is trivial. |
| Polling completion dir | **HIGH** | At N=10 workers and 0.5s poll, overhead is negligible (~20 stats/sec). No inotify dependency. |
| `--task` + completion-write hook | **MEDIUM** | New flag `--continuous-worker-id` added to all 3 engines. Adds ~20 lines per engine in the task-exit path. Mirror across Claude/Devin/Codex. |
| Heartbeat & stale detection | **MEDIUM** | New: heartbeat-write background loop in each worker, sweep logic in orchestrator. ~50 lines total. Edge cases (clock skew, slow filesystems) need testing. |
| SIGINT drain across tabs | **MEDIUM** | Orchestrator catches SIGINT, stops spawning, polls for completions until in_flight is empty. Tabs continue independently. Test on macOS where tabs don't inherit signals. |
| Crash recovery | **MEDIUM** | Existing `sweep_stale_continuous_state` handles orphaned `[~]` markers. New: GC `.completions/` and `.heartbeats/` dirs on next startup. ~20 lines. |
| Cross-platform | **LOW** | iTerm2 = macOS only. VS Code variants = macOS/Linux. Pure Linux terminals = fallback to single-pane. Document this; don't try to support every terminal. |

**Overall: HIGH confidence the design is feasible.** Main complexity is
the heartbeat / stale-detection mechanism (medium) and getting SIGINT
drain right across detached tabs (medium). No deep unknowns.

## Test plan

| Layer | Tests |
|---|---|
| Completion file protocol | atomic write under N=10 concurrent workers; orchestrator processes each completion exactly once; corrupted files are skipped |
| Tab spawning | `spawn_parallel_agents` already covered; new test for single-tab spawn with `--continuous-worker-id` |
| Orchestrator loop | M=1 with 1 task → 1 tab spawned, completion processed, orchestrator exits; M=5 with N=2 → no more than 2 tabs in-flight at once; skip-list takes effect at K |
| Heartbeat / stale detection | worker that exits without writing completion → orchestrator detects stale heartbeat after 60s, reverts task; worker that writes completion → no stale path fired |
| SIGINT drain | SIGINT during 3 in-flight tabs → orchestrator stops spawning, waits for all 3 to complete, exits cleanly with "user interrupt" stop reason |
| Crash recovery | SIGKILL orchestrator → next ralph startup sweeps `[~]` markers and GCs stale completion/heartbeat files |
| `--tabs` opt-in | `--parallel N M` (no `--tabs`) stays single-pane (byte-identical to today); `--parallel N M --tabs` engages tab mode |
| Engine parity | Same flag + behavior across Claude / Devin / Codex |

Total new tests: ~25-30. Plus updates to existing continuous tests to
verify they still pass without `--tabs`.

## Rollout

1. Land design proposal (this doc).
2. Phase A: completion-protocol primitives (write/read/poll) + tests.
3. Phase B: `--continuous-worker-id` flag in `--task` path (all 3 engines).
4. Phase C: tab-mode orchestrator in `lib/worker_pool_tabs.sh`.
5. Phase D: `--tabs` flag + aliases + README.
6. Phase E: heartbeat + stale-detection + crash-recovery GC.

Each phase ships independently with tests. Default `--parallel N M`
behavior unchanged at every phase.

## Estimated effort

| Phase | Effort |
|---|---|
| A. Completion protocol + tests | 0.5 day |
| B. Worker `--continuous-worker-id` flag (3 engines) | 1 day |
| C. Tab-mode orchestrator | 1.5 days |
| D. CLI surface + aliases + README | 0.5 day |
| E. Heartbeat / stale / GC | 1 day |
| **Total** | **~4.5 days** |

## Open questions

1. **Tab auto-close.** Some users will want tabs to auto-close on
   completion; others will want to inspect output afterward. Suggested
   default: leave open (current `spawn_parallel_agents` behavior).
   Configurable later via `RALPH_TABS_AUTOCLOSE=true`.
2. **Completion dir cleanup.** When do we GC processed completion
   files? Suggested: orchestrator deletes after processing.
3. **Heartbeat interval.** 10s write / 60s stale threshold are
   placeholders. Tune empirically once we have data.
4. **What about workspace + tabs + continuous?** `rpd.ws.p N M --tabs`
   should work the same way — orchestrator picks across repos, each tab
   handles one repo's task. No additional architecture, just verify the
   same mechanism works.
