#!/usr/bin/env bash
# lib/worker_pool.sh — Continuous parallel execution worker pool
#
# Implements a bounded continuous worker pool that keeps ≤ N workers running,
# spawning a replacement as soon as one finishes, until M total attempts are
# spent or the picker returns no more tasks.
#
# See docs/proposals/continuous-parallel-execution.md for the full design.
#
# This file intentionally avoids bash 4 features (associative arrays, wait -n
# without polling fallback, etc.) so it works on macOS's bash 3.2.

# Public entry points exported at the bottom of this file:
#   run_continuous_worker_pool
#   _wait_for_any
#   _atomic_inc_call_count
#   init_continuous_state
#   record_inflight
#   clear_inflight
#   cleanup_continuous_state

# =============================================================================
# Internal: cross-version wait-for-any
# =============================================================================
#
# Sets _WAIT_FOR_ANY_SLOT and _WAIT_FOR_ANY_RC to the slot index and exit
# code of the first PID in the caller's pids array that has exited.
# Returns 0. Echoes "<slot> <rc>" on stdout for compatibility with callers
# that prefer command-substitution semantics — when used that way, the
# captured exit code is the rc of `wait` from the polling subshell, which
# is meaningless because the awaited PIDs are children of the OUTER shell,
# not the subshell. Production callers should rely on the global vars.
#
# Bash 4.3+ has `wait -n` but we don't rely on it — the polling
# implementation works everywhere and is bounded by `WORKER_POOL_POLL_INTERVAL`
# seconds (default 0.5), negligible vs. LLM session durations.
_wait_for_any() {
    local pids_var="$1"
    local sleep_interval="${WORKER_POOL_POLL_INTERVAL:-0.5}"
    while true; do
        local idx pid
        # shellcheck disable=SC2046
        eval "set -- \"\${${pids_var}[@]}\""
        idx=0
        for pid in "$@"; do
            if [[ -z "$pid" ]]; then
                idx=$((idx + 1))
                continue
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                # Use `|| rc=$?` so a non-zero child rc does not abort the
                # function under `set -e`. Without this, callers that run with
                # `set -e` (bats tests, ralph_loop.sh's main) would see this
                # function exit with the child's rc instead of returning 0.
                local rc=0
                wait "$pid" 2>/dev/null || rc=$?
                _WAIT_FOR_ANY_SLOT="$idx"
                _WAIT_FOR_ANY_RC="$rc"
                echo "$idx $rc"
                return 0
            fi
            idx=$((idx + 1))
        done
        sleep "$sleep_interval"
    done
}

# =============================================================================
# Internal: atomic call-count increment
# =============================================================================
#
# Increments $CALL_COUNT_FILE by 1 under an mkdir-based lock. Echoes the new
# value on stdout. Safe under concurrent callers.
_atomic_inc_call_count() {
    local lock_dir
    lock_dir="${RALPH_DIR:-.ralph}/.call_count_lock"
    local count_file="${CALL_COUNT_FILE:-${RALPH_DIR:-.ralph}/.call_count}"
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.05
        waited=$((waited + 1))
        if [[ $waited -ge 200 ]]; then
            # 10s of contention → break the lock as a last-resort failsafe.
            rmdir "$lock_dir" 2>/dev/null || true
        fi
    done
    local n
    n=$(cat "$count_file" 2>/dev/null || echo "0")
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n + 1))
    echo "$n" > "$count_file"
    rmdir "$lock_dir" 2>/dev/null || true
    echo "$n"
}

# =============================================================================
# Continuous state file lifecycle (.ralph/.continuous_state)
# =============================================================================
#
# The state file lets a startup sweeper (lib/continuous_recovery.sh) detect
# crashed orchestrators and revert their stale [~] markers. We use a simple
# tab-separated key/value format — one record per line — so the file can be
# manipulated with grep/sed/awk without depending on jq:
#
#   orchestrator_pid<TAB>12345
#   started_at<TAB>1715080000
#   inflight<TAB>42<TAB>T-101<TAB>12346
#   inflight<TAB>57<TAB>T-105<TAB>12347
#
# Each `inflight` row carries (line_num, task_id, worker_pid). Tabs are used
# rather than commas/colons so task IDs may contain those characters safely.

_continuous_state_file() {
    echo "${RALPH_DIR:-.ralph}/.continuous_state"
}

init_continuous_state() {
    local pid="${1:-$$}"
    local state_file
    state_file=$(_continuous_state_file)
    mkdir -p "$(dirname "$state_file")"

    # Concurrent-invocation safety: if a state file already exists AND its
    # recorded orchestrator PID is alive AND it isn't us, refuse to start.
    # Two orchestrators in the same project would clobber each other's
    # in-flight markers and break crash recovery.
    # Honor RALPH_CONTINUOUS_FORCE=true to override (for tests / recovery).
    if [[ -f "$state_file" && "${RALPH_CONTINUOUS_FORCE:-false}" != "true" ]]; then
        local existing_pid
        existing_pid=$(awk -F'\t' '$1 == "orchestrator_pid" { print $2; exit }' "$state_file" 2>/dev/null)
        if [[ -n "$existing_pid" && "$existing_pid" =~ ^[0-9]+$ \
            && "$existing_pid" != "$pid" ]] \
            && kill -0 "$existing_pid" 2>/dev/null; then
            echo "ERROR: another continuous-mode orchestrator is already running (pid=${existing_pid}) in this project." >&2
            echo "       If this is incorrect (e.g., the previous run was hard-killed), remove ${state_file} or set RALPH_CONTINUOUS_FORCE=true." >&2
            return 2
        fi
    fi

    local now
    now=$(date +%s)
    {
        printf 'orchestrator_pid\t%s\n' "$pid"
        printf 'started_at\t%s\n'       "$now"
        # Sentinel: presence of "in_flight" key (initially empty).
        printf 'in_flight\t\n'
    } > "$state_file"
}

# Append an in-flight task entry. Args: line_num, task_id, worker_pid
record_inflight() {
    local line_num="$1"
    local task_id="$2"
    local worker_pid="$3"
    local state_file
    state_file=$(_continuous_state_file)

    [[ -f "$state_file" ]] || return 1
    printf 'inflight\t%s\t%s\t%s\n' "$line_num" "$task_id" "$worker_pid" >> "$state_file"
}

# Remove the in-flight entry for a finished worker. Arg: worker_pid
clear_inflight() {
    local worker_pid="$1"
    local state_file
    state_file=$(_continuous_state_file)
    [[ -f "$state_file" ]] || return 1

    local tmp="${state_file}.tmp.$$"
    # Drop only the inflight line whose 4th field matches worker_pid.
    awk -v wp="$worker_pid" -F'\t' '
        $1 == "inflight" && $4 == wp { next }
        { print }
    ' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

cleanup_continuous_state() {
    local state_file
    state_file=$(_continuous_state_file)
    rm -f "$state_file"
}

# =============================================================================
# Skip-list helpers
# =============================================================================
#
# The skip-list is a newline-separated list of task identifiers. The picker
# function receives it on $1 and is expected to skip any task whose ID is in
# the list. The picker decides what an "ID" is (line number, repo|line, etc.).

_skip_list_contains() {
    local skip_list="$1"
    local id="$2"
    [[ -z "$id" ]] && return 1
    [[ -z "$skip_list" ]] && return 1
    echo "$skip_list" | grep -qxF "$id"
}

# =============================================================================
# Orchestrator: run_continuous_worker_pool
# =============================================================================
#
# Args (positional, all required):
#   $1 - max_concurrent_N      : integer ≥ 1
#   $2 - max_total_attempts_M  : integer ≥ 1
#   $3 - max_attempts_per_task : integer ≥ 1 (skip threshold)
#   $4 - respawn_delay_seconds : integer ≥ 0 (or float)
#   $5 - picker_fn             : name of picker function (receives skip_list)
#   $6 - executor_fn           : name of executor function (receives task descriptor)
#   $7 - on_complete_fn        : name of post-completion hook (receives descriptor + rc)
#
# Returns:
#   0 on overall success (succeeded == completed).
#   1 if any attempt failed.
run_continuous_worker_pool() {
    local N="$1"
    local M="$2"
    local K="$3"
    local respawn_delay="$4"
    local picker_fn="$5"
    local executor_fn="$6"
    local on_complete_fn="$7"

    if [[ -z "$N" || -z "$M" || -z "$K" || -z "$respawn_delay" \
        || -z "$picker_fn" || -z "$executor_fn" || -z "$on_complete_fn" ]]; then
        echo "ERROR: run_continuous_worker_pool requires 7 positional args" >&2
        return 2
    fi

    # State.
    local -a pids=()
    local -a tasks=()
    local i
    for ((i = 0; i < N; i++)); do
        pids[i]=""
        tasks[i]=""
    done

    local completed=0 succeeded=0 failed=0 skipped=0 inflight=0
    local skip_list=""
    # Parallel arrays for attempts_by_task.
    local -a _att_id=()
    local -a _att_count=()

    local stop_reason=""
    local start_epoch
    start_epoch=$(date +%s)

    # State file & SIGINT handling.
    # init_continuous_state returns 2 if another live orchestrator is
    # already running in this project; refuse to start in that case so we
    # don't clobber its in-flight markers. Other init failures (e.g., disk
    # full) are tolerated so we can still try to make progress.
    local _init_rc=0
    init_continuous_state $$ || _init_rc=$?
    if [[ "$_init_rc" == "2" ]]; then
        return 2
    fi

    # status.json hook (proposal §8). Engines define _continuous_update_status
    # if they want continuous-mode metadata (mode, target_M, concurrency_N,
    # attempts_completed) surfaced to ralph-monitor. We call it best-effort
    # — undefined hook just no-ops, so worker_pool.sh stays engine-agnostic.
    _maybe_update_status() {
        if declare -F _continuous_update_status > /dev/null 2>&1; then
            _continuous_update_status "$@" 2>/dev/null || true
        fi
    }
    _maybe_update_status "continuous:starting" "running" 0 "$M" "$N"

    local _prev_int_trap _prev_term_trap
    _prev_int_trap=$(trap -p INT 2>/dev/null || true)
    _prev_term_trap=$(trap -p TERM 2>/dev/null || true)
    local _interrupted=false
    _continuous_handle_signal() {
        _interrupted=true
        echo "[continuous] received signal — draining only, no new spawns" >&2
    }
    trap _continuous_handle_signal INT TERM

    # Increments the attempt count for `id` and writes the new count into
    # the global var $_ATTEMPTS_LAST. Must NOT be called via $(...) — that
    # runs in a subshell where the array mutations would be discarded,
    # leaving the counter pinned at 1 forever and the K=max-task-attempts
    # skip-list permanently silent for K >= 2 (regression covered by
    # tests/unit/test_worker_pool.bats).
    _attempts_increment() {
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

    _spawn_worker() {
        local slot="$1"
        local descriptor="$2"
        # Run the executor in a forked subshell so worktree state etc. is
        # isolated per worker.
        (
            "$executor_fn" "$descriptor"
        ) &
        local pid=$!
        pids[$slot]="$pid"
        tasks[$slot]="$descriptor"
        inflight=$((inflight + 1))
        # Record into state file. We don't have line / task_id here in a
        # generic way; we record the whole descriptor in place of task_id.
        local first_token="${descriptor%% *}"
        record_inflight "0" "$first_token" "$pid" 2>/dev/null || true
    }

    # ── Initial fill ──────────────────────────────────────────────────────────
    for ((i = 0; i < N; i++)); do
        if [[ "$_interrupted" == "true" ]]; then
            break
        fi
        if [[ $((completed + inflight)) -ge $M ]]; then
            break
        fi
        local task
        task=$("$picker_fn" "$skip_list" 2>/dev/null) || task=""
        if [[ -z "$task" ]]; then
            break
        fi
        _spawn_worker "$i" "$task"
    done

    if [[ $inflight -eq 0 ]]; then
        stop_reason="queue empty"
        _continuous_emit_summary "$N" "$M" "$completed" "$succeeded" "$failed" "$skipped" "$start_epoch" "$stop_reason"
        _maybe_update_status "continuous:completed" "stopped" "$completed" "$M" "$N" "$stop_reason"
        cleanup_continuous_state
        # Restore signal traps.
        eval "${_prev_int_trap:-trap - INT}"
        eval "${_prev_term_trap:-trap - TERM}"
        return 0
    fi

    # ── Main loop ─────────────────────────────────────────────────────────────
    while [[ $inflight -gt 0 ]]; do
        # _wait_for_any sets _WAIT_FOR_ANY_SLOT / _WAIT_FOR_ANY_RC. Calling it
        # directly (NOT via $(...)) is required so `wait` runs in this shell
        # where the worker PIDs are children. A subshell capture would lose
        # the exit codes (wait returns 127 for "not a child").
        _WAIT_FOR_ANY_SLOT=""
        _WAIT_FOR_ANY_RC=""
        _wait_for_any pids > /dev/null
        local slot="$_WAIT_FOR_ANY_SLOT"
        local rc="$_WAIT_FOR_ANY_RC"

        local finished_descriptor="${tasks[$slot]}"
        local finished_pid="${pids[$slot]}"
        completed=$((completed + 1))
        inflight=$((inflight - 1))

        # Per-completion telemetry.
        echo "[continuous] completed=${completed}/${M} succeeded=${succeeded} failed=${failed} skipped=${skipped} in_flight=${inflight} task=\"${finished_descriptor}\" rc=${rc}"

        # Per-task post-completion hook.
        "$on_complete_fn" "$finished_descriptor" "$rc" 2>/dev/null || true

        # Clear in_flight from state file.
        clear_inflight "$finished_pid" 2>/dev/null || true

        # Surface progress to ralph-monitor via status.json (engine-specific
        # hook; no-op if undefined). Fires AFTER clear_inflight so the
        # in-flight count is accurate.
        _maybe_update_status "continuous:executing" "running" "$completed" "$M" "$N"

        if [[ "$rc" == "0" ]]; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            local task_key="${finished_descriptor%% *}"
            # Direct call (not $(_attempts_increment …)) so the function's
            # array mutations persist in our shell. See the helper's docstring.
            _ATTEMPTS_LAST=""
            _attempts_increment "$task_key"
            local n_attempts="$_ATTEMPTS_LAST"
            if [[ "$n_attempts" -ge "$K" ]]; then
                skip_list="${skip_list}${task_key}"$'\n'
                skipped=$((skipped + 1))
                echo "[continuous] skip-list += ${task_key} (failed ${n_attempts} ≥ K=${K})"
            fi
        fi

        pids[$slot]=""
        tasks[$slot]=""

        # Decide whether to respawn.
        if [[ "$_interrupted" == "true" ]]; then
            stop_reason="user interrupt"
            continue
        fi
        if [[ $completed -ge $M ]]; then
            stop_reason="target reached (M)"
            continue
        fi
        if [[ $((completed + inflight)) -ge $M ]]; then
            # Already at target counting in-flight — drain only.
            stop_reason="${stop_reason:-target reached (M)}"
            continue
        fi

        if [[ $(awk -v d="$respawn_delay" 'BEGIN { print (d > 0) ? 1 : 0 }') == "1" ]]; then
            sleep "$respawn_delay" 2>/dev/null || true
        fi

        local next_task
        next_task=$("$picker_fn" "$skip_list" 2>/dev/null) || next_task=""
        if [[ -z "$next_task" ]]; then
            stop_reason="${stop_reason:-queue empty}"
            continue
        fi
        _spawn_worker "$slot" "$next_task"
    done

    # Final stop reason fallback.
    if [[ -z "$stop_reason" ]]; then
        if [[ $completed -ge $M ]]; then
            stop_reason="target reached (M)"
        else
            stop_reason="queue empty"
        fi
    fi

    _continuous_emit_summary "$N" "$M" "$completed" "$succeeded" "$failed" "$skipped" "$start_epoch" "$stop_reason"
    _maybe_update_status "continuous:completed" "stopped" "$completed" "$M" "$N" "$stop_reason"
    cleanup_continuous_state

    # Restore signal traps.
    eval "${_prev_int_trap:-trap - INT}"
    eval "${_prev_term_trap:-trap - TERM}"

    if [[ $succeeded -eq $completed ]]; then
        return 0
    fi
    return 1
}

# Helper: emit final summary block to stdout AND append to summary log.
_continuous_emit_summary() {
    local N="$1" M="$2" completed="$3" succeeded="$4" failed="$5" skipped="$6" start_epoch="$7" stop_reason="$8"
    local now elapsed avg_per_task pct
    now=$(date +%s)
    elapsed=$((now - start_epoch))
    if [[ $completed -gt 0 ]]; then
        avg_per_task=$((elapsed / completed))
        pct=$((completed * 100 / M))
    else
        avg_per_task=0
        pct=0
    fi

    local log_dir="${RALPH_DIR:-.ralph}/logs"
    mkdir -p "$log_dir"
    local summary_log="${log_dir}/continuous-summary.log"

    local summary
    summary=$(cat << EOF

╔════════════════════════════════════════════════════════════╗
║              Continuous Execution Summary                  ║
╠════════════════════════════════════════════════════════════╣
║  Mode:            continuous                               ║
║  Concurrency:     N=${N}
║  Target:          M=${M} attempts
║  Completed:       ${completed} attempts (${pct}%)
║  Succeeded:       ${succeeded}
║  Failed:          ${failed}
║  Skipped:         ${skipped} (hit max-attempts limit)
║  Wall time:       ${elapsed}s
║  Avg per task:    ${avg_per_task}s
║  Stop reason:     ${stop_reason}
╚════════════════════════════════════════════════════════════╝

EOF
    )
    echo "$summary"
    {
        echo ""
        echo "═══ $(date -u +"%Y-%m-%dT%H:%M:%SZ") ═══"
        echo "$summary"
    } >> "$summary_log"
}

# =============================================================================
# Exports
# =============================================================================

export -f _wait_for_any
export -f _atomic_inc_call_count
export -f _continuous_state_file
export -f init_continuous_state
export -f record_inflight
export -f clear_inflight
export -f cleanup_continuous_state
export -f _skip_list_contains
export -f run_continuous_worker_pool
export -f _continuous_emit_summary
