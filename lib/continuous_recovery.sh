#!/usr/bin/env bash
# lib/continuous_recovery.sh — Startup sweeper for stale continuous-mode state
#
# When a continuous-mode orchestrator (lib/worker_pool.sh) dies hard
# (SIGKILL, panic, machine reboot), in-flight tasks retain their `[~]` marker
# in fix_plan.md. The sweeper runs at the top of every ralph entry point: it
# reads `.ralph/.continuous_state`, checks whether the orchestrator PID is
# still alive via `kill -0`, and if not, reverts each in-flight `[~]` marker
# back to `[ ]` so the next run can pick them up cleanly.
#
# See docs/proposals/continuous-parallel-execution.md §16 for the full
# rationale (PID-collision considerations, jq optionality, etc.).

# sweep_stale_continuous_state — entry point. Always returns 0 (sweep failures
# must never block the caller's startup). Silent when there is no state file.
sweep_stale_continuous_state() {
    local state_file="${RALPH_DIR:-.ralph}/.continuous_state"
    [[ -f "$state_file" ]] || return 0

    # Parse orchestrator PID from the flat TSV state file. (The earlier
    # JSON-based proposal pseudocode used jq; we use a portable awk because
    # jq is a soft dependency in ai-ralph and the format is now flat TSV.)
    local orch_pid
    orch_pid=$(awk -F'\t' '$1 == "orchestrator_pid" { print $2; exit }' "$state_file" 2>/dev/null)

    if [[ -z "$orch_pid" || ! "$orch_pid" =~ ^[0-9]+$ ]]; then
        # Malformed state file — leave it alone, log a warning, return 0.
        if command -v log_status &>/dev/null; then
            log_status "WARN" "Continuous state file present but orchestrator PID could not be parsed; skipping sweep."
        fi
        return 0
    fi

    if kill -0 "$orch_pid" 2>/dev/null; then
        # Orchestrator still alive — leave state alone.
        return 0
    fi

    # Orchestrator is dead. Determine which fix_plan to mutate.
    local fix_plan="${WORKSPACE_FIX_PLAN:-${RALPH_DIR:-.ralph}/fix_plan.md}"

    if [[ ! -f "$fix_plan" ]]; then
        # No fix_plan to repair, but still clean up the state file so the
        # next startup is silent.
        rm -f "$state_file"
        return 0
    fi

    # Iterate inflight rows, revert each [~] to [ ].
    local reverted=0
    while IFS=$'\t' read -r tag line_num task_id worker_pid; do
        [[ "$tag" == "inflight" ]] || continue
        [[ -z "$line_num" || ! "$line_num" =~ ^[0-9]+$ ]] && continue
        # Only act on lines that are actually [~]; if a human already cleaned
        # up the marker we leave their edit alone.
        local current_line
        current_line=$(sed -n "${line_num}p" "$fix_plan" 2>/dev/null)
        if [[ "$current_line" == *"[~]"* ]]; then
            local tmp_file="${fix_plan}.tmp.$$"
            awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "$fix_plan" > "$tmp_file" \
                && mv "$tmp_file" "$fix_plan"
            reverted=$((reverted + 1))
            if command -v log_info &>/dev/null; then
                log_info "Reverted stale [~] at line ${line_num} (task ${task_id}) from dead orchestrator ${orch_pid}"
            elif command -v log_status &>/dev/null; then
                log_status "INFO" "Reverted stale [~] at line ${line_num} (task ${task_id}) from dead orchestrator ${orch_pid}"
            else
                echo "[continuous-recovery] Reverted stale [~] at line ${line_num} (task ${task_id}) from dead orchestrator ${orch_pid}"
            fi
        fi
    done < "$state_file"

    rm -f "$state_file"
    return 0
}

export -f sweep_stale_continuous_state
