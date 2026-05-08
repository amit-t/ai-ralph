#!/usr/bin/env bats
# Unit tests for the skip-list-aware picker wrappers used by the worker pool:
#   pick_workspace_task_for_pool  (lib/workspace_manager.sh)
#   pick_next_task_for_pool       (lib/task_sources.sh)
# See docs/proposals/continuous-parallel-execution.md §5.3

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
TASK_SOURCES_LIB="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$TASK_SOURCES_LIB" ]]; then
        source "$TASK_SOURCES_LIB"
    fi
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# pick_workspace_task_for_pool
# =============================================================================

@test "pick_workspace_task_for_pool exists" {
    declare -F pick_workspace_task_for_pool > /dev/null
}

@test "pick_workspace_task_for_pool picks a task with empty skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task

## repo-beta
- [ ] Second task
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
    [[ "$output" == *"First task"* ]]
}

@test "pick_workspace_task_for_pool skips lines listed in skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task

## repo-beta
- [ ] Second task
EOF

    # The first picker call would yield line 4 (or whatever line the first
    # task is on). Pre-mark that line in the skip-list.
    local first
    first=$(pick_workspace_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f3)
    # Re-set fix_plan back to [ ] so we can re-pick.
    revert_workspace_task "${TEST_DIR}/.ralph/fix_plan.md" "$first_line"

    local skip_list="$first_line"
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "$skip_list"
    assert_success
    # The picker should have skipped the first task and chosen the second.
    [[ "$output" != *"$first_line|"* ]] || [[ "$output" == *"Second task"* ]]
    [[ "$output" == *"repo-beta"* ]] || [[ "$output" == *"Second"* ]]
}

@test "pick_workspace_task_for_pool returns failure when all eligible are skipped" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Only task
EOF
    # Skip lines 4 (the only task) and 5 to exhaust the queue.
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" $'4\n5\n6\n7\n8'
    assert_failure
}

@test "pick_workspace_task_for_pool atomically marks picked task in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task to mark
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    grep -q '\[~\]' "${TEST_DIR}/.ralph/fix_plan.md"
}

@test "pick_workspace_task_for_pool output format matches pick_workspace_task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Format check task
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output: repo|task_id|line_num|description
    echo "$output" | grep -qE '^repo-alpha\|[a-z0-9-]+\|[0-9]+\|Format check task$'
}

# =============================================================================
# pick_next_task_for_pool
# =============================================================================

@test "pick_next_task_for_pool exists" {
    declare -F pick_next_task_for_pool > /dev/null
}

@test "pick_next_task_for_pool picks a task with empty skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output format from pick_next_task: task_id|line_num|bead_id
    echo "$output" | grep -qE '\|[0-9]+\|'
}

@test "pick_next_task_for_pool skips lines in skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
- [ ] Task three
EOF

    # Pick + revert to identify the first line, then put it in skip-list.
    local first
    first=$(pick_next_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f2)
    awk -v ln="$first_line" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' \
        "${TEST_DIR}/.ralph/fix_plan.md" > "${TEST_DIR}/.ralph/fix_plan.md.tmp" \
        && mv "${TEST_DIR}/.ralph/fix_plan.md.tmp" "${TEST_DIR}/.ralph/fix_plan.md"

    run pick_next_task_for_pool ".ralph/fix_plan.md" "$first_line"
    assert_success
    # Should not pick the first line again.
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" != "$first_line" ]]
}

@test "pick_next_task_for_pool returns failure when all unclaimed are skipped" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Lone task
EOF

    # The only task is on line 2 (line 1 is the heading).
    run pick_next_task_for_pool ".ralph/fix_plan.md" $'2\n3\n4'
    assert_failure
}

@test "pick_next_task_for_pool atomically marks picked task in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task to mark
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    grep -q '\[~\]' "${TEST_DIR}/.ralph/fix_plan.md"
}

@test "pick_next_task_for_pool output format matches pick_next_task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Format check task
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output: task_id|line_num|bead_id  (bead_id may be empty)
    echo "$output" | grep -qE '^[a-zA-Z0-9_-]+\|[0-9]+\|'
}

# =============================================================================
# Concurrent picker race: N parallel callers must each get a distinct line
# under the .task_pick_lock / .workspace_task_lock atomic.
# =============================================================================

@test "pick_next_task_for_pool: 5 concurrent callers each get a distinct line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
- [ ] Task three
- [ ] Task four
- [ ] Task five
EOF

    : > "${TEST_DIR}/.picks"
    local pids=()
    for _ in 1 2 3 4 5; do
        (
            out=$(pick_next_task_for_pool ".ralph/fix_plan.md" "" 2>/dev/null) || out="MISS"
            echo "$out" >> "${TEST_DIR}/.picks"
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Each pick is "task_id|line_num|bead_id". Extract the line numbers and
    # assert they are unique. With 5 tasks and 5 racing pickers, all 5 should
    # have hit a distinct line.
    local picked_lines
    picked_lines=$(awk -F'|' '$2 ~ /^[0-9]+$/ {print $2}' "${TEST_DIR}/.picks" | sort -n)
    local unique
    unique=$(echo "$picked_lines" | sort -u)
    [[ "$picked_lines" == "$unique" ]]
    # All 5 must be claimed (no MISS).
    ! grep -q '^MISS$' "${TEST_DIR}/.picks"
    [[ "$(echo "$unique" | wc -l | tr -d ' ')" == "5" ]]
}

@test "pick_next_task_for_pool: under contention, total [~] count equals total picks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] T1
- [ ] T2
- [ ] T3
- [ ] T4
- [ ] T5
- [ ] T6
EOF

    local pids=()
    for _ in 1 2 3 4; do
        ( pick_next_task_for_pool ".ralph/fix_plan.md" "" >/dev/null 2>&1 ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Exactly 4 lines should now be [~] (no double-claims, no missed claims).
    local in_progress
    in_progress=$(grep -c '^- \[~\]' .ralph/fix_plan.md)
    [[ "$in_progress" == "4" ]]
}

@test "pick_workspace_task_for_pool: 3 concurrent callers each get a distinct repo+line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] alpha-task
- [ ] alpha-task-2

## repo-b
- [ ] beta-task

## repo-c
- [ ] gamma-task
EOF

    : > "${TEST_DIR}/.ws_picks"
    local pids=()
    for _ in 1 2 3; do
        (
            out=$(pick_workspace_task_for_pool ".ralph/fix_plan.md" "" 2>/dev/null) || out="MISS"
            echo "$out" >> "${TEST_DIR}/.ws_picks"
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Output format: repo|task_id|line|description
    # Distinct line numbers => no double-claim.
    local picked_lines
    picked_lines=$(awk -F'|' '$3 ~ /^[0-9]+$/ {print $3}' "${TEST_DIR}/.ws_picks" | sort -n)
    local unique
    unique=$(echo "$picked_lines" | sort -u)
    [[ "$picked_lines" == "$unique" ]]
    [[ "$(echo "$unique" | wc -l | tr -d ' ')" == "3" ]]
}

# =============================================================================
# Lock-acquisition failure path: when _acquire_task_lock fails, the picker
# returns 1 (not 0 with empty stdout). The orchestrator interprets a 1 from
# the picker as "queue empty / no eligible task," which is what we want
# (better than crashing or silently picking duplicates).
# =============================================================================

@test "pick_next_task_for_pool returns failure if _acquire_task_lock fails" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
EOF

    # Override _acquire_task_lock to always fail (simulates lock contention
    # exceeding the timeout).
    _acquire_task_lock() { return 1; }
    export -f _acquire_task_lock

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_failure
    # The picker should not have claimed anything.
    ! grep -q '\[~\]' .ralph/fix_plan.md
}

@test "pick_workspace_task_for_pool returns failure if _acquire_task_lock fails" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] alpha-task
EOF

    _acquire_task_lock() { return 1; }
    export -f _acquire_task_lock

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_failure
    ! grep -q '\[~\]' .ralph/fix_plan.md
}

# =============================================================================
# Skip-list edge cases
# =============================================================================

@test "pick_next_task_for_pool skip-list does NOT match line-number prefixes (5 vs 55)" {
    # Regression guard for `grep -F` (substring) vs `grep -xF` (exact-match)
    # in skip-list filtering. The skip-list is line numbers; if the picker
    # used substring matching, a skip-list of "5" would also exclude line 55.
    mkdir -p .ralph
    {
        echo "# Fix Plan"
        # Add 60 tasks so we have lines 2..61.
        for i in $(seq 1 60); do
            echo "- [ ] Task $i"
        done
    } > .ralph/fix_plan.md

    # Skip line 5 only. The picker should pick line 2 (first unclaimed).
    run pick_next_task_for_pool ".ralph/fix_plan.md" "5"
    assert_success
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" == "2" ]]

    # Now pre-mark lines 2,3,4,5 [~] and skip line 5; picker should pick 6, NOT 55.
    awk 'NR>=2 && NR<=5 { sub(/- \[ \]/, "- [~]") } 1' .ralph/fix_plan.md > .ralph/fix_plan.md.tmp \
        && mv .ralph/fix_plan.md.tmp .ralph/fix_plan.md
    run pick_next_task_for_pool ".ralph/fix_plan.md" "5"
    assert_success
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" == "6" ]]
}

@test "pick_next_task_for_pool skip-list ignores trailing blank line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
EOF
    # Skip-list with trailing newline.
    run pick_next_task_for_pool ".ralph/fix_plan.md" $'2\n'
    assert_success
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" == "3" ]]
}
