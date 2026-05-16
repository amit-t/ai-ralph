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

    # P2 #17: collect all reverted (line_num, task_id) pairs in one pass over
    # the state file, then mutate fix_plan.md exactly once via a single awk
    # call. The previous implementation forked sed + awk + mv per in-flight
    # row, which was O(N·R) file IO for R inflight rows of an N-line plan;
    # the new path is O(N + R). Behavior is otherwise unchanged: only lines
    # currently containing `[~]` are reverted, hand-edited rows are left
    # alone, and the same per-row log line is emitted.
    #
    # P2 #18: relax the substitution regex from `- \[~\]` to `\[~\]` so
    # indented or non-dash-prefixed `[~]` markers are recovered too. The
    # picker only ever writes `- [~]`, so this is purely defensive against
    # hand-edited fix_plan formats (e.g. `* [~]`, `\t- [~]`, `  - [~]`).
    local reverted=0
    local revert_lines=""   # space-separated line numbers, set form via awk
    local -a revert_log_msgs=()
    # shellcheck disable=SC2034  # worker_pid is read for column-shape only
    while IFS=$'\t' read -r tag line_num task_id worker_pid; do
        [[ "$tag" == "inflight" ]] || continue
        [[ -z "$line_num" || ! "$line_num" =~ ^[0-9]+$ ]] && continue
        # Pre-check the line is still [~]; skip rows where a human already
        # cleaned up the marker (we leave their edit alone).
        local current_line
        current_line=$(sed -n "${line_num}p" "$fix_plan" 2>/dev/null)
        if [[ "$current_line" == *"[~]"* ]]; then
            revert_lines="${revert_lines}${line_num} "
            revert_log_msgs+=("Reverted stale [~] at line ${line_num} (task ${task_id}) from dead orchestrator ${orch_pid}")
            reverted=$((reverted + 1))
        fi
    done < "$state_file"

    if [[ "$reverted" -gt 0 ]]; then
        local tmp_file="${fix_plan}.tmp.$$"
        # Single awk pass: build a set of target line numbers, then substitute
        # `[~]` → `[ ]` on those lines only. `gsub` over `\[~\]` survives
        # leading whitespace, alternate list-item prefixes (`* [~]`, indented
        # `  - [~]`), or any other harmless variation around the marker.
        awk -v lines="$revert_lines" 'BEGIN {
            n = split(lines, parts, " ")
            for (i = 1; i <= n; i++) if (parts[i] != "") target[parts[i]] = 1
        }
        (NR in target) { gsub(/\[~\]/, "[ ]") }
        1' "$fix_plan" > "$tmp_file" \
            && mv "$tmp_file" "$fix_plan"

        local msg
        for msg in "${revert_log_msgs[@]}"; do
            if command -v log_info &>/dev/null; then
                log_info "$msg"
            elif command -v log_status &>/dev/null; then
                log_status "INFO" "$msg"
            else
                echo "[continuous-recovery] ${msg}"
            fi
        done
    fi

    rm -f "$state_file"
    return 0
}

export -f sweep_stale_continuous_state
