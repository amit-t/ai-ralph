#!/usr/bin/env bash
# lib/worker_pool_tabs.sh — Tab-based continuous parallel execution
#
# This is the tab-spawning variant of lib/worker_pool.sh. Instead of running
# each worker as a background subshell inside the orchestrator, each worker is
# spawned as its own terminal tab (iTerm2 / VS Code / Windsurf / Cursor) via
# spawn_parallel_agents. Workers communicate completion to the orchestrator
# by atomically writing JSON files to .ralph/.continuous_completions/.
#
# See docs/proposals/continuous-with-tabs.md for the full design.
#
# Tab mode is the DEFAULT for `--parallel N M` when the terminal supports
# tabs (iTerm2 / VS Code-family). Plain terminals (and `--no-tabs`) fall
# back to the single-pane orchestrator in lib/worker_pool.sh.
#
# Public entry points exported at the bottom of this file:
#   run_continuous_worker_pool_tabs       # tab-mode orchestrator
#   write_completion_file                 # worker-side: atomic JSON write
#   read_completion_files                 # orchestrator-side: scan dir
#   delete_completion_file                # orchestrator-side: GC after processing
#   write_heartbeat                       # worker-side: bump mtime
#   start_heartbeat_writer                # worker-side: spawn background tick
#   stop_heartbeat_writer                 # worker-side: terminate ticker
#   heartbeat_age_seconds                 # orchestrator-side: mtime delta
#   is_heartbeat_stale                    # orchestrator-side: bool check
#   gc_stale_continuous_artifacts         # startup sweep helper
#   generate_worker_id                    # uniqueness helper
#   worker_init_completion_protocol       # engine-side: install traps + heartbeat
#   worker_exit_handler                   # engine-side: write completion on exit
#   tabs_supported_by_terminal            # engine-side: dispatch decision

# This file depends on lib/worker_pool.sh for shared state primitives
# (init_continuous_state, record_inflight, clear_inflight, cleanup_continuous_state,
# _continuous_emit_summary, _skip_list_contains, _continuous_state_file). The
# expectation is that callers source lib/worker_pool.sh first, then this file.

# =============================================================================
# Configuration knobs (override via env)
# =============================================================================

# Polling interval for the completion-dir scan (seconds, float OK).
: "${WORKER_POOL_TABS_POLL_INTERVAL:=0.5}"

# Heartbeat write interval (seconds). Workers bump their heartbeat file
# this often. Tuning down trades fewer fs writes for slower stale-detection.
: "${WORKER_POOL_TABS_HEARTBEAT_INTERVAL:=10}"

# Heartbeat staleness threshold (seconds). A worker whose heartbeat mtime
# is older than this is declared dead by the orchestrator. Should be a
# comfortable multiple of HEARTBEAT_INTERVAL to absorb fs latency / GC pauses.
: "${WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS:=60}"

# =============================================================================
# Path helpers
# =============================================================================

_tabs_completions_dir() {
    echo "${RALPH_DIR:-.ralph}/.continuous_completions"
}

_tabs_heartbeats_dir() {
    echo "${RALPH_DIR:-.ralph}/.continuous_heartbeats"
}

# =============================================================================
# Worker ID generation
# =============================================================================
#
# A worker_id is unique within the lifetime of the orchestrator. We combine
# a caller-supplied tag (typically slot index + epoch) with a 4-digit random
# suffix so concurrent spawns in the same second never collide.
generate_worker_id() {
    local tag="${1:-ws}"
    local rand=$(( RANDOM % 10000 ))
    printf '%s-%s-%04d' "$tag" "$(date +%s)" "$rand"
}

# =============================================================================
# Completion protocol — worker side
# =============================================================================
#
# write_completion_file
#   Atomically writes a completion JSON to .ralph/.continuous_completions/.
#   Args (positional):
#     $1 - worker_id (required)
#     $2 - task_id (required, may be empty string)
#     $3 - line_num (required, may be 0)
#     $4 - rc (required, integer exit code)
#     $5 - started_at (required, epoch seconds)
#     $6 - tab_pid (optional, defaults to $$)
#     $7 - changes_detected (optional, "true"|"false", defaults to "false")
#
# Implementation:
#   We write to <wid>-<ended_at>.json.tmp first, then rename it to the final
#   name. This is POSIX-atomic on the same filesystem and guarantees the
#   orchestrator only ever sees a complete file.
write_completion_file() {
    local worker_id="$1"
    local task_id="$2"
    local line_num="${3:-0}"
    local rc="$4"
    local started_at="$5"
    local tab_pid="${6:-$$}"
    local changes_detected="${7:-false}"

    if [[ -z "$worker_id" || -z "$rc" || -z "$started_at" ]]; then
        echo "write_completion_file: missing required args" >&2
        return 1
    fi

    local dir
    dir=$(_tabs_completions_dir)
    mkdir -p "$dir" 2>/dev/null

    local now
    now=$(date +%s)
    local final="${dir}/${worker_id}-${now}.json"
    local tmp="${final}.tmp"

    # Hand-rolled JSON — no jq dependency. The fields are simple scalars,
    # and the schema matches docs/proposals/continuous-with-tabs.md §Completion protocol.
    # task_id is the only field that may contain quotes; escape minimally.
    local esc_task_id
    esc_task_id=$(printf '%s' "$task_id" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$tmp" << EOF
{
  "worker_id": "${worker_id}",
  "task_id": "${esc_task_id}",
  "line_num": ${line_num},
  "rc": ${rc},
  "started_at": ${started_at},
  "ended_at": ${now},
  "tab_pid": ${tab_pid},
  "changes_detected": ${changes_detected}
}
EOF
    mv "$tmp" "$final"
}

# =============================================================================
# Completion protocol — orchestrator side
# =============================================================================
#
# read_completion_files
#   Echoes the names (not paths) of every completion JSON in the dir, one per
#   line, sorted by oldest mtime first so older completions are processed
#   first. Skips .tmp files (workers in mid-write).
#   The orchestrator parses each file with awk/sed (no jq) and removes it
#   via delete_completion_file once consumed.
read_completion_files() {
    local dir
    dir=$(_tabs_completions_dir)
    [[ -d "$dir" ]] || return 0
    # `find` portable across macOS / Linux: ignore .tmp files, sort by mtime.
    # macOS BSD find doesn't support -printf; use stat after the fact.
    # We use -newer/oldest via a Python-free shell sort: ls -t reverses to
    # newest first, so use `ls -tr` (reverse mtime = oldest first).
    # Note: filenames are timestamp-tagged so lexical sort is also acceptable.
    ( cd "$dir" 2>/dev/null && ls -1tr 2>/dev/null | grep -v '\.tmp$' || true )
}

delete_completion_file() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    local dir
    dir=$(_tabs_completions_dir)
    rm -f "${dir}/${name}" 2>/dev/null || true
}

# parse_completion_file <file_path> — emits TAB-separated KV pairs that
# callers can read into shell vars. Echoes nothing on parse error.
#
# Fields emitted (one per line, tab-delimited):
#   worker_id <TAB> <value>
#   task_id   <TAB> <value>
#   line_num  <TAB> <int>
#   rc        <TAB> <int>
#   started_at <TAB> <int>
#   ended_at  <TAB> <int>
#   tab_pid   <TAB> <int>
#   changes_detected <TAB> <bool>
parse_completion_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    # JSON is flat/simple — use sed for portable extraction (gawk's 3-arg
    # match() is not available on macOS BSD awk). We emit TAB-separated
    # `key<TAB>value` pairs for every field present in the file.
    local key
    for key in worker_id task_id; do
        local v
        v=$(sed -n "s/.*\"${key}\": *\"\\(.*\\)\".*/\\1/p" "$file" 2>/dev/null | head -1)
        [[ -n "$v" ]] && printf '%s\t%s\n' "$key" "$v"
    done
    for key in line_num rc started_at ended_at tab_pid; do
        local v
        v=$(sed -n "s/.*\"${key}\": *\\(-\\{0,1\\}[0-9][0-9]*\\).*/\\1/p" "$file" 2>/dev/null | head -1)
        [[ -n "$v" ]] && printf '%s\t%s\n' "$key" "$v"
    done
    local cd
    # BSD sed doesn't support `\|` alternation; use -E (extended regex).
    cd=$(sed -En 's/.*"changes_detected": *(true|false).*/\1/p' "$file" 2>/dev/null | head -1)
    [[ -n "$cd" ]] && printf 'changes_detected\t%s\n' "$cd"
}

# =============================================================================
# Worker-mode lifecycle helpers (called by engine entry points)
# =============================================================================
#
# When an engine is launched with `--continuous-worker-id WID`, it acts as a
# worker tab. The lifecycle is:
#
#   1. worker_init_completion_protocol — records started_at, spawns the
#      heartbeat writer, installs an EXIT/INT/TERM trap that writes the
#      completion JSON on exit (with the engine's $? as rc).
#   2. The engine runs its normal --task / workspace-task path. On exit
#      (any rc), the trap fires.
#   3. worker_exit_handler — invoked by the trap. Stops the heartbeat
#      writer, writes the completion file, cleans up heartbeat file.
#
# Globals used (set by engine before calling worker_init_completion_protocol):
#   CONTINUOUS_WORKER_ID      — string, required, the worker's unique ID
#   CONTINUOUS_WORKER_TASK_ID — string, the task ID the worker is running
#   CONTINUOUS_WORKER_LINE_NUM— int, the line number in fix_plan.md (or 0)

worker_init_completion_protocol() {
    if [[ -z "${CONTINUOUS_WORKER_ID:-}" ]]; then
        echo "worker_init_completion_protocol: CONTINUOUS_WORKER_ID is required" >&2
        return 1
    fi
    CONTINUOUS_WORKER_STARTED_AT=$(date +%s)
    export CONTINUOUS_WORKER_STARTED_AT
    # Write the first heartbeat synchronously so the orchestrator's
    # stale-detection sweep never sees a missing-file false-positive on a
    # freshly spawned worker. Then start the background ticker.
    write_heartbeat "$CONTINUOUS_WORKER_ID"
    CONTINUOUS_WORKER_HB_PID=$(start_heartbeat_writer "$CONTINUOUS_WORKER_ID")
    export CONTINUOUS_WORKER_HB_PID
    # Trap fires on every exit path; we re-set the worker_id local to
    # avoid recursing if the handler itself bails.
    trap '_worker_exit_trap' EXIT
    trap '_worker_signal_trap INT' INT
    trap '_worker_signal_trap TERM' TERM
}

_worker_exit_trap() {
    local rc=$?
    worker_exit_handler "$rc"
    exit "$rc"
}

_worker_signal_trap() {
    local sig="$1"
    # Use rc 130 for SIGINT, 143 for SIGTERM (POSIX convention 128+signum).
    case "$sig" in
        INT)  worker_exit_handler 130 ;;
        TERM) worker_exit_handler 143 ;;
        *)    worker_exit_handler 1   ;;
    esac
    # Restore default and re-raise to let the parent see the actual signal.
    trap - "$sig"
    kill "-${sig}" $$ 2>/dev/null || exit 1
}

worker_exit_handler() {
    local rc="${1:-$?}"
    # Idempotent — second invocations (e.g. EXIT after SIGINT-handler) no-op.
    [[ -z "${CONTINUOUS_WORKER_ID:-}" ]] && return 0

    if [[ -n "${CONTINUOUS_WORKER_HB_PID:-}" ]]; then
        stop_heartbeat_writer "$CONTINUOUS_WORKER_HB_PID"
        CONTINUOUS_WORKER_HB_PID=""
    fi

    write_completion_file \
        "$CONTINUOUS_WORKER_ID" \
        "${CONTINUOUS_WORKER_TASK_ID:-}" \
        "${CONTINUOUS_WORKER_LINE_NUM:-0}" \
        "$rc" \
        "${CONTINUOUS_WORKER_STARTED_AT:-$(date +%s)}" \
        "$$" \
        "false" 2>/dev/null || true

    delete_heartbeat "$CONTINUOUS_WORKER_ID" 2>/dev/null || true

    # Mark the ID consumed so EXIT-trap re-entry doesn't re-write.
    CONTINUOUS_WORKER_ID=""
}

# =============================================================================
# Heartbeat protocol
# =============================================================================
#
# write_heartbeat <worker_id>
#   Touches .ralph/.continuous_heartbeats/<worker_id> (bumps mtime).
write_heartbeat() {
    local worker_id="$1"
    [[ -z "$worker_id" ]] && return 1
    local dir
    dir=$(_tabs_heartbeats_dir)
    mkdir -p "$dir" 2>/dev/null
    : > "${dir}/${worker_id}"  # truncate-or-create
    touch "${dir}/${worker_id}" 2>/dev/null || true
}

# start_heartbeat_writer <worker_id> — spawns a background loop that bumps
# the heartbeat every $WORKER_POOL_TABS_HEARTBEAT_INTERVAL seconds. Echoes
# the writer's PID on stdout so the caller can stop it later.
start_heartbeat_writer() {
    local worker_id="$1"
    [[ -z "$worker_id" ]] && return 1
    (
        # Detach from controlling terminal so the writer keeps ticking
        # even if the parent's stdin/stdout closes.
        while true; do
            write_heartbeat "$worker_id"
            sleep "${WORKER_POOL_TABS_HEARTBEAT_INTERVAL}"
        done
    ) >/dev/null 2>&1 &
    echo "$!"
}

stop_heartbeat_writer() {
    local pid="$1"
    [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && return 0
    kill "$pid" 2>/dev/null || true
    # Best-effort reap to avoid zombie.
    wait "$pid" 2>/dev/null || true
}

# heartbeat_age_seconds <worker_id> — echoes the heartbeat file's age in
# seconds, or "-1" if the file doesn't exist.
heartbeat_age_seconds() {
    local worker_id="$1"
    local dir
    dir=$(_tabs_heartbeats_dir)
    local file="${dir}/${worker_id}"
    [[ -f "$file" ]] || { echo "-1"; return; }
    local now mtime
    now=$(date +%s)
    # GNU stat vs. BSD stat — try both.
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0")
    [[ -z "$mtime" || "$mtime" == "0" ]] && { echo "-1"; return; }
    echo $(( now - mtime ))
}

is_heartbeat_stale() {
    local worker_id="$1"
    local threshold="${2:-${WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS}}"
    local age
    age=$(heartbeat_age_seconds "$worker_id")
    # Missing heartbeat (age == -1) counts as stale ONLY if the worker has
    # had time to write its first one. Callers track "expected to be live"
    # separately; we just answer the mtime question.
    [[ "$age" == "-1" ]] && return 0
    [[ $age -gt $threshold ]]
}

# delete_heartbeat <worker_id> — cleanup after worker completes.
delete_heartbeat() {
    local worker_id="$1"
    [[ -z "$worker_id" ]] && return 1
    local dir
    dir=$(_tabs_heartbeats_dir)
    rm -f "${dir}/${worker_id}" 2>/dev/null || true
}

# =============================================================================
# Startup GC — sweep stale completion / heartbeat dirs
# =============================================================================
#
# gc_stale_continuous_artifacts
#   Called at the top of each ralph entrypoint. Removes any orphaned
#   completion / heartbeat files left behind by a previous run. Cheap:
#   typically a no-op (the orchestrator deletes completions inline as it
#   processes them, and clears heartbeats on success). Bounded to avoid
#   blocking startup if the dirs somehow grew large.
gc_stale_continuous_artifacts() {
    local comp_dir hb_dir
    comp_dir=$(_tabs_completions_dir)
    hb_dir=$(_tabs_heartbeats_dir)

    # Only sweep when the orchestrator state file is absent (no live
    # orchestrator). If a live orchestrator exists, leave these alone — it
    # owns them.
    local state_file="${RALPH_DIR:-.ralph}/.continuous_state"
    if [[ -f "$state_file" ]]; then
        local orch_pid
        orch_pid=$(awk -F'\t' '$1 == "orchestrator_pid" { print $2; exit }' "$state_file" 2>/dev/null)
        if [[ -n "$orch_pid" && "$orch_pid" =~ ^[0-9]+$ ]] && kill -0 "$orch_pid" 2>/dev/null; then
            return 0
        fi
    fi

    [[ -d "$comp_dir" ]] && rm -f "$comp_dir"/* 2>/dev/null
    [[ -d "$hb_dir" ]] && rm -f "$hb_dir"/* 2>/dev/null
    return 0
}

# =============================================================================
# Tab spawning
# =============================================================================
#
# _spawn_worker_tab <worker_id> <task_id> <line_num> <descriptor>
#   Spawns ONE worker tab running the engine in --continuous-worker-id mode.
#   Uses spawn_parallel_agents with count=1 so we reuse the existing iTerm2
#   / VS Code / Windsurf / Cursor / background dispatch.
#
#   Mode is decided by the global RALPH_TABS_WORKSPACE_MODE:
#     - "true"  → workspace worker: `--workspace-task <descriptor>`
#     - other   → single-repo worker: `--task <task_id>`
#
#   Globals read:
#     RALPH_TABS_ENGINE_CMD       — "ralph" | "ralph-devin" | "ralph-codex"
#     RALPH_TABS_WORKSPACE_MODE   — "true" for workspace, anything else for single-repo
#     RALPH_TABS_EXTRA_ARGS       — extra flags to forward (space-separated)
_spawn_worker_tab() {
    local worker_id="$1"
    local task_id="$2"
    local line_num="$3"
    local descriptor="$4"
    local engine_cmd="${RALPH_TABS_ENGINE_CMD:-ralph}"

    local -a args=()
    args+=("--continuous-worker-id" "$worker_id")

    if [[ "${RALPH_TABS_WORKSPACE_MODE:-false}" == "true" ]]; then
        # Workspace worker: pass the FULL descriptor so the worker can
        # cd into the right repo and mark the right line on completion.
        args+=("--workspace-task" "$descriptor")
    else
        # Single-repo worker: route via --task <task_id> so the engine
        # finds the task by ID (more robust against fix_plan.md edits).
        if [[ -n "$task_id" ]]; then
            args+=("--task" "$task_id")
        fi
    fi

    # Pass through engine-specific flags (e.g. --live, --quality-gates).
    if [[ -n "${RALPH_TABS_EXTRA_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        local -a _extras=( $RALPH_TABS_EXTRA_ARGS )
        args+=("${_extras[@]}")
    fi

    # Use spawn_parallel_agents (count=1) so the existing tab-detection
    # logic (iTerm2 / VS Code / Windsurf / Cursor / background) is reused.
    # When the terminal doesn't support tabs or PARALLEL_BG=true, this
    # falls back to a background subprocess and tee's output to a per-worker log.
    if declare -F spawn_parallel_agents >/dev/null 2>&1; then
        # spawn_parallel_agents prints status; suppress to keep the
        # orchestrator's per-completion telemetry clean.
        spawn_parallel_agents 1 "$engine_cmd" "${args[@]}" >/dev/null 2>&1 &
        return 0
    fi

    # Fallback: degraded background mode for tests / minimal environments
    # that don't source lib/parallel_spawn.sh.
    ( "$engine_cmd" "${args[@]}" ) >/dev/null 2>&1 &
    return 0
}

# =============================================================================
# Orchestrator: run_continuous_worker_pool_tabs
# =============================================================================
#
# Same calling convention as run_continuous_worker_pool. Picker / executor
# / on_complete are functions defined by the caller. The key difference:
# instead of running executor in a forked subshell, we delegate execution
# to a freshly-spawned tab and wait for it to drop a completion file.
#
# The executor_fn argument is still accepted for API parity but is IGNORED
# in tab mode — the tab itself runs the engine's --task path. Callers that
# need an in-process executor must use lib/worker_pool.sh's variant.
#
# Args (positional, all required):
#   $1 - max_concurrent_N      : integer ≥ 1
#   $2 - max_total_attempts_M  : integer ≥ 1
#   $3 - max_attempts_per_task : integer ≥ 1 (skip threshold)
#   $4 - respawn_delay_seconds : integer ≥ 0 (or float)
#   $5 - picker_fn             : name of picker function (receives skip_list)
#   $6 - executor_fn           : IGNORED in tab mode (preserved for API parity)
#   $7 - on_complete_fn        : name of post-completion hook (descriptor + rc)
#
# Pre-conditions (set by the caller):
#   RALPH_TABS_ENGINE_CMD       — engine binary name (e.g. "ralph", "ralph-devin")
#   RALPH_TABS_WORKSPACE_MODE   — "true" for workspace tabs, else single-repo
#   RALPH_TABS_EXTRA_ARGS       — pass-through flags (optional, space-separated)
#
# Returns:
#   0 on overall success (succeeded == completed).
#   1 if any attempt failed.
#   2 if another orchestrator is already running.
run_continuous_worker_pool_tabs() {
    local N="$1"
    local M="$2"
    local K="$3"
    local respawn_delay="$4"
    local picker_fn="$5"
    # $6 - executor_fn (intentionally unused in tab mode)
    local on_complete_fn="$7"

    if [[ -z "$N" || -z "$M" || -z "$K" || -z "$respawn_delay" \
        || -z "$picker_fn" || -z "$on_complete_fn" ]]; then
        echo "ERROR: run_continuous_worker_pool_tabs requires 7 positional args (executor_fn may be empty)" >&2
        return 2
    fi

    # Per-slot state. Parallel arrays so we work on bash 3.2 (no assoc arrays).
    local -a worker_ids=()
    local -a worker_tasks=()
    local -a worker_task_ids=()
    local -a worker_line_nums=()
    local -a worker_started_at=()
    local -a worker_alive=()         # "true" while we expect a completion
    local i
    for ((i = 0; i < N; i++)); do
        worker_ids[i]=""
        worker_tasks[i]=""
        worker_task_ids[i]=""
        worker_line_nums[i]=""
        worker_started_at[i]=""
        worker_alive[i]="false"
    done

    local completed=0 succeeded=0 failed=0 skipped=0 inflight=0
    local skip_list=""
    local -a _att_id=()
    local -a _att_count=()
    local stop_reason=""
    local start_epoch
    start_epoch=$(date +%s)

    # Acquire the orchestrator-singleton lock via init_continuous_state.
    local _init_rc=0
    init_continuous_state $$ || _init_rc=$?
    if [[ "$_init_rc" == "2" ]]; then
        return 2
    fi

    # Wipe stale completion / heartbeat artifacts from any previous run.
    mkdir -p "$(_tabs_completions_dir)" "$(_tabs_heartbeats_dir)"
    rm -f "$(_tabs_completions_dir)"/* 2>/dev/null || true
    rm -f "$(_tabs_heartbeats_dir)"/* 2>/dev/null || true

    _maybe_update_status_tabs() {
        if declare -F _continuous_update_status >/dev/null 2>&1; then
            _continuous_update_status "$@" 2>/dev/null || true
        fi
    }
    _maybe_update_status_tabs "continuous:starting" "running" 0 "$M" "$N"

    local _prev_int_trap _prev_term_trap
    _prev_int_trap=$(trap -p INT 2>/dev/null || true)
    _prev_term_trap=$(trap -p TERM 2>/dev/null || true)
    local _interrupted=false
    _tabs_handle_signal() {
        _interrupted=true
        echo "[continuous-tabs] received signal — draining only, no new spawns" >&2
    }
    trap _tabs_handle_signal INT TERM

    _tabs_attempts_increment() {
        local id="$1"
        local idx
        for ((idx = 0; idx < ${#_att_id[@]}; idx++)); do
            if [[ "${_att_id[$idx]}" == "$id" ]]; then
                _att_count[$idx]=$(( ${_att_count[$idx]} + 1 ))
                _ATTEMPTS_LAST="${_att_count[$idx]}"
                return
            fi
        done
        _att_id+=("$id")
        _att_count+=(1)
        _ATTEMPTS_LAST="1"
    }

    # _tabs_assign_slot <slot> <descriptor>
    #   Parses task_id / line_num out of descriptor (formats are
    #   engine-specific; we delegate to RALPH_TABS_PARSE_FN if defined,
    #   otherwise use a default best-effort).
    _tabs_assign_slot() {
        local slot="$1"
        local descriptor="$2"

        local task_id="" line_num=""
        if declare -F "${RALPH_TABS_PARSE_FN:-_tabs_default_parse}" >/dev/null 2>&1; then
            local parsed
            parsed=$("${RALPH_TABS_PARSE_FN:-_tabs_default_parse}" "$descriptor")
            task_id=$(echo "$parsed" | cut -d'|' -f1)
            line_num=$(echo "$parsed" | cut -d'|' -f2)
        fi

        local wid
        wid=$(generate_worker_id "ws-${slot}")
        worker_ids[$slot]="$wid"
        worker_tasks[$slot]="$descriptor"
        worker_task_ids[$slot]="$task_id"
        worker_line_nums[$slot]="$line_num"
        worker_started_at[$slot]=$(date +%s)
        worker_alive[$slot]="true"

        # P1 #5: pass the unique worker_id (wid) as the 4th field rather than
        # the hard-coded "0". With "0" every tab worker shared the same key,
        # so any clear_inflight "0" call deleted every in-flight row at once.
        # Now the row is keyed on wid; clear_inflight "$wid" only removes
        # this worker's entry. (The state-file column is called "worker_pid"
        # for historical reasons; in tab mode it holds a wid string.)
        record_inflight "${line_num:-0}" "${task_id:-${descriptor%% *}}" "$wid" 2>/dev/null || true

        _spawn_worker_tab "$wid" "$task_id" "$line_num" "$descriptor"
        inflight=$((inflight + 1))
    }

    # Default descriptor parser. Echoes "task_id|line_num".
    #   Single-repo descriptor format: "task_id|line_num|bead_id"
    #   Workspace descriptor format:   "repo_name|task_id|line_num|desc"
    # The orchestrator decides which is which via RALPH_TABS_WORKSPACE_MODE,
    # so we don't have to guess by field count here — just slice accordingly.
    #
    # P2 #16: replaced the 4 `cut -d'|'` subshell invocations per call with a
    # single `IFS='|' read` (no subshells, no forks). Identical output.
    _tabs_default_parse() {
        local descriptor="$1"
        local f1 f2 f3 _rest
        IFS='|' read -r f1 f2 f3 _rest <<< "$descriptor"
        if [[ "${RALPH_TABS_WORKSPACE_MODE:-false}" == "true" ]]; then
            # workspace: skip f1 (repo), echo task_id|line_num.
            echo "${f2}|${f3}"
        else
            # single-repo: f1=task_id, f2=line_num.
            echo "${f1}|${f2}"
        fi
    }

    # _tabs_process_completion <file_name>
    #   Parses the JSON, updates counters, applies skip-list rule, fires
    #   the on-complete hook, and deletes the file. Identifies the slot
    #   by worker_id (we don't track tab PID since spawn_parallel_agents
    #   in tab mode doesn't expose it reliably).
    #
    #   Returns the freed slot index in the global $_TABS_LAST_SLOT
    #   (range 0..N-1 on success, -1 on the orphan / no-op path). Using a
    #   global instead of $? avoids the slot-0 vs return-code-0 collision
    #   the caller previously had on the orphan-completion path, where
    #   `return 0` was indistinguishable from "slot 0 freed" and would
    #   cause a worker to be spawned into an already-occupied slot.
    _tabs_process_completion() {
        local comp_name="$1"
        _TABS_LAST_SLOT=-1   # default: no slot freed; caller must NOT respawn

        local comp_path
        comp_path="$(_tabs_completions_dir)/${comp_name}"
        [[ -f "$comp_path" ]] || return 1

        local fields wid task_id line_num rc started_at
        # Parse into shell vars.
        wid=""
        task_id=""
        line_num="0"
        rc="1"
        started_at="0"
        while IFS=$'\t' read -r key val; do
            case "$key" in
                worker_id)  wid="$val" ;;
                task_id)    task_id="$val" ;;
                line_num)   line_num="$val" ;;
                rc)         rc="$val" ;;
                started_at) started_at="$val" ;;
            esac
        done < <(parse_completion_file "$comp_path")

        # Find slot for this worker_id.
        local slot=-1
        local s
        for ((s = 0; s < ${#worker_ids[@]}; s++)); do
            if [[ "${worker_ids[$s]}" == "$wid" ]]; then
                slot="$s"
                break
            fi
        done

        if [[ "$slot" == "-1" ]]; then
            # Unknown worker_id — orphaned completion. GC and move on.
            # _TABS_LAST_SLOT stays -1 so the caller's freed_slot check
            # rejects this iteration (no respawn).
            delete_completion_file "$comp_name"
            return 0
        fi

        completed=$((completed + 1))
        inflight=$((inflight - 1))
        local descriptor="${worker_tasks[$slot]}"

        echo "[continuous-tabs] completed=${completed}/${M} succeeded=${succeeded} failed=${failed} skipped=${skipped} in_flight=${inflight} worker=${wid} task=\"${descriptor}\" rc=${rc}"

        "$on_complete_fn" "$descriptor" "$rc" 2>/dev/null || true

        # Tear down state for this worker.
        worker_ids[$slot]=""
        worker_tasks[$slot]=""
        worker_task_ids[$slot]=""
        worker_line_nums[$slot]=""
        worker_started_at[$slot]=""
        worker_alive[$slot]="false"
        # P1 #5: clear by the unique worker_id, not the hard-coded "0"
        # that previously matched every in-flight tab row at once.
        clear_inflight "$wid" 2>/dev/null || true
        delete_heartbeat "$wid"
        delete_completion_file "$comp_name"

        _maybe_update_status_tabs "continuous:executing" "running" "$completed" "$M" "$N"

        if [[ "$rc" == "0" ]]; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            # P1 #8: route through _continuous_skip_key (from
            # lib/worker_pool.sh) so tabs and single-pane orchestrators use
            # the same skip-key shape AND match what the pickers check.
            # Workspace → repo|task_id|line; single-repo → task_id;
            # pipe-less / test-mock descriptors → first-space-prefix.
            #
            # Previously tabs orchestrator used `${task_id:-${descriptor%% *}}`
            # which (a) collided across repos for workspace tasks sharing a
            # slug and (b) silently mis-matched the picker's check when the
            # task description changed between picks.
            local task_key
            task_key=$(_continuous_skip_key "$descriptor")
            _ATTEMPTS_LAST=""
            _tabs_attempts_increment "$task_key"
            if [[ "$_ATTEMPTS_LAST" -ge "$K" ]]; then
                skip_list="${skip_list}${task_key}"$'\n'
                skipped=$((skipped + 1))
                echo "[continuous-tabs] skip-list += ${task_key} (failed ${_ATTEMPTS_LAST} ≥ K=${K})"
            fi
        fi
        _TABS_LAST_SLOT="$slot"
        return 0
    }

    # _tabs_check_stale_workers — declare any worker with a stale heartbeat
    # dead, synthesize a rc=124 (timeout-ish) completion for it.
    _tabs_check_stale_workers() {
        local s wid age
        for ((s = 0; s < ${#worker_ids[@]}; s++)); do
            wid="${worker_ids[$s]}"
            [[ -z "$wid" ]] && continue
            [[ "${worker_alive[$s]}" == "true" ]] || continue
            # Allow new workers a grace period before we expect a heartbeat.
            local grace=$(( ${WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS} + ${WORKER_POOL_TABS_HEARTBEAT_INTERVAL} ))
            local elapsed=$(( $(date +%s) - ${worker_started_at[$s]:-0} ))
            [[ $elapsed -lt $grace ]] && continue
            age=$(heartbeat_age_seconds "$wid")
            if [[ "$age" == "-1" || $age -gt ${WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS} ]]; then
                echo "[continuous-tabs] stale heartbeat for worker=${wid} (age=${age}s) — declaring dead" >&2
                # Synthesize a completion file so the regular path handles it.
                write_completion_file "$wid" "${worker_task_ids[$s]}" "${worker_line_nums[$s]:-0}" 124 \
                    "${worker_started_at[$s]:-0}" 0 "false"
            fi
        done
    }

    # ── Initial fill ──────────────────────────────────────────────────────────
    for ((i = 0; i < N; i++)); do
        [[ "$_interrupted" == "true" ]] && break
        if [[ $((completed + inflight)) -ge $M ]]; then
            break
        fi
        local task
        task=$("$picker_fn" "$skip_list" 2>/dev/null) || task=""
        if [[ -z "$task" ]]; then
            break
        fi
        _tabs_assign_slot "$i" "$task"
    done

    if [[ $inflight -eq 0 ]]; then
        stop_reason="queue empty"
        _continuous_emit_summary "$N" "$M" "$completed" "$succeeded" "$failed" "$skipped" "$start_epoch" "$stop_reason"
        _maybe_update_status_tabs "continuous:completed" "stopped" "$completed" "$M" "$N" "$stop_reason"
        cleanup_continuous_state
        eval "${_prev_int_trap:-trap - INT}"
        eval "${_prev_term_trap:-trap - TERM}"
        return 0
    fi

    # ── Main loop ─────────────────────────────────────────────────────────────
    # P2 #11: track last stale-heartbeat sweep time so the cadence is
    # decoupled from completion traffic. The previous logic only ran the
    # sweep on cycles where no completion was processed; a steady stream of
    # completions would starve stale-detection indefinitely. We now run the
    # sweep on its own clock (every $WORKER_POOL_TABS_HEARTBEAT_INTERVAL
    # seconds), independent of completion volume.
    local last_stale_sweep_epoch
    last_stale_sweep_epoch=$(date +%s)
    local _stale_sweep_interval="${WORKER_POOL_TABS_HEARTBEAT_INTERVAL:-10}"
    while [[ $inflight -gt 0 ]]; do
        # Poll the completion dir.
        local pending
        pending=$(read_completion_files)
        local processed_any=false
        if [[ -n "$pending" ]]; then
            while IFS= read -r comp_name; do
                [[ -z "$comp_name" ]] && continue
                _TABS_LAST_SLOT=-1
                _tabs_process_completion "$comp_name"
                # Read freed slot from the global; $? is no longer the slot
                # index (see _tabs_process_completion's docstring for why).
                local freed_slot="${_TABS_LAST_SLOT:--1}"
                processed_any=true
                # Maybe spawn replacement.
                if [[ "$_interrupted" != "true" \
                    && $completed -lt $M \
                    && $((completed + inflight)) -lt $M \
                    && "$freed_slot" -ge 0 \
                    && "$freed_slot" -lt $N ]]; then
                    if [[ $(awk -v d="$respawn_delay" 'BEGIN { print (d > 0) ? 1 : 0 }') == "1" ]]; then
                        sleep "$respawn_delay" 2>/dev/null || true
                    fi
                    local next_task
                    next_task=$("$picker_fn" "$skip_list" 2>/dev/null) || next_task=""
                    if [[ -n "$next_task" ]]; then
                        _tabs_assign_slot "$freed_slot" "$next_task"
                    fi
                fi
            done <<< "$pending"
        fi

        # P2 #11: stale heartbeat sweep on its own clock — runs whenever
        # $_stale_sweep_interval seconds have elapsed since the last sweep,
        # independent of completion traffic. The previous logic gated the
        # sweep on "no completion processed this cycle", so a steady stream
        # of completions could starve stale-detection indefinitely.
        # Safe to run after completion processing because
        # _tabs_process_completion clears worker_ids[$slot] and sets
        # worker_alive[$slot]="false" for the completed slot — the sweep's
        # per-slot guards skip those entries by design.
        local now_epoch
        now_epoch=$(date +%s)
        if [[ $((now_epoch - last_stale_sweep_epoch)) -ge $_stale_sweep_interval ]]; then
            _tabs_check_stale_workers
            last_stale_sweep_epoch="$now_epoch"
        fi
        # Backoff sleep only when no completion was processed (avoid
        # spinning when the queue is empty), as before.
        if [[ "$processed_any" == "false" ]]; then
            sleep "$WORKER_POOL_TABS_POLL_INTERVAL" 2>/dev/null || true
        fi

        # Decide drain conditions.
        if [[ "$_interrupted" == "true" ]]; then
            stop_reason="user interrupt"
        elif [[ $completed -ge $M ]]; then
            stop_reason="target reached (M)"
        elif [[ $((completed + inflight)) -ge $M && $inflight -gt 0 ]]; then
            stop_reason="${stop_reason:-target reached (M)}"
        fi
    done

    if [[ -z "$stop_reason" ]]; then
        if [[ $completed -ge $M ]]; then
            stop_reason="target reached (M)"
        else
            stop_reason="queue empty"
        fi
    fi

    _continuous_emit_summary "$N" "$M" "$completed" "$succeeded" "$failed" "$skipped" "$start_epoch" "$stop_reason"
    _maybe_update_status_tabs "continuous:completed" "stopped" "$completed" "$M" "$N" "$stop_reason"
    cleanup_continuous_state
    eval "${_prev_int_trap:-trap - INT}"
    eval "${_prev_term_trap:-trap - TERM}"

    if [[ $succeeded -eq $completed ]]; then
        return 0
    fi
    return 1
}

# =============================================================================
# Terminal-environment helper
# =============================================================================
#
# tabs_supported_by_terminal — returns 0 if the current terminal can host
# per-worker tabs, 1 otherwise. Mirrors detect_terminal_env from
# lib/parallel_spawn.sh but explicitly carves out a "supported" answer
# so the engine dispatch can decide tabs-vs-fallback up front.
tabs_supported_by_terminal() {
    [[ "${RALPH_DISABLE_TABS:-false}" == "true" ]] && return 1
    if declare -F detect_terminal_env >/dev/null 2>&1; then
        local env
        env=$(detect_terminal_env)
        case "$env" in
            iterm) return 0 ;;
            ide)
                # IDE only counts as supported if we can detect the app
                # name (Windsurf / Cursor / VS Code). Otherwise fall back.
                declare -F detect_ide_app_name >/dev/null 2>&1 \
                    && detect_ide_app_name >/dev/null 2>&1 \
                    && return 0
                return 1
                ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

# =============================================================================
# Exports
# =============================================================================

export -f _tabs_completions_dir
export -f _tabs_heartbeats_dir
export -f generate_worker_id
export -f write_completion_file
export -f read_completion_files
export -f delete_completion_file
export -f parse_completion_file
export -f write_heartbeat
export -f start_heartbeat_writer
export -f stop_heartbeat_writer
export -f heartbeat_age_seconds
export -f is_heartbeat_stale
export -f delete_heartbeat
export -f gc_stale_continuous_artifacts
export -f _spawn_worker_tab
export -f run_continuous_worker_pool_tabs
export -f tabs_supported_by_terminal
export -f worker_init_completion_protocol
export -f worker_exit_handler
export -f _worker_exit_trap
export -f _worker_signal_trap
