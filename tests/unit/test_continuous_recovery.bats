#!/usr/bin/env bats
# Unit tests for lib/continuous_recovery.sh — startup sweeper for stale [~] markers
# See docs/proposals/continuous-parallel-execution.md §16

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
RECOVERY_LIB="${BATS_TEST_DIRNAME}/../../lib/continuous_recovery.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"

    if [[ -f "$WORKER_POOL_LIB" ]]; then
        source "$WORKER_POOL_LIB"
    fi
    if [[ -f "$RECOVERY_LIB" ]]; then
        source "$RECOVERY_LIB"
    fi

    # Stand-in for engines' log_status.
    log_status() {
        local level="$1"; shift
        echo "[$level] $*"
    }
    export -f log_status
    log_info() {
        echo "[INFO] $*"
    }
    export -f log_info
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

@test "lib/continuous_recovery.sh exists" {
    [[ -f "$RECOVERY_LIB" ]]
}

@test "continuous_recovery.sh exports sweep_stale_continuous_state" {
    declare -F sweep_stale_continuous_state > /dev/null
}

# =============================================================================
# sweep_stale_continuous_state — no-op behavior
# =============================================================================

@test "sweeper is a no-op when state file is absent" {
    run sweep_stale_continuous_state
    assert_success
    [[ -z "$output" ]]
}

@test "sweeper is a no-op when orchestrator PID is alive" {
    # Use the test process's own PID as the orchestrator — it is, by
    # definition, alive while the test runs.
    init_continuous_state $$
    record_inflight 5 "T-1" 99999

    # Create a fix_plan.md with [~] markers.
    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] In progress task A
- [~] In progress task B
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    run sweep_stale_continuous_state
    assert_success
    # State file untouched, fix_plan unchanged.
    [[ -f "${RALPH_DIR}/.continuous_state" ]]
    grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
}

# =============================================================================
# sweep_stale_continuous_state — recovery behavior
# =============================================================================

@test "sweeper reverts [~] to [ ] when orchestrator PID is dead" {
    # Spawn a short-lived process to get a guaranteed-dead PID.
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    record_inflight 1 "T-A" 88888
    record_inflight 2 "T-B" 88889

    # Build a fix_plan with [~] markers on lines 1 and 2.
    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Task A description
- [~] Task B description
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    run sweep_stale_continuous_state
    assert_success
    # Both lines should be reverted to [ ].
    ! grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
    grep -q '^\- \[ \] Task A description$' "${TEST_DIR}/fix_plan.md"
    grep -q '^\- \[ \] Task B description$' "${TEST_DIR}/fix_plan.md"
    # State file is removed.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "sweeper reverts only the lines listed in state file (not other [~] markers)" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    record_inflight 2 "T-B" 77777

    # Two [~] markers but state only mentions line 2.
    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Task A (untouched)
- [~] Task B (state-listed)
- [x] Task C
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    run sweep_stale_continuous_state
    assert_success

    # Line 1 still [~]
    sed -n '1p' "${TEST_DIR}/fix_plan.md" | grep -q '\[~\] Task A'
    # Line 2 reverted
    sed -n '2p' "${TEST_DIR}/fix_plan.md" | grep -q '\[ \] Task B'
}

@test "sweeper logs which lines were reverted" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    record_inflight 1 "T-X" 66666

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Task X
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    run sweep_stale_continuous_state
    assert_success
    [[ "$output" == *"line 1"* ]] || [[ "$output" == *"Reverted"* ]]
    [[ "$output" == *"T-X"* ]] || [[ "$output" == *"task"* ]] || [[ "$output" == *"Task"* ]]
}

@test "sweeper handles state file with no in_flight entries" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    # No record_inflight calls.

    run sweep_stale_continuous_state
    assert_success
    # No fix_plan to touch — sweeper should still clean up the state file.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "sweeper handles missing fix_plan gracefully" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    record_inflight 5 "T-Y" 55555

    export WORKSPACE_FIX_PLAN="${TEST_DIR}/does-not-exist.md"

    run sweep_stale_continuous_state
    # Should not crash; should clean up state file.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "sweeper falls back to .ralph/fix_plan.md when WORKSPACE_FIX_PLAN unset" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    init_continuous_state "$dead_pid"
    record_inflight 1 "T-Z" 44444

    cat > "${RALPH_DIR}/fix_plan.md" << 'EOF'
- [~] Task Z
EOF
    unset WORKSPACE_FIX_PLAN

    run sweep_stale_continuous_state
    assert_success
    grep -q '\[ \] Task Z' "${RALPH_DIR}/fix_plan.md"
}

@test "sweeper handles malformed orchestrator PID gracefully" {
    # Manually write an invalid state file.
    cat > "${RALPH_DIR}/.continuous_state" << 'EOF'
orchestrator_pid	not-a-number
started_at	0
in_flight
EOF

    run sweep_stale_continuous_state
    # Should not crash the calling shell; behavior is "treat as alive" or
    # "log warning and skip". Either way, returns 0.
    assert_success
}
