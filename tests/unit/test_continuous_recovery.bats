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

# =============================================================================
# Corrupt / partial-write state file matrix — must never crash, never corrupt
# fix_plan.md, never leave stale [~] markers when the orchestrator is dead.
# =============================================================================

@test "sweeper handles empty state file (zero bytes)" {
    : > "${RALPH_DIR}/.continuous_state"
    run sweep_stale_continuous_state
    assert_success
}

@test "sweeper handles state file missing orchestrator_pid row" {
    cat > "${RALPH_DIR}/.continuous_state" << 'EOF'
started_at	0
in_flight
EOF
    run sweep_stale_continuous_state
    # No PID to check → log warning and bail gracefully.
    assert_success
}

@test "sweeper skips inflight rows with non-numeric line_num" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Task A
- [~] Task B
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # State file: one valid inflight row (line 2), one with garbage line_num.
    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight	notanumber	T-bad	11111
inflight	2	T-good	22222
EOF

    run sweep_stale_continuous_state
    assert_success
    # Bad row ignored, good row reverted.
    sed -n '2p' "${TEST_DIR}/fix_plan.md" | grep -q '\[ \] Task B'
    # State file cleaned up.
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "sweeper skips inflight rows with line_num past EOF of fix_plan" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Only task
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # Reference a non-existent line 99 (file shrank between crash and sweep,
    # e.g., user hand-edited).
    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight	99	T-stale	33333
EOF

    run sweep_stale_continuous_state
    # Must not crash, must not corrupt the file, must clean up state.
    assert_success
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
    # File content unchanged (still 1 line).
    [[ "$(wc -l < "${TEST_DIR}/fix_plan.md" | tr -d ' ')" -le "1" ]] \
        || [[ "$(wc -l < "${TEST_DIR}/fix_plan.md" | tr -d ' ')" == "1" ]]
}

@test "sweeper does not modify lines that are not [~] (e.g. already [x] or [ ])" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [x] Already done
- [ ] Already reverted
- [~] Still in flight
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # State file lists ALL three lines, even though only line 3 is [~].
    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight	1	T-done	11111
inflight	2	T-reverted	22222
inflight	3	T-flight	33333
EOF

    run sweep_stale_continuous_state
    assert_success
    # Line 1 still [x], line 2 still [ ], line 3 reverted.
    sed -n '1p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[x\] Already done$'
    sed -n '2p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[ \] Already reverted$'
    sed -n '3p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[ \] Still in flight$'
}

@test "sweeper handles inflight row with empty line_num field" {
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [~] Task A
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # Empty line_num field (3 fields after `inflight` separator instead of 4).
    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight		T-empty	44444
inflight	1	T-real	55555
EOF

    run sweep_stale_continuous_state
    assert_success
    # The empty-line_num row is ignored; the valid row reverts line 1.
    grep -q '^- \[ \] Task A$' "${TEST_DIR}/fix_plan.md"
    [[ ! -f "${RALPH_DIR}/.continuous_state" ]]
}

@test "sweeper preserves [x] markers when reverting [~] on adjacent lines" {
    # Regression guard: an awk substitution bug could overwrite [x] with [ ].
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    cat > "${TEST_DIR}/fix_plan.md" << 'EOF'
- [x] Completed first
- [~] In flight
- [x] Completed second
EOF
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight	2	T-mid	66666
EOF

    run sweep_stale_continuous_state
    assert_success
    sed -n '1p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[x\] Completed first$'
    sed -n '2p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[ \] In flight$'
    sed -n '3p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[x\] Completed second$'
}

@test "P2 #18: sweeper recovers indented and non-dash-prefixed [~] markers" {
    # The picker only writes `- [~]` but a hand-edited fix_plan may use
    # indented bullets (`  - [~]`), star bullets (`* [~]`), or a tab prefix.
    # The relaxed regex must revert all of them.
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    printf '  - [~] indented dash\n* [~] star bullet\n\t- [~] tabbed dash\n- [~] standard\n' > "${TEST_DIR}/fix_plan.md"
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    cat > "${RALPH_DIR}/.continuous_state" << EOF
orchestrator_pid	${dead_pid}
started_at	0
in_flight	
inflight	1	T-indent	11111
inflight	2	T-star	22222
inflight	3	T-tab	33333
inflight	4	T-std	44444
EOF

    run sweep_stale_continuous_state
    assert_success
    # All four variants reverted; no [~] left anywhere.
    ! grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
    # Prefix preserved on each line (only the marker flipped). Use $'…' for
    # the tab variant since macOS BSD grep lacks -P (Perl regex).
    sed -n '1p' "${TEST_DIR}/fix_plan.md" | grep -q '^  - \[ \] indented dash$'
    sed -n '2p' "${TEST_DIR}/fix_plan.md" | grep -q '^\* \[ \] star bullet$'
    [[ "$(sed -n '3p' "${TEST_DIR}/fix_plan.md")" == $'\t- [ ] tabbed dash' ]]
    sed -n '4p' "${TEST_DIR}/fix_plan.md" | grep -q '^- \[ \] standard$'
}

@test "P2 #17: sweeper performs a single awk pass over fix_plan (no O(N·R) rewrites)" {
    # Regression guard for the per-row sed+awk+mv pattern. We can't directly
    # observe the awk invocation, but we can confirm correctness on a state
    # file with many in-flight rows. The key property: an N-line fix_plan
    # with R in-flight markers should produce the same final state as the
    # old loop, atomically.
    sh -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    # Build a 20-line fix_plan with 10 [~] markers on even lines.
    : > "${TEST_DIR}/fix_plan.md"
    local i
    for ((i = 1; i <= 20; i++)); do
        if (( i % 2 == 0 )); then
            echo "- [~] task ${i}" >> "${TEST_DIR}/fix_plan.md"
        else
            echo "- [ ] task ${i}" >> "${TEST_DIR}/fix_plan.md"
        fi
    done
    export WORKSPACE_FIX_PLAN="${TEST_DIR}/fix_plan.md"

    # Record all 10 even-numbered lines as inflight.
    {
        echo "orchestrator_pid	${dead_pid}"
        echo "started_at	0"
        printf 'in_flight\t\n'
        for ((i = 2; i <= 20; i += 2)); do
            printf 'inflight\t%d\tT-%d\t%d\n' "$i" "$i" "$((10000 + i))"
        done
    } > "${RALPH_DIR}/.continuous_state"

    run sweep_stale_continuous_state
    assert_success
    # No [~] left, all 10 even lines reverted to [ ].
    ! grep -q '\[~\]' "${TEST_DIR}/fix_plan.md"
    # Odd lines (which started [ ]) are untouched.
    [[ "$(grep -c '^- \[ \] task ' "${TEST_DIR}/fix_plan.md")" == "20" ]]
    # File size sanity: 20 lines still.
    [[ "$(wc -l < "${TEST_DIR}/fix_plan.md" | tr -d ' ')" == "20" ]]
}
