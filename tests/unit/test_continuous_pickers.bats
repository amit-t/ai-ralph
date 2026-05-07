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
