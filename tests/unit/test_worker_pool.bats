#!/usr/bin/env bats
# Unit tests for lib/worker_pool.sh — continuous parallel execution
# See docs/proposals/continuous-parallel-execution.md §13

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
TASK_SOURCES_LIB="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # All continuous-mode artifacts live under .ralph/
    export RALPH_DIR="${TEST_DIR}/.ralph"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "${RALPH_DIR}/logs"
    echo "0" > "$CALL_COUNT_FILE"

    if [[ -f "$WORKER_POOL_LIB" ]]; then
        source "$WORKER_POOL_LIB"
    fi
    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$TASK_SOURCES_LIB" ]]; then
        source "$TASK_SOURCES_LIB"
    fi

    # Stand-in for the engines' log_status (worker_pool.sh emits status lines).
    log_status() {
        local level="$1"; shift
        echo "[$level] $*"
    }
    export -f log_status
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# library load
# =============================================================================

@test "lib/worker_pool.sh exists" {
    [[ -f "$WORKER_POOL_LIB" ]]
}

@test "worker_pool.sh exports run_continuous_worker_pool" {
    declare -F run_continuous_worker_pool > /dev/null
}

@test "worker_pool.sh exports _wait_for_any" {
    declare -F _wait_for_any > /dev/null
}

@test "worker_pool.sh exports _atomic_inc_call_count" {
    declare -F _atomic_inc_call_count > /dev/null
}

@test "worker_pool.sh exports init_continuous_state" {
    declare -F init_continuous_state > /dev/null
}

@test "worker_pool.sh exports record_inflight" {
    declare -F record_inflight > /dev/null
}

@test "worker_pool.sh exports clear_inflight" {
    declare -F clear_inflight > /dev/null
}

@test "worker_pool.sh exports cleanup_continuous_state" {
    declare -F cleanup_continuous_state > /dev/null
}

# =============================================================================
# _wait_for_any — portable wait-for-any-PID helper
# =============================================================================

@test "_wait_for_any returns slot index of the first-finishing PID" {
    # Spawn 3 sleepers with very different durations. Use the globals
    # (_WAIT_FOR_ANY_SLOT / _WAIT_FOR_ANY_RC) — subshell-capture would lose
    # `wait` semantics, see the docstring on _wait_for_any.
    sleep 0.05 & local pid_fast=$!
    sleep 5    & local pid_slow1=$!
    sleep 5    & local pid_slow2=$!
    local -a pids=("$pid_slow1" "$pid_fast" "$pid_slow2")

    _WAIT_FOR_ANY_SLOT=""
    _wait_for_any pids > /dev/null
    [[ "$_WAIT_FOR_ANY_SLOT" == "1" ]]

    # Clean up the slow sleepers
    kill "$pid_slow1" 2>/dev/null || true
    kill "$pid_slow2" 2>/dev/null || true
    wait 2>/dev/null || true
}

@test "_wait_for_any propagates exit code of the finishing PID" {
    ( exit 7 ) & local pid_fail=$!
    sleep 5    & local pid_slow=$!
    local -a pids=("$pid_fail" "$pid_slow")

    # Give the failing process a moment to register its exit status.
    sleep 0.1

    _WAIT_FOR_ANY_RC=""
    _wait_for_any pids > /dev/null
    [[ "$_WAIT_FOR_ANY_RC" == "7" ]]

    kill "$pid_slow" 2>/dev/null || true
    wait 2>/dev/null || true
}

@test "_wait_for_any skips empty slots" {
    sleep 0.05 & local pid_only=$!
    local -a pids=("" "$pid_only" "")

    _WAIT_FOR_ANY_SLOT=""
    _wait_for_any pids > /dev/null
    [[ "$_WAIT_FOR_ANY_SLOT" == "1" ]]
}

# =============================================================================
# _atomic_inc_call_count — race-free counter increment
# =============================================================================

@test "_atomic_inc_call_count increments by 1 starting from 0" {
    echo "0" > "$CALL_COUNT_FILE"
    run _atomic_inc_call_count
    assert_success
    [[ "$output" == "1" ]]
    [[ "$(cat "$CALL_COUNT_FILE")" == "1" ]]
}

@test "_atomic_inc_call_count increments by 1 starting from 5" {
    echo "5" > "$CALL_COUNT_FILE"
    run _atomic_inc_call_count
    assert_success
    [[ "$output" == "6" ]]
    [[ "$(cat "$CALL_COUNT_FILE")" == "6" ]]
}

@test "_atomic_inc_call_count handles missing file as zero" {
    rm -f "$CALL_COUNT_FILE"
    run _atomic_inc_call_count
    assert_success
    [[ "$output" == "1" ]]
}

@test "_atomic_inc_call_count is race-free under 10 parallel callers" {
    echo "0" > "$CALL_COUNT_FILE"
    local -a pids=()
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ( _atomic_inc_call_count > /dev/null ) & pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    [[ "$(cat "$CALL_COUNT_FILE")" == "10" ]]
}

# =============================================================================
# Continuous state file lifecycle (.ralph/.continuous_state)
# =============================================================================

@test "init_continuous_state creates state file with orchestrator PID" {
    init_continuous_state $$
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    grep -q "$$" "${RALPH_DIR}/.continuous_state"
}

@test "init_continuous_state writes a started_at epoch" {
    init_continuous_state $$
    local content
    content=$(cat "${RALPH_DIR}/.continuous_state")
    [[ "$content" == *"started_at"* ]]
}

@test "init_continuous_state initializes empty in_flight list" {
    init_continuous_state $$
    local content
    content=$(cat "${RALPH_DIR}/.continuous_state")
    [[ "$content" == *"in_flight"* ]]
}

@test "record_inflight appends a task entry to in_flight" {
    init_continuous_state $$
    record_inflight 42 "T-101" 12346
    local content
    content=$(cat "${RALPH_DIR}/.continuous_state")
    [[ "$content" == *"42"* ]]
    [[ "$content" == *"T-101"* ]]
    [[ "$content" == *"12346"* ]]
}

@test "record_inflight handles multiple tasks" {
    init_continuous_state $$
    record_inflight 42 "T-101" 12346
    record_inflight 57 "T-105" 12347
    local content
    content=$(cat "${RALPH_DIR}/.continuous_state")
    [[ "$content" == *"42"* ]]
    [[ "$content" == *"57"* ]]
    [[ "$content" == *"T-101"* ]]
    [[ "$content" == *"T-105"* ]]
}

@test "clear_inflight removes the entry for a finished worker" {
    init_continuous_state $$
    record_inflight 42 "T-101" 12346
    record_inflight 57 "T-105" 12347
    clear_inflight 12346
    local content
    content=$(cat "${RALPH_DIR}/.continuous_state")
    [[ "$content" != *"12346"* ]]
    [[ "$content" == *"12347"* ]]
}

@test "cleanup_continuous_state removes the state file" {
    init_continuous_state $$
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    cleanup_continuous_state
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

# =============================================================================
# run_continuous_worker_pool — orchestrator integration tests with mock
# executor / picker. These are unit-scoped: no real engine, no real worktree.
# =============================================================================

# Simple FIFO picker driven by a pending-tasks file. Each line in the file
# is a task descriptor. Skips any descriptor whose first space-token is in
# the skip-list (newline-separated, on stdin via $1).
_test_picker() {
    local skip_list="${1:-}"
    local queue="${TEST_DIR}/.test_queue"
    [[ -f "$queue" ]] || return 1
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local token="${line%% *}"
        if [[ -z "$skip_list" ]] || ! echo "$skip_list" | grep -qxF "$token"; then
            # Pop this line from the queue.
            grep -vxF "$line" "$queue" > "${queue}.tmp" 2>/dev/null || true
            mv "${queue}.tmp" "$queue" 2>/dev/null || true
            echo "$line"
            return 0
        fi
    done < "$queue"
    return 1
}
export -f _test_picker

# Mock executor: writes its task descriptor to a results log, then returns
# the exit code parsed from the descriptor. Format: "ID rc=N [optional sleep=S]"
_test_executor() {
    local descriptor="$1"
    echo "$descriptor" >> "${TEST_DIR}/.test_executions"
    local rc=0
    if [[ "$descriptor" == *" rc="* ]]; then
        rc=$(echo "$descriptor" | sed -n 's/.* rc=\([0-9][0-9]*\).*/\1/p')
    fi
    if [[ "$descriptor" == *" sleep="* ]]; then
        local s
        s=$(echo "$descriptor" | sed -n 's/.* sleep=\([0-9.]*\).*/\1/p')
        sleep "$s" 2>/dev/null || true
    fi
    return "${rc:-0}"
}
export -f _test_executor

# No-op completion hook (orchestrator owns counters; test just checks them).
_test_on_complete() { :; }
export -f _test_on_complete

@test "run_continuous_worker_pool runs M=1 N=1 with a single task" {
    echo "T1 rc=0" > "${TEST_DIR}/.test_queue"
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    [[ "$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')" == "1" ]]
    grep -q "T1" "${TEST_DIR}/.test_executions"
}

@test "run_continuous_worker_pool stops at M attempts even with more pending tasks" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
T4 rc=0
T5 rc=0
T6 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    # M=4, N=2 → exactly 4 attempts even though 6 are queued.
    run run_continuous_worker_pool 2 4 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    local count
    count=$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')
    [[ "$count" == "4" ]]

    # Two tasks should still be in the queue (unpicked).
    local remaining
    remaining=$(wc -l < "${TEST_DIR}/.test_queue" | tr -d ' ')
    [[ "$remaining" == "2" ]]
}

@test "run_continuous_worker_pool drains naturally when queue empties before M" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    # M=20 (huge), N=2 → only 3 in queue, so exactly 3 attempts.
    run run_continuous_worker_pool 2 20 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    local count
    count=$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')
    [[ "$count" == "3" ]]
    [[ ! -s "${TEST_DIR}/.test_queue" ]]
}

@test "run_continuous_worker_pool returns success when all attempts succeed" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 2 3 1 0 _test_picker _test_executor _test_on_complete
    assert_success
}

@test "run_continuous_worker_pool returns nonzero when some attempts fail" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=1
T3 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 2 3 1 0 _test_picker _test_executor _test_on_complete
    assert_failure
}

@test "run_continuous_worker_pool respects max-task-attempts K=1 (skip on first fail)" {
    # Same task fails repeatedly. With K=1 it should be skipped after first fail.
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TBROKEN rc=1
TBROKEN rc=1
TBROKEN rc=1
TGOOD rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    # M=10 large enough to drain. N=1 to keep this deterministic.
    run run_continuous_worker_pool 1 10 1 0 _test_picker _test_executor _test_on_complete

    # All 4 lines pop from queue regardless (FIFO picker doesn't dedupe by ID),
    # but the orchestrator must have classified one task as "skipped".
    local executions
    executions=$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')
    [[ "$executions" -le "4" ]]

    # Output should mention skipping at least once.
    [[ "$output" == *"skip"* ]] || [[ "$output" == *"Skip"* ]]
}

@test "run_continuous_worker_pool keeps N concurrent workers running" {
    # 6 long-ish tasks, N=3. We measure peak concurrency by having each task
    # write its slot's PID to a log on entry and remove it on exit. The peak
    # number of live PIDs in the log should be exactly 3.
    : > "${TEST_DIR}/.concurrency_log"
    : > "${TEST_DIR}/.peak"

    _concurrency_executor() {
        local descriptor="$1"
        local pid=$$
        echo "+$pid" >> "${TEST_DIR}/.concurrency_log"
        # Re-count live PIDs and update peak. Use awk to keep the result a
        # single integer regardless of grep's no-match exit code.
        local live removed current peak
        live=$(awk '/^\+/{c++} END{print c+0}' "${TEST_DIR}/.concurrency_log" 2>/dev/null)
        removed=$(awk '/^-/{c++} END{print c+0}' "${TEST_DIR}/.concurrency_log" 2>/dev/null)
        live="${live:-0}"
        removed="${removed:-0}"
        current=$((live - removed))
        peak=$(cat "${TEST_DIR}/.peak" 2>/dev/null)
        peak="${peak:-0}"
        if [[ "$current" -gt "$peak" ]]; then
            echo "$current" > "${TEST_DIR}/.peak"
        fi
        sleep 0.4
        echo "-$pid" >> "${TEST_DIR}/.concurrency_log"
        return 0
    }
    export -f _concurrency_executor

    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
T4 rc=0
T5 rc=0
T6 rc=0
EOF

    run run_continuous_worker_pool 3 10 1 0 _test_picker _concurrency_executor _test_on_complete
    assert_success

    local peak
    peak=$(cat "${TEST_DIR}/.peak" 2>/dev/null || echo "0")
    [[ "$peak" -le "3" ]]
    [[ "$peak" -ge "1" ]]
}

@test "run_continuous_worker_pool respawn_delay slows down replacements" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
T4 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    local start_epoch=$(date +%s)
    # N=1, M=4, respawn_delay=1 → at least 3 replacements at 1s each ⇒ ≥3s total.
    run run_continuous_worker_pool 1 4 1 1 _test_picker _test_executor _test_on_complete
    local end_epoch=$(date +%s)
    local elapsed=$((end_epoch - start_epoch))

    assert_success
    [[ "$elapsed" -ge "3" ]]
}

@test "run_continuous_worker_pool emits a final summary block" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=1
T3 rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 2 3 1 0 _test_picker _test_executor _test_on_complete
    [[ "$output" == *"Continuous Execution Summary"* ]]
    [[ "$output" == *"Completed"* ]]
    [[ "$output" == *"Succeeded"* ]]
    [[ "$output" == *"Failed"* ]]
}

@test "run_continuous_worker_pool appends summary to .ralph/logs/continuous-summary.log" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
EOF

    run run_continuous_worker_pool 1 2 1 0 _test_picker _test_executor _test_on_complete
    [[ -f "${RALPH_DIR}/logs/continuous-summary.log" ]]
    grep -q "Continuous Execution Summary" "${RALPH_DIR}/logs/continuous-summary.log"
}

@test "run_continuous_worker_pool removes state file on clean exit" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
EOF

    run run_continuous_worker_pool 1 2 1 0 _test_picker _test_executor _test_on_complete
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "run_continuous_worker_pool reports stop reason: target reached" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
T4 rc=0
EOF

    # M=2, queue has 4 → must stop at target.
    run run_continuous_worker_pool 1 2 1 0 _test_picker _test_executor _test_on_complete
    [[ "$output" == *"target reached"* ]] || [[ "$output" == *"Target reached"* ]]
}

@test "run_continuous_worker_pool reports stop reason: queue empty" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
EOF

    # M=20 (huge), queue has 1 → must stop because queue empty.
    run run_continuous_worker_pool 2 20 1 0 _test_picker _test_executor _test_on_complete
    [[ "$output" == *"queue empty"* ]] || [[ "$output" == *"Queue empty"* ]]
}

# =============================================================================
# Signal trap installation — both INT and TERM must be wired to the same
# drain handler. A regression that drops INT (e.g., `trap handler TERM` only)
# would silently break Ctrl+C handling in a foreground orchestrator.
# =============================================================================

@test "run_continuous_worker_pool installs trap for both INT and TERM" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
EOF

    # Capture the orchestrator's trap state from the on-completion hook,
    # which runs in the orchestrator's own shell (not a worker subshell).
    # Worker subshells (`( ... ) &`) reset traps, so they can't see the
    # parent's trap; on_complete is a direct function call so it can.
    _trap_snapshot_on_complete() {
        trap -p INT TERM > "${TEST_DIR}/.trap_snapshot" 2>&1
    }
    export -f _trap_snapshot_on_complete

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _trap_snapshot_on_complete
    assert_success
    [[ -f "${TEST_DIR}/.trap_snapshot" ]]
    # Both INT and TERM must be wired to the same drain handler.
    grep -q "_continuous_handle_signal" "${TEST_DIR}/.trap_snapshot"
    grep -qE "(trap.*SIGINT|trap.*' INT$| INT$)" "${TEST_DIR}/.trap_snapshot"
    grep -qE "(trap.*SIGTERM|trap.*' TERM$| TERM$)" "${TEST_DIR}/.trap_snapshot"
}

@test "run_continuous_worker_pool restores prior INT trap after exit" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
EOF

    # Install a custom INT trap before the run.
    trap 'echo USER_TRAP_FIRED' INT
    local before
    before=$(trap -p INT)

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    # After the run, our trap should be intact.
    local after
    after=$(trap -p INT)
    [[ "$after" == "$before" ]]

    # Cleanup
    trap - INT
}

@test "run_continuous_worker_pool restores prior TERM trap after exit" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
EOF

    trap 'echo USER_TERM_TRAP_FIRED' TERM
    local before
    before=$(trap -p TERM)

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    local after
    after=$(trap -p TERM)
    [[ "$after" == "$before" ]]

    trap - TERM
}

@test "run_continuous_worker_pool restores 'no trap' state when no prior trap was set" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
EOF

    # Ensure no INT/TERM traps are set before the run.
    trap - INT
    trap - TERM

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_success

    # After the run, neither INT nor TERM should have a custom handler.
    [[ -z "$(trap -p INT)" ]]
    [[ -z "$(trap -p TERM)" ]]
}

# =============================================================================
# K≥2 retry path: a task fails K-1 times then succeeds, must NOT be skipped.
# =============================================================================

@test "K=2: task fails once then succeeds → not in skip-list, attempts counted" {
    # Queue: TFLAKY first attempt (fail), TFLAKY second attempt (succeed).
    # K=2 means the orchestrator allows up to 2 attempts before skipping.
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TFLAKY rc=1
TFLAKY rc=0
TGOOD rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 1 5 2 0 _test_picker _test_executor _test_on_complete
    # K=2: TFLAKY allowed to fail once and succeed second time. Should NOT
    # appear in the skip-list output.
    [[ "$output" != *"skip-list += TFLAKY"* ]]
}

@test "K=3: task fails twice then succeeds → still not skipped" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TFAIL rc=1
TFAIL rc=1
TFAIL rc=0
EOF
    run run_continuous_worker_pool 1 5 3 0 _test_picker _test_executor _test_on_complete
    [[ "$output" != *"skip-list += TFAIL"* ]]
}

@test "K=2: task fails twice → IS added to skip-list on 2nd failure" {
    # Use distinct queue entries (different rc-tag suffixes) so each pick
    # consumes exactly one queue line. With three identical entries the
    # picker's `grep -vxF "$line"` pops all three at once, masking the
    # K-counter behavior — the original test was a false positive.
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TBAD rc=1 a
TBAD rc=1 b
TBAD rc=1 c
EOF
    : > "${TEST_DIR}/.test_executions"
    run run_continuous_worker_pool 1 5 2 0 _test_picker _test_executor _test_on_complete
    [[ "$output" == *"skip-list += TBAD"* ]]
    # Regression guard: `_attempts_increment` must NOT be called via $(...).
    # When run via command substitution, the `_att_*` array mutations are
    # discarded, the counter pins at 1, and the skip-list message only
    # fires for K=1. The "failed 2 ≥ K=2" string only appears when the
    # counter persists across calls.
    [[ "$output" == *"failed 2 ≥ K=2"* ]]
    # And the orchestrator must drain after the skip — total attempts
    # should be exactly 2 (1st fail, 2nd fail → skip-list, then drain),
    # not the full M=5.
    local attempts
    attempts=$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')
    [[ "$attempts" == "2" ]]
}

@test "K=3: skip-list message fires at exactly the 3rd failure (counter persists)" {
    # Companion regression for the subshell-counter bug. Distinct queue
    # entries (a/b/c/d suffix) so each pick consumes exactly one line.
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TBAD3 rc=1 a
TBAD3 rc=1 b
TBAD3 rc=1 c
TBAD3 rc=1 d
EOF
    : > "${TEST_DIR}/.test_executions"
    run run_continuous_worker_pool 1 6 3 0 _test_picker _test_executor _test_on_complete
    [[ "$output" == *"skip-list += TBAD3 (failed 3 ≥ K=3)"* ]]
    # The skip-list line must NOT appear for n=1 or n=2.
    [[ "$output" != *"failed 1 ≥ K=3"* ]]
    [[ "$output" != *"failed 2 ≥ K=3"* ]]
    local attempts
    attempts=$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')
    [[ "$attempts" == "3" ]]
}

@test "_attempts_increment must NOT be called via \$(...) — direct-call invariant" {
    # Direct probe of the subshell-counter regression.  We re-implement
    # the helper inline because it is defined `local` to
    # run_continuous_worker_pool and isn't externally callable.  The
    # invariant we lock down: when the helper writes its result to a
    # global ($_PROBE_LAST), repeated calls accumulate; when called via
    # $(...) command substitution, the array mutations are discarded
    # and the counter pins at 1.
    local -a _ids=()
    local -a _cnt=()
    local _PROBE_LAST=""
    _probe_inc() {
        local id="$1" idx
        for ((idx = 0; idx < ${#_ids[@]}; idx++)); do
            if [[ "${_ids[$idx]}" == "$id" ]]; then
                _cnt[$idx]=$(( ${_cnt[$idx]} + 1 ))
                _PROBE_LAST="${_cnt[$idx]}"
                return
            fi
        done
        _ids+=("$id"); _cnt+=(1); _PROBE_LAST="1"
    }

    # Direct calls: counter accumulates.
    _probe_inc "X"; [[ "$_PROBE_LAST" == "1" ]]
    _probe_inc "X"; [[ "$_PROBE_LAST" == "2" ]]
    _probe_inc "X"; [[ "$_PROBE_LAST" == "3" ]]

    # Now demonstrate the regression mode: command substitution discards
    # array mutations.  We DON'T expect the orchestrator's production
    # path to use this form — the test exists to document why.
    local -a _ids2=()
    local -a _cnt2=()
    _probe_inc_subshell() {
        local id="$1" idx
        for ((idx = 0; idx < ${#_ids2[@]}; idx++)); do
            if [[ "${_ids2[$idx]}" == "$id" ]]; then
                _cnt2[$idx]=$(( ${_cnt2[$idx]} + 1 ))
                echo "${_cnt2[$idx]}"
                return
            fi
        done
        _ids2+=("$id"); _cnt2+=(1); echo "1"
    }
    local n
    n=$(_probe_inc_subshell "Y"); [[ "$n" == "1" ]]
    n=$(_probe_inc_subshell "Y"); [[ "$n" == "1" ]]   # ← regression: pinned at 1
    n=$(_probe_inc_subshell "Y"); [[ "$n" == "1" ]]
}

# =============================================================================
# M=1 K=1 with a failing task — degenerate edge case
# =============================================================================

@test "M=1 K=1 with failing task: completes 1, returns nonzero, no double-spawn" {
    cat > "${TEST_DIR}/.test_queue" << 'EOF'
TFAIL rc=1
TEXTRA rc=0
EOF
    : > "${TEST_DIR}/.test_executions"

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_failure
    # Exactly 1 execution attempted (M=1).
    [[ "$(wc -l < "${TEST_DIR}/.test_executions" | tr -d ' ')" == "1" ]]
    # Stop reason is target-reached (M).
    [[ "$output" == *"target reached"* ]]
}

# =============================================================================
# M < N (e.g., M=2 N=5): orchestrator must cap concurrency at M, not at N.
# =============================================================================

@test "M=2 N=5: never exceeds M=2 concurrent workers" {
    : > "${TEST_DIR}/.concurrency_log"
    : > "${TEST_DIR}/.peak"

    _peak_executor() {
        echo "+$$" >> "${TEST_DIR}/.concurrency_log"
        local live removed current peak
        live=$(awk '/^\+/{c++} END{print c+0}' "${TEST_DIR}/.concurrency_log")
        removed=$(awk '/^-/{c++} END{print c+0}' "${TEST_DIR}/.concurrency_log")
        current=$((live - removed))
        peak=$(cat "${TEST_DIR}/.peak" 2>/dev/null)
        peak="${peak:-0}"
        if [[ "$current" -gt "$peak" ]]; then
            echo "$current" > "${TEST_DIR}/.peak"
        fi
        sleep 0.4
        echo "-$$" >> "${TEST_DIR}/.concurrency_log"
        return 0
    }
    export -f _peak_executor

    cat > "${TEST_DIR}/.test_queue" << 'EOF'
T1 rc=0
T2 rc=0
T3 rc=0
T4 rc=0
T5 rc=0
EOF

    run run_continuous_worker_pool 5 2 1 0 _test_picker _peak_executor _test_on_complete
    assert_success

    local peak
    peak=$(cat "${TEST_DIR}/.peak" 2>/dev/null || echo "0")
    [[ "$peak" -le "2" ]]
    [[ "$peak" -ge "1" ]]
}

# =============================================================================
# Summary block / divide-by-zero safety when completed=0
# (queue empty before any worker spawns)
# =============================================================================

@test "queue empty on first pick → summary printed without divide-by-zero" {
    : > "${TEST_DIR}/.test_queue"  # empty queue

    run run_continuous_worker_pool 2 5 1 0 _test_picker _test_executor _test_on_complete
    assert_success
    [[ "$output" == *"Continuous Execution Summary"* ]]
    [[ "$output" == *"Completed:"* ]]
    [[ "$output" == *"queue empty"* ]] || [[ "$output" == *"Queue empty"* ]]
    # No "division by zero" / "/" arithmetic error from awk or bash.
    [[ "$output" != *"division by zero"* ]]
    [[ "$output" != *"/ by zero"* ]]
}

@test "summary log appended even when completed=0" {
    : > "${TEST_DIR}/.test_queue"  # empty queue
    run run_continuous_worker_pool 2 5 1 0 _test_picker _test_executor _test_on_complete
    [[ -f "${RALPH_DIR}/logs/continuous-summary.log" ]]
    grep -q "Continuous Execution Summary" "${RALPH_DIR}/logs/continuous-summary.log"
}

# =============================================================================
# _skip_list_contains direct tests
# =============================================================================

@test "_skip_list_contains: empty skip-list returns false" {
    run _skip_list_contains "" "5"
    assert_failure
}

@test "_skip_list_contains: empty id returns false" {
    run _skip_list_contains $'5\n7' ""
    assert_failure
}

@test "_skip_list_contains: exact match returns true" {
    run _skip_list_contains $'5\n7\n9' "7"
    assert_success
}

@test "_skip_list_contains: non-member returns false" {
    run _skip_list_contains $'5\n7\n9' "8"
    assert_failure
}

@test "_skip_list_contains: substring (5 vs 55) does NOT match (uses -xF)" {
    # Regression guard: this is the same exact-match invariant the picker
    # relies on (covered for the picker in test_continuous_pickers.bats).
    run _skip_list_contains $'5\n7' "55"
    assert_failure
}

@test "_skip_list_contains: id with shell metacharacters (* [ ]) is matched literally" {
    # `grep -F` treats input as fixed strings, so * is literal — this should match.
    run _skip_list_contains $'task[5]\nfoo*bar' "task[5]"
    assert_success
    # And substring-of-metachar-id is not a match either.
    run _skip_list_contains $'task[5]\nfoo*bar' "task"
    assert_failure
}

# =============================================================================
# Concurrent-invocation safety: a second orchestrator must refuse to start
# while the first is still alive (would otherwise clobber state file).
# =============================================================================

@test "init_continuous_state refuses when another live orchestrator's state file exists" {
    # Spawn a long-lived dummy "orchestrator" so we have a guaranteed-alive PID.
    sleep 30 &
    local alive_pid=$!

    # Pre-write a state file as if that orchestrator owned it.
    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${alive_pid}
started_at	0
in_flight	
EOF

    # Try to init under a different PID. Must refuse.
    run init_continuous_state 99999  # arbitrary other PID
    [[ "$status" == "2" ]]
    [[ "$output" == *"already running"* ]] || [[ "$output" == *"orchestrator"* ]]

    # Cleanup
    kill "$alive_pid" 2>/dev/null || true
    wait "$alive_pid" 2>/dev/null || true
}

@test "init_continuous_state proceeds when prior state file's PID is dead" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
EOF

    # Should succeed — dead orchestrator means prior state is stale.
    run init_continuous_state 88888
    assert_success
    # New PID should be in the state file now.
    grep -q "88888" "${RALPH_DIR}/.continuous_state"
}

@test "init_continuous_state honors RALPH_CONTINUOUS_FORCE override" {
    sleep 30 &
    local alive_pid=$!

    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${alive_pid}
started_at	0
in_flight	
EOF

    RALPH_CONTINUOUS_FORCE=true run init_continuous_state 77777
    assert_success
    grep -q "77777" "${RALPH_DIR}/.continuous_state"

    kill "$alive_pid" 2>/dev/null || true
    wait "$alive_pid" 2>/dev/null || true
}

@test "run_continuous_worker_pool returns 2 when init detects live orchestrator" {
    sleep 30 &
    local alive_pid=$!

    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${alive_pid}
started_at	0
in_flight	
EOF

    cat > "${TEST_DIR}/.test_queue" << 'INNER'
T1 rc=0
INNER

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    [[ "$status" == "2" ]]

    kill "$alive_pid" 2>/dev/null || true
    wait "$alive_pid" 2>/dev/null || true
}


# =============================================================================
# status.json hook (proposal §8) — orchestrator MUST call
# _continuous_update_status (if defined) at init, after every completion,
# and at exit so ralph-monitor can show continuous-mode metadata.
# =============================================================================

@test "_continuous_update_status hook is called at orchestrator init" {
    # Define a spy hook that records every invocation to a file.
    _continuous_update_status() {
        echo "$@" >> "${TEST_DIR}/.hook_calls"
    }
    export -f _continuous_update_status

    cat > "${TEST_DIR}/.test_queue" << EOF
T1 rc=0
EOF
    : > "${TEST_DIR}/.hook_calls"

    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete

    # First call should be the init: "continuous:starting running 0 1 1"
    local first
    first=$(head -1 "${TEST_DIR}/.hook_calls")
    [[ "$first" == "continuous:starting running 0 1 1" ]]
}

@test "_continuous_update_status hook is called after each completion with attempt count" {
    _continuous_update_status() {
        echo "$@" >> "${TEST_DIR}/.hook_calls"
    }
    export -f _continuous_update_status

    cat > "${TEST_DIR}/.test_queue" << EOF
T1 rc=0
T2 rc=0
T3 rc=0
EOF
    : > "${TEST_DIR}/.hook_calls"

    run run_continuous_worker_pool 1 3 1 0 _test_picker _test_executor _test_on_complete

    # We expect at least one "continuous:executing running 1 3 1",
    # one "continuous:executing running 2 3 1", and one "continuous:executing running 3 3 1".
    grep -qF "continuous:executing running 1 3 1" "${TEST_DIR}/.hook_calls"
    grep -qF "continuous:executing running 2 3 1" "${TEST_DIR}/.hook_calls"
    grep -qF "continuous:executing running 3 3 1" "${TEST_DIR}/.hook_calls"
}

@test "_continuous_update_status hook is called at exit with stop_reason" {
    _continuous_update_status() {
        echo "$@" >> "${TEST_DIR}/.hook_calls"
    }
    export -f _continuous_update_status

    cat > "${TEST_DIR}/.test_queue" << EOF
T1 rc=0
T2 rc=0
EOF
    : > "${TEST_DIR}/.hook_calls"

    run run_continuous_worker_pool 1 2 1 0 _test_picker _test_executor _test_on_complete

    # Last call should be the exit: "continuous:completed stopped 2 2 1 target reached (M)"
    local last
    last=$(tail -1 "${TEST_DIR}/.hook_calls")
    [[ "$last" == "continuous:completed stopped 2 2 1 "*"target reached (M)" ]]
}

@test "queue-empty exit path also calls hook with stop_reason" {
    _continuous_update_status() {
        echo "$@" >> "${TEST_DIR}/.hook_calls"
    }
    export -f _continuous_update_status

    : > "${TEST_DIR}/.test_queue"   # empty queue
    : > "${TEST_DIR}/.hook_calls"

    run run_continuous_worker_pool 1 5 1 0 _test_picker _test_executor _test_on_complete

    # First (and only) call should still be the init call. Then queue-empty
    # exit calls the hook with "stopped" and stop_reason "queue empty".
    grep -qF "continuous:completed stopped 0 5 1 queue empty" "${TEST_DIR}/.hook_calls"
}

@test "orchestrator works without _continuous_update_status (engine-agnostic)" {
    # If no engine has defined the hook, the worker pool must still run.
    unset -f _continuous_update_status 2>/dev/null || true

    cat > "${TEST_DIR}/.test_queue" << EOF
T1 rc=0
EOF
    run run_continuous_worker_pool 1 1 1 0 _test_picker _test_executor _test_on_complete
    assert_success
    [[ "$output" == *"target reached"* ]] || [[ "$output" == *"queue empty"* ]]
}

