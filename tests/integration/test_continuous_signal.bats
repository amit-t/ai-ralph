#!/usr/bin/env bats
# Integration tests for continuous-mode signal handling and end-to-end
# orchestration. Uses a mocked executor — no real engine CLI required.
# See docs/proposals/continuous-parallel-execution.md §7

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
RECOVERY_LIB="${BATS_TEST_DIRNAME}/../../lib/continuous_recovery.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # picker.sh below uses $TEST_DIR; export so child processes see it.
    export TEST_DIR
    export RALPH_DIR="${TEST_DIR}/.ralph"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "${RALPH_DIR}/logs"
    echo "0" > "$CALL_COUNT_FILE"

    if [[ -f "$WORKER_POOL_LIB" ]]; then
        source "$WORKER_POOL_LIB"
    fi
    if [[ -f "$RECOVERY_LIB" ]]; then
        source "$RECOVERY_LIB"
    fi
    log_status() { echo "[$1] ${@:2}"; }
    log_info() { echo "[INFO] $*"; }
    export -f log_status log_info
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# SIGINT during continuous run → drain only, no replacements
# =============================================================================

@test "SIGTERM during continuous run drains in-flight workers without spawning replacements" {
    # Note: we use SIGTERM rather than SIGINT here because bash backgrounded
    # async processes (`(...) &`) inherit SIGINT as ignored — sending SIGINT
    # to such a process is a no-op. The orchestrator's trap handles both
    # SIGINT and SIGTERM identically (proposal §7).

    # Build a queue with many tasks; N=2, M=20 — drain must abort early.
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 sleep=0.6 rc=0
T2 sleep=0.6 rc=0
T3 sleep=0.6 rc=0
T4 sleep=0.6 rc=0
T5 sleep=0.6 rc=0
T6 sleep=0.6 rc=0
T7 sleep=0.6 rc=0
T8 sleep=0.6 rc=0
EOF

    cat > "${TEST_DIR}/picker.sh" << 'PICKER'
#!/usr/bin/env bash
queue="${TEST_DIR}/.test_queue"
[[ -f "$queue" ]] || exit 1
line=$(head -1 "$queue")
[[ -z "$line" ]] && exit 1
tail -n +2 "$queue" > "${queue}.tmp" && mv "${queue}.tmp" "$queue"
echo "$line"
PICKER
    chmod +x "${TEST_DIR}/picker.sh"

    _picker_fn() {
        "${TEST_DIR}/picker.sh" "$@"
    }
    _executor_fn() {
        local descriptor="$1"
        local s
        s=$(echo "$descriptor" | sed -n 's/.* sleep=\([0-9.]*\).*/\1/p')
        sleep "${s:-0.5}"
        return 0
    }
    _on_complete() { :; }
    export -f _picker_fn _executor_fn _on_complete

    (
        run_continuous_worker_pool 2 20 1 0 _picker_fn _executor_fn _on_complete > "${TEST_DIR}/orch.out" 2>&1
        echo "EXIT=$?" >> "${TEST_DIR}/orch.out"
    ) &
    local orch_pid=$!

    # Give it a moment to start two workers.
    sleep 0.3

    # Send SIGTERM. The orchestrator's trap (set inside run_continuous_worker_pool)
    # catches both SIGINT and SIGTERM; we use SIGTERM for portability.
    kill -TERM "$orch_pid" 2>/dev/null || true

    wait "$orch_pid" 2>/dev/null || true

    # Stop reason must mention user interrupt.
    grep -q "user interrupt" "${TEST_DIR}/orch.out"
    # State file cleaned up.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
    # Summary block present.
    grep -q "Continuous Execution Summary" "${TEST_DIR}/orch.out"
    # Crucially: completed count is FAR less than M=20, since drain aborted early.
    grep -E "Completed: *[0-9]+ attempts" "${TEST_DIR}/orch.out"
    local completed
    completed=$(grep -oE "Completed: +[0-9]+" "${TEST_DIR}/orch.out" | head -1 | grep -oE '[0-9]+')
    [[ "$completed" -lt "20" ]]
}

# =============================================================================
# State file lifecycle observed during a real run
# =============================================================================

@test "state file is created during run and removed on clean exit" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 sleep=0.3 rc=0
T2 sleep=0.3 rc=0
EOF

    cat > "${TEST_DIR}/picker.sh" << 'PICKER'
#!/usr/bin/env bash
queue="${TEST_DIR}/.test_queue"
[[ -f "$queue" ]] || exit 1
line=$(head -1 "$queue")
[[ -z "$line" ]] && exit 1
tail -n +2 "$queue" > "${queue}.tmp" && mv "${queue}.tmp" "$queue"
echo "$line"
PICKER
    chmod +x "${TEST_DIR}/picker.sh"

    _picker_fn() { "${TEST_DIR}/picker.sh"; }
    _executor_fn() {
        local descriptor="$1"
        local s
        s=$(echo "$descriptor" | sed -n 's/.* sleep=\([0-9.]*\).*/\1/p')
        sleep "${s:-0.2}"
        return 0
    }
    _on_complete() { :; }
    export -f _picker_fn _executor_fn _on_complete

    (
        run_continuous_worker_pool 2 2 1 0 _picker_fn _executor_fn _on_complete > /dev/null 2>&1
    ) &
    local orch_pid=$!

    # Mid-run snapshot — state file should exist.
    sleep 0.15
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    grep -q "orchestrator_pid" "${RALPH_DIR}/.continuous_state"

    wait "$orch_pid" 2>/dev/null || true

    # After clean exit — state file is gone.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

# =============================================================================
# Skip-list: failed task at K=1 stops being re-picked even if queue resubmits it
# =============================================================================

@test "skip-list prevents respawning a task that fails at K=1" {
    # Queue contains a flaky task ID (T1) that will keep failing if re-picked,
    # plus a healthy T2. With K=1 the orchestrator must skip subsequent T1s
    # after the first failure, then succeed on T2.
    #
    # The picker pops the FIRST line of the queue each call, but skips lines
    # whose ID is in skip_list (popping past them so we don't loop forever).
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1
T1
T1
T2
EOF

    _picker_fn() {
        local skip_list="${1:-}"
        local queue="${TEST_DIR}/.test_queue"
        [[ -f "$queue" ]] || return 1
        # Iterate: pop the first line; if its ID is skipped, pop and try again.
        while [[ -s "$queue" ]]; do
            local first
            first=$(head -1 "$queue")
            tail -n +2 "$queue" > "${queue}.tmp" && mv "${queue}.tmp" "$queue"
            [[ -z "$first" ]] && continue
            local id="${first%% *}"
            if [[ -n "$skip_list" ]] && echo "$skip_list" | grep -qxF "$id"; then
                continue
            fi
            echo "$first"
            return 0
        done
        return 1
    }
    _executor_fn() {
        local descriptor="$1"
        if [[ "$descriptor" == "T1"* ]]; then
            return 1
        fi
        return 0
    }
    _on_complete() { :; }
    export -f _picker_fn _executor_fn _on_complete

    : > "${TEST_DIR}/orch.out"
    run_continuous_worker_pool 1 10 1 0 _picker_fn _executor_fn _on_complete > "${TEST_DIR}/orch.out" 2>&1 || true
    # Should record T1 as skipped (the worker pool emits "skip-list += T1").
    grep -q "skip-list" "${TEST_DIR}/orch.out"
    grep -q "T1" "${TEST_DIR}/orch.out"
    # T2 should have been executed (succeeded).
    grep -q "T2" "${TEST_DIR}/orch.out"
}

# =============================================================================
# Hard-kill E2E: SIGKILL the orchestrator, then run sweeper, [~] reverts.
# This is the full crash-recovery cycle the proposal §16 promises.
# =============================================================================

@test "SIGKILL'd orchestrator's state file is swept on next startup, [~] reverts" {
    # Build a real fix_plan.md.
    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [ ] Task A
- [ ] Task B
- [ ] Task C
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # Spawn a real bash process to act as the "orchestrator". Using `bash
    # script.sh &` (rather than a `(...) &` subshell) ensures `$$` inside
    # the script equals `$!` from the parent, which is critical: the state
    # file records `$$` and we SIGKILL `$!`. With `(...) &` on macOS bash
    # 3.2 these can drift apart because the inner block re-forks.
    cat > "${TEST_DIR}/orch.sh" << 'ORCH'
#!/usr/bin/env bash
# Args: $1 = path to worker_pool.sh
source "$1"

# Pick the first [ ] task, mark it [~], capture line number.
plan="${WORKSPACE_FIX_PLAN}"
ln=$(grep -n '^- \[ \]' "$plan" | head -1 | cut -d: -f1)
desc=$(sed -n "${ln}p" "$plan" | sed 's/^- \[ \] //')
awk -v ln="$ln" 'NR==ln { sub(/- \[ \]/, "- [~]") } 1' "$plan" > "${plan}.tmp" \
    && mv "${plan}.tmp" "$plan"

# Write state file with our own PID and a worker entry referencing the
# fix_plan line number.
init_continuous_state "$$"
( sleep 30 ) &
worker_pid=$!
printf 'inflight\t%s\t%s\t%s\n' "$ln" "$desc" "$worker_pid" \
    >> "${RALPH_DIR}/.continuous_state"

# Sleep forever — parent will SIGKILL us mid-flight.
sleep 60
ORCH
    chmod +x "${TEST_DIR}/orch.sh"

    bash "${TEST_DIR}/orch.sh" "$WORKER_POOL_LIB" &
    local orch_pid=$!

    # Wait for the orchestrator to write state + mutate fix_plan.
    local waited=0
    while [[ ! -f "${RALPH_DIR}/.continuous_state" ]] && [[ $waited -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    sleep 0.2  # let it finish writing the inflight row too

    # Sanity: state file exists, fix_plan has a [~], inflight row recorded.
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
    grep -q '^inflight' "${RALPH_DIR}/.continuous_state"

    # Verify the recorded PID matches the orchestrator we're about to kill.
    local state_pid
    state_pid=$(awk -F'\t' '$1=="orchestrator_pid" {print $2}' "${RALPH_DIR}/.continuous_state")
    [[ "$state_pid" == "$orch_pid" ]]

    # Hard-kill (SIGKILL bypasses any trap).
    kill -KILL "$orch_pid" 2>/dev/null || true
    wait "$orch_pid" 2>/dev/null || true

    # Wait for the OS to reap the process so kill -0 returns false.
    waited=0
    while kill -0 "$orch_pid" 2>/dev/null && [[ $waited -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    # State file still present (no clean shutdown), fix_plan still has [~].
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"

    # Simulate next ralph startup → sweeper runs.
    run sweep_stale_continuous_state
    assert_success

    # [~] reverted to [ ], state file cleaned up.
    ! grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
    grep -q '^- \[ \] Task A' "${TEST_DIR}/fix_plan.md"
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

# =============================================================================
# Heartbeat logged at completion
# =============================================================================

@test "every completion emits a [continuous] log line with progress fields" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1
T2
T3
EOF
    _picker_fn() {
        local queue="${TEST_DIR}/.test_queue"
        local line
        line=$(head -1 "$queue")
        [[ -z "$line" ]] && return 1
        tail -n +2 "$queue" > "${queue}.tmp" && mv "${queue}.tmp" "$queue"
        echo "$line"
    }
    _executor_fn() { return 0; }
    _on_complete() { :; }
    export -f _picker_fn _executor_fn _on_complete

    run run_continuous_worker_pool 1 3 1 0 _picker_fn _executor_fn _on_complete
    assert_success
    [[ "$output" == *"completed=1/3"* ]]
    [[ "$output" == *"completed=2/3"* ]]
    [[ "$output" == *"completed=3/3"* ]]
}
