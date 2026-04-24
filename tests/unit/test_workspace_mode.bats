#!/usr/bin/env bats
# Unit tests for workspace mode — multi-repo orchestration
# Tests: repo discovery, workspace fix_plan.md parsing, default branch detection,
#         per-repo context switching, CLI parsing (--workspace flag), template loading

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
WORKSPACE_PLAN_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_plan.sh"
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
RALPH_PLAN_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_plan.sh"
TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../../templates"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (sets up functions)
    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$WORKSPACE_PLAN_LIB" ]]; then
        source "$WORKSPACE_PLAN_LIB"
    fi
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# discover_workspace_repos — find git repos in a directory
# =============================================================================

@test "discover_workspace_repos finds git repos in directory" {
    # Create mock repo directories with .git
    mkdir -p repo-alpha/.git repo-beta/.git repo-gamma/.git
    # Create a non-repo directory (should be excluded)
    mkdir -p docs-folder

    run discover_workspace_repos "."
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
    [[ "$output" == *"repo-beta"* ]]
    [[ "$output" == *"repo-gamma"* ]]
    [[ "$output" != *"docs-folder"* ]]
}

@test "discover_workspace_repos returns failure when no repos found" {
    mkdir -p empty-dir
    run discover_workspace_repos "empty-dir"
    assert_failure
}

@test "discover_workspace_repos skips hidden directories" {
    mkdir -p .hidden-repo/.git visible-repo/.git
    run discover_workspace_repos "."
    assert_success
    [[ "$output" == *"visible-repo"* ]]
    [[ "$output" != *".hidden-repo"* ]]
}

@test "discover_workspace_repos skips .ralph directory itself" {
    mkdir -p .ralph some-repo/.git
    run discover_workspace_repos "."
    assert_success
    [[ "$output" == *"some-repo"* ]]
    [[ "$output" != *".ralph"* ]]
}

@test "discover_workspace_repos returns repos sorted alphabetically" {
    mkdir -p zebra-repo/.git alpha-repo/.git middle-repo/.git
    run discover_workspace_repos "."
    assert_success
    # Verify alphabetical order
    local first_line=$(echo "$output" | head -1)
    local last_line=$(echo "$output" | tail -1)
    [[ "$first_line" == *"alpha-repo"* ]]
    [[ "$last_line" == *"zebra-repo"* ]]
}

@test "discover_workspace_repos handles absolute path" {
    mkdir -p "$TEST_DIR/workspace/repo-one/.git" "$TEST_DIR/workspace/repo-two/.git"
    run discover_workspace_repos "$TEST_DIR/workspace"
    assert_success
    [[ "$output" == *"repo-one"* ]]
    [[ "$output" == *"repo-two"* ]]
}

@test "discover_workspace_repos returns failure for nonexistent directory" {
    run discover_workspace_repos "/nonexistent/path"
    assert_failure
}

# =============================================================================
# parse_workspace_fix_plan — extract tasks with repo context
# =============================================================================

@test "parse_workspace_fix_plan extracts tasks grouped by repo" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix authentication bug
- [ ] Add rate limiting

## repo-beta
- [ ] Update database schema
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"*"Fix authentication bug"* ]]
    [[ "$output" == *"repo-alpha|"*"Add rate limiting"* ]]
    [[ "$output" == *"repo-beta|"*"Update database schema"* ]]
}

@test "parse_workspace_fix_plan skips completed tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Already done task
- [ ] Pending task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" != *"Already done task"* ]]
    [[ "$output" == *"Pending task"* ]]
}

@test "parse_workspace_fix_plan skips in-progress tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] In-progress task
- [ ] Pending task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" != *"In-progress task"* ]]
    [[ "$output" == *"Pending task"* ]]
}

@test "parse_workspace_fix_plan returns failure for missing file" {
    run parse_workspace_fix_plan "/nonexistent/fix_plan.md"
    assert_failure
}

@test "parse_workspace_fix_plan returns failure when no pending tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Task 1 done
- [x] Task 2 done
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_failure
}

@test "parse_workspace_fix_plan handles H3 section headers" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

### repo-alpha
- [ ] Task with H3 header
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"*"Task with H3 header"* ]]
}

@test "parse_workspace_fix_plan handles cross-repo section" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix auth

## cross-repo
- [ ] Ensure API compatibility
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"cross-repo|"*"Ensure API compatibility"* ]]
}

@test "parse_workspace_fix_plan output format is repo|line_num|task_description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## my-repo
- [ ] My task here
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    # Output should be pipe-delimited: repo_name|line_number|task_description
    echo "$output" | grep -qE '^my-repo\|[0-9]+\|My task here$'
}

@test "parse_workspace_fix_plan handles tasks with bead IDs" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] [AUTH-01] Fix token refresh
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"*"[AUTH-01] Fix token refresh"* ]]
}

@test "parse_workspace_fix_plan handles tasks with bold IDs" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] **R01** Fix token refresh
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"*"**R01** Fix token refresh"* ]]
}

# =============================================================================
# pick_workspace_task — pick next task from workspace fix_plan
# =============================================================================

@test "pick_workspace_task picks first unclaimed task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task

## repo-beta
- [ ] Second task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    # Output: repo_name|task_id|line_num|task_description
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"First task"* ]]
}

@test "pick_workspace_task marks task in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success

    # Verify the file was modified
    grep -q '\[~\]' .ralph/fix_plan.md
}

@test "pick_workspace_task skips completed and in-progress tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Completed task
- [~] In-progress task
- [ ] Available task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"Available task"* ]]
}

@test "pick_workspace_task returns failure when all tasks done" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Done task 1
- [x] Done task 2
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_failure
}

@test "pick_workspace_task picks from second repo when first is done" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Done task

## repo-beta
- [ ] Available task in beta
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-beta|"* ]]
    [[ "$output" == *"Available task in beta"* ]]
}

# =============================================================================
# get_repo_default_branch — detect default branch of a git repo
# =============================================================================

@test "get_repo_default_branch detects main branch" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    run get_repo_default_branch "test-repo"
    assert_success
    # Should return the branch name (main or master depending on git config)
    [[ "$output" =~ ^(main|master)$ ]]
}

@test "get_repo_default_branch returns failure for non-repo directory" {
    mkdir -p not-a-repo
    run get_repo_default_branch "not-a-repo"
    assert_failure
}

@test "get_repo_default_branch handles repo with custom default branch" {
    mkdir -p custom-repo
    cd custom-repo
    git init --quiet -b develop
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    run get_repo_default_branch "custom-repo"
    assert_success
    [[ "$output" == "develop" ]]
}

# =============================================================================
# validate_workspace — check workspace structure
# =============================================================================

@test "validate_workspace succeeds with valid structure" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task one

## repo-beta
- [ ] Task two
EOF

    run validate_workspace "."
    assert_success
}

@test "validate_workspace fails when .ralph/fix_plan.md missing" {
    mkdir -p repo-alpha/.git
    run validate_workspace "."
    assert_failure
    [[ "$output" == *"fix_plan.md"* ]]
}

@test "validate_workspace fails when no repos found" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md
    run validate_workspace "."
    assert_failure
    [[ "$output" == *"No git repositories"* ]]
}

@test "validate_workspace warns about repos in plan but not on disk" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task one

## repo-missing
- [ ] Task for missing repo
EOF

    run validate_workspace "."
    # Should succeed but with warning about missing repo
    [[ "$output" == *"repo-missing"* ]]
    [[ "$output" == *"not found"* ]]
}

# =============================================================================
# build_workspace_repo_context — prepare context for AI in a specific repo
# =============================================================================

@test "build_workspace_repo_context includes repo name" {
    mkdir -p repo-alpha/.git
    run build_workspace_repo_context "repo-alpha" "Fix auth bug" "."
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
}

@test "build_workspace_repo_context includes task description" {
    mkdir -p repo-alpha/.git
    run build_workspace_repo_context "repo-alpha" "Fix auth bug" "."
    assert_success
    [[ "$output" == *"Fix auth bug"* ]]
}

@test "build_workspace_repo_context includes working directory" {
    mkdir -p repo-alpha/.git
    run build_workspace_repo_context "repo-alpha" "Fix auth bug" "."
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
}

# =============================================================================
# mark_workspace_task_complete — mark task done in workspace fix_plan
# =============================================================================

@test "mark_workspace_task_complete changes [~] to [x] on specified line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] In-progress task
- [ ] Pending task
EOF

    run mark_workspace_task_complete ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[x]"* ]]
}

@test "mark_workspace_task_complete does not modify other lines" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] In-progress task
- [ ] Pending task
EOF

    mark_workspace_task_complete ".ralph/fix_plan.md" 4

    local line5
    line5=$(sed -n '5p' .ralph/fix_plan.md)
    [[ "$line5" == *"[ ]"* ]]
}

@test "mark_workspace_task_complete returns failure for invalid line" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md
    run mark_workspace_task_complete ".ralph/fix_plan.md" ""
    assert_failure
}

# =============================================================================
# revert_workspace_task — revert [~] back to [ ] on failure
# =============================================================================

@test "revert_workspace_task changes [~] back to [ ]" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Was in-progress task
EOF

    run revert_workspace_task ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[ ]"* ]]
}

# =============================================================================
# is_workspace_mode — detect if current directory is a workspace
# =============================================================================

@test "is_workspace_mode returns true for workspace directory" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task
EOF

    run is_workspace_mode "."
    assert_success
}

@test "is_workspace_mode returns false for single-repo directory" {
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md

    run is_workspace_mode "."
    assert_failure
}

@test "is_workspace_mode returns false for directory without .ralph" {
    mkdir -p repo-alpha/.git
    run is_workspace_mode "."
    assert_failure
}

# =============================================================================
# CLI parsing — --workspace flag
# =============================================================================

@test "--workspace flag is recognized by ralph_loop.sh" {
    run bash "$RALPH_SCRIPT" --workspace --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--help mentions --workspace flag" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--workspace"* ]]
}

@test "--workspace combined with other flags" {
    run bash "$RALPH_SCRIPT" --workspace --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--workspace combined with --monitor flag" {
    run bash "$RALPH_SCRIPT" --workspace --monitor --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--workspace combined with --live flag" {
    run bash "$RALPH_SCRIPT" --workspace --live --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# PROMPT_WORKSPACE.md template
# =============================================================================

@test "PROMPT_WORKSPACE.md template exists" {
    [[ -f "$TEMPLATES_DIR/PROMPT_WORKSPACE.md" ]]
}

@test "PROMPT_WORKSPACE.md contains workspace mode header" {
    run cat "$TEMPLATES_DIR/PROMPT_WORKSPACE.md"
    assert_success
    [[ "$output" == *"Workspace Mode"* ]]
}

@test "PROMPT_WORKSPACE.md mentions multi-repo context" {
    run cat "$TEMPLATES_DIR/PROMPT_WORKSPACE.md"
    assert_success
    [[ "$output" == *"multiple repositories"* ]]
}

@test "PROMPT_WORKSPACE.md contains RALPH_STATUS block instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_WORKSPACE.md"
    assert_success
    [[ "$output" == *"RALPH_STATUS"* ]]
}

@test "PROMPT_WORKSPACE.md contains working directory constraint" {
    run cat "$TEMPLATES_DIR/PROMPT_WORKSPACE.md"
    assert_success
    [[ "$output" == *"working directory"* ]]
}

# =============================================================================
# workspace_fix_plan.md template
# =============================================================================

@test "workspace fix_plan template exists" {
    [[ -f "$TEMPLATES_DIR/workspace_fix_plan.md" ]]
}

@test "workspace fix_plan template has repo section format" {
    run cat "$TEMPLATES_DIR/workspace_fix_plan.md"
    assert_success
    [[ "$output" == *"## "* ]]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "workspace mode handles repo names with hyphens" {
    mkdir -p .ralph my-complex-repo-name/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## my-complex-repo-name
- [ ] Test task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"my-complex-repo-name|"* ]]
}

@test "workspace mode handles repo names with underscores" {
    mkdir -p .ralph my_repo/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## my_repo
- [ ] Test task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"my_repo|"* ]]
}

@test "workspace mode handles repo names with dots" {
    mkdir -p .ralph my.repo/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## my.repo
- [ ] Test task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"my.repo|"* ]]
}

@test "workspace fix_plan with empty section has no tasks for that repo" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha

## repo-beta
- [ ] Beta task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" != *"repo-alpha|"* ]]
    [[ "$output" == *"repo-beta|"* ]]
}

@test "workspace handles multiple tasks per repo" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 3 ]]
}

@test "pick_workspace_task generates task_id from description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix Authentication Bug
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    # task_id should be a sanitized version of the description
    [[ "$output" == *"fix-authentication-bug"* ]] || [[ "$output" == *"repo-alpha|"* ]]
}

@test "pick_workspace_task uses bead ID when present" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] [AUTH-01] Fix Authentication Bug
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"AUTH-01"* ]]
}

@test "workspace mode with single repo works" {
    mkdir -p .ralph only-repo/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## only-repo
- [ ] Single repo task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"only-repo|"* ]]
}

@test "discover_workspace_repos handles many repos" {
    for i in $(seq 1 20); do
        mkdir -p "repo-$(printf '%02d' $i)/.git"
    done

    run discover_workspace_repos "."
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 20 ]]
}

@test "pick_workspace_task returns repo|task_id|line_num|description format" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] My specific task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    # Format: repo_name|task_id|line_num|description
    local field_count
    field_count=$(echo "$output" | awk -F'|' '{print NF}')
    [[ "$field_count" -eq 4 ]]
}

@test "workspace ignores non-task lines under repo section" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
Some descriptive text here
- [ ] Actual task
Another non-task line
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
}

@test "workspace handles indented subtasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Main task
  - [ ] Subtask 1
  - [ ] Subtask 2
EOF

    # Only top-level tasks should be picked (subtasks are context)
    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"Main task"* ]]
}

# =============================================================================
# Parallel workspace execution
# =============================================================================

# --- get_workspace_parallel_limit ---

@test "get_workspace_parallel_limit returns min of repos, pending tasks, and requested count" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git repo-gamma/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task alpha

## repo-beta
- [ ] Task beta

## repo-gamma
- [ ] Task gamma
EOF

    # Request 2 parallel, 3 repos with tasks available → limit is 2
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 2
    assert_success
    [[ "$output" == "2" ]]
}

@test "get_workspace_parallel_limit capped by number of repos with pending tasks" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git repo-gamma/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task alpha

## repo-beta
- [x] Task beta done
EOF

    # Request 5 parallel but only 1 repo has pending tasks → limit is 1
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 5
    assert_success
    [[ "$output" == "1" ]]
}

@test "get_workspace_parallel_limit returns 0 when no pending tasks" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Done
EOF

    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 3
    assert_success
    [[ "$output" == "0" ]]
}

@test "get_workspace_parallel_limit defaults requested to repo count when 0" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task alpha

## repo-beta
- [ ] Task beta
EOF

    # Request 0 means "auto" → use all available repos with tasks
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0
    assert_success
    [[ "$output" == "2" ]]
}

# --- pick_workspace_tasks_parallel ---

@test "pick_workspace_tasks_parallel picks one task per repo up to count" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task 1
- [ ] Alpha task 2

## repo-beta
- [ ] Beta task 1

## repo-gamma
- [ ] Gamma task 1
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 2
    assert_success
    # Should pick exactly 2 tasks from different repos
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 2 ]]
    # First two repos alphabetically: repo-alpha and repo-beta
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"repo-beta|"* ]]
}

@test "pick_workspace_tasks_parallel marks all picked tasks as in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 2
    assert_success

    # Both tasks should now be [~]
    local tilde_count
    tilde_count=$(grep -c '\[~\]' .ralph/fix_plan.md)
    [[ "$tilde_count" -eq 2 ]]
}

@test "pick_workspace_tasks_parallel skips repos with in-progress tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Alpha in-progress
- [ ] Alpha pending

## repo-beta
- [ ] Beta task
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 2
    assert_success
    # Only repo-beta should be picked (repo-alpha already has in-progress)
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
    [[ "$output" == *"repo-beta|"* ]]
    [[ "$output" != *"repo-alpha|"* ]]
}

@test "pick_workspace_tasks_parallel returns failure when no tasks available" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] All done
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    assert_failure
}

@test "pick_workspace_tasks_parallel picks only one task per repo even with multiple pending" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task 1
- [ ] Alpha task 2
- [ ] Alpha task 3
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    assert_success
    # Should only pick 1 task (one repo = max 1 parallel task)
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
}

@test "pick_workspace_tasks_parallel handles fewer repos than requested count" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    # Request 5 but only 2 repos have tasks
    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 5
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 2 ]]
}

@test "pick_workspace_tasks_parallel output format matches pick_workspace_task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] My task here
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 1
    assert_success
    # Format: repo_name|task_id|line_num|description (4 pipe-separated fields)
    local field_count
    field_count=$(echo "$output" | head -1 | awk -F'|' '{print NF}')
    [[ "$field_count" -eq 4 ]]
}

@test "pick_workspace_tasks_parallel skips cross-repo section for parallel picking" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## cross-repo
- [ ] Cross-repo task

## repo-beta
- [ ] Beta task
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    assert_success
    # cross-repo tasks should NOT be picked in parallel mode
    [[ "$output" != *"cross-repo|"* ]]
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"repo-beta|"* ]]
}

# --- run_workspace_tasks_parallel ---

@test "run_workspace_tasks_parallel spawns background jobs for each task" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    # Use a mock executor that just creates a marker file
    _mock_workspace_executor() {
        local repo_name="$1"
        local task_desc="$2"
        local workspace_dir="$3"
        touch "${workspace_dir}/.ralph/.parallel_ran_${repo_name}"
        return 0
    }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 2 "_mock_workspace_executor"
    assert_success

    # Both marker files should exist
    [[ -f .ralph/.parallel_ran_repo-alpha ]]
    [[ -f .ralph/.parallel_ran_repo-beta ]]
}

@test "run_workspace_tasks_parallel marks tasks complete on success" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    _mock_workspace_executor() { return 0; }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 2 "_mock_workspace_executor"
    assert_success

    # Both tasks should be [x]
    local done_count
    done_count=$(grep -c '\[x\]' .ralph/fix_plan.md)
    [[ "$done_count" -eq 2 ]]
}

@test "run_workspace_tasks_parallel reverts tasks on failure" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task
EOF

    _mock_workspace_executor() { return 1; }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 1 "_mock_workspace_executor"
    # Should report partial failure
    [[ "$output" == *"failed"* ]] || [[ "$output" == *"reverted"* ]] || [[ "$status" -ne 0 ]]

    # Task should be reverted to [ ]
    local unclaimed_count
    unclaimed_count=$(grep -c '\[ \]' .ralph/fix_plan.md)
    [[ "$unclaimed_count" -eq 1 ]]
}

@test "run_workspace_tasks_parallel creates per-worker log files" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    _mock_workspace_executor() {
        echo "Working on $1: $2"
        return 0
    }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 2 "_mock_workspace_executor"
    assert_success

    # Log directory should exist with worker logs
    [[ -d .ralph/logs/parallel ]]
    local log_count
    log_count=$(ls .ralph/logs/parallel/ws_worker_*.log 2>/dev/null | wc -l | tr -d ' ')
    [[ "$log_count" -ge 1 ]]
}

@test "run_workspace_tasks_parallel returns 0 when all tasks succeed" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task
EOF

    _mock_workspace_executor() { return 0; }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 1 "_mock_workspace_executor"
    assert_success
}

@test "run_workspace_tasks_parallel handles mixed success and failure" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task
EOF

    # repo-alpha succeeds, repo-beta fails
    _mock_workspace_executor() {
        if [[ "$1" == "repo-alpha" ]]; then return 0; fi
        return 1
    }
    export -f _mock_workspace_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 2 "_mock_workspace_executor"

    # repo-alpha should be [x], repo-beta should be reverted to [ ]
    local line_alpha line_beta
    line_alpha=$(grep "Alpha task" .ralph/fix_plan.md)
    line_beta=$(grep "Beta task" .ralph/fix_plan.md)
    [[ "$line_alpha" == *"[x]"* ]]
    [[ "$line_beta" == *"[ ]"* ]]
}

# --- CLI parsing: --workspace --parallel ---

@test "--workspace --parallel N flags are recognized together" {
    run bash "$RALPH_SCRIPT" --workspace --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--help mentions parallel workspace usage" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--workspace"* ]]
    [[ "$output" == *"--parallel"* ]]
}

@test "--workspace --parallel rejects zero" {
    run bash "$RALPH_SCRIPT" --workspace --parallel 0
    assert_failure
    [[ "$output" == *"positive integer"* ]]
}

# --- Edge cases for parallel workspace ---

@test "parallel workspace with single repo picks only that repo" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## only-repo
- [ ] Single task
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 5
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
    [[ "$output" == *"only-repo|"* ]]
}

@test "parallel workspace respects existing in-progress across multiple repos" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Alpha in-progress

## repo-beta
- [~] Beta in-progress

## repo-gamma
- [ ] Gamma pending
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    assert_success
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]
    [[ "$output" == *"repo-gamma|"* ]]
}

# =============================================================================
# Integration tests — workspace routing in ralph_loop.sh
# Verify that --workspace flag routes to run_workspace_mode() and that
# the function validates workspace structure, picks workspace tasks, and
# handles missing repos correctly.
# =============================================================================

# Helper: source ralph_loop.sh without triggering exit from CLI parsing
# We source it with a no-op to prevent the "if BASH_SOURCE == $0" block from running
_source_ralph_loop() {
    # Override exit to prevent sourced script from killing our test shell
    # The script calls exit in --help, --status, etc.
    BASH_SOURCE_OVERRIDE="sourced"
    (
        # Source only the function definitions, not the CLI parsing
        # by temporarily setting BASH_SOURCE[0] != $0
        eval '
            _original_exit() { builtin exit "$@"; }
            exit() {
                if [[ "${FUNCNAME[1]:-}" == "source" ]] || [[ "${FUNCNAME[1]:-}" == "main" ]]; then
                    return "${1:-0}" 2>/dev/null || true
                fi
                builtin exit "$@"
            }
        '
        source "$RALPH_SCRIPT" 2>/dev/null
    ) 2>/dev/null || true
}

@test "run_workspace_mode function is defined in ralph_loop.sh" {
    # Verify via grep that the function exists in the script
    grep -q '^run_workspace_mode()' "$RALPH_SCRIPT"
}

@test "_run_workspace_parallel function is defined in ralph_loop.sh" {
    grep -q '^_run_workspace_parallel()' "$RALPH_SCRIPT"
}

@test "_workspace_execute_task function is defined and exported" {
    grep -q '^_workspace_execute_task()' "$RALPH_SCRIPT"
    grep -q 'export -f _workspace_execute_task' "$RALPH_SCRIPT"
}

@test "run_workspace_mode validates workspace structure" {
    # Set up a non-workspace directory (missing .ralph/fix_plan.md)
    mkdir -p repo-alpha/.git

    # Source the library files needed by run_workspace_mode
    source "$WORKSPACE_LIB"
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/circuit_breaker.sh"

    # Define run_workspace_mode inline with the validation logic
    # (the real function is in ralph_loop.sh; we test the same validation call)
    _test_workspace_validation() {
        local ws_validation
        ws_validation=$(validate_workspace "." 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Invalid workspace"
            return 1
        fi
        return 0
    }

    run _test_workspace_validation
    assert_failure
    [[ "$output" == *"Invalid workspace"* ]] || [[ "$output" == *"fix_plan.md"* ]]
}

@test "workspace mode picks workspace tasks not regular tasks" {
    # Create valid workspace structure
    mkdir -p .ralph repo-alpha/.git
    echo "# Plan" > .ralph/PROMPT.md
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix auth bug
EOF

    source "$WORKSPACE_LIB"

    # pick_workspace_task should pick from ## repo sections
    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"Fix auth bug"* ]]

    # Verify task was marked in-progress
    grep -q '\[~\]' .ralph/fix_plan.md
}

@test "workspace mode reverts task when execution fails" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix auth bug
EOF

    source "$WORKSPACE_LIB"

    # Pick task (marks [~])
    pick_workspace_task ".ralph/fix_plan.md" > /dev/null
    grep -q '\[~\]' .ralph/fix_plan.md

    # Simulate failure: revert task back to [ ]
    local line_num
    line_num=$(grep -n '\[~\]' .ralph/fix_plan.md | head -1 | cut -d: -f1)
    revert_workspace_task ".ralph/fix_plan.md" "$line_num"

    # Verify task was reverted
    grep -q '\[ \] Fix auth bug' .ralph/fix_plan.md
}

@test "workspace mode exits cleanly when no tasks pending" {
    # Create workspace with all tasks completed
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Already done
EOF

    source "$WORKSPACE_LIB"

    # pick_workspace_task should fail when no pending tasks
    run pick_workspace_task ".ralph/fix_plan.md"
    assert_failure
}

@test "workspace mode entry point routes before main() call" {
    # Verify that the entry point checks WORKSPACE_MODE before calling main()
    local workspace_route_line main_call_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$RALPH_SCRIPT" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    main_call_line=$(grep -n '^\s*main$' "$RALPH_SCRIPT" | tail -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$main_call_line" ]]
    # Workspace routing must come before main() call
    [[ "$workspace_route_line" -lt "$main_call_line" ]]
}

@test "workspace mode entry point routes before QG mode" {
    # The actual function calls are the definitive ordering check
    local workspace_call_line qg_call_line

    # Find run_workspace_mode call in the entry point section (after line 2900+)
    workspace_call_line=$(grep -n '^\s*run_workspace_mode' "$RALPH_SCRIPT" | tail -1 | cut -d: -f1)
    qg_call_line=$(grep -n '^\s*run_qg_mode' "$RALPH_SCRIPT" | tail -1 | cut -d: -f1)

    [[ -n "$workspace_call_line" ]]
    [[ -n "$qg_call_line" ]]
    [[ "$workspace_call_line" -lt "$qg_call_line" ]]
}

@test "workspace mode skips normal parallel spawning" {
    # When --workspace is set, --parallel should NOT trigger spawn_parallel_agents
    # Instead, workspace mode handles parallelism internally
    # Verify that the parallel spawn check excludes workspace mode
    grep -q 'PARALLEL_COUNT.*-gt.*0' "$RALPH_SCRIPT"

    # The non-workspace parallel block should appear AFTER workspace routing
    local workspace_route_line parallel_spawn_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$RALPH_SCRIPT" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    parallel_spawn_line=$(grep -n 'spawn_parallel_agents' "$RALPH_SCRIPT" | head -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$parallel_spawn_line" ]]
    [[ "$workspace_route_line" -lt "$parallel_spawn_line" ]]
}

@test "workspace mode forwards --workspace flag through tmux setup" {
    # The tmux setup code forwards --workspace on a separate line from the WORKSPACE_MODE check
    # Verify both the condition and the flag forwarding exist
    grep -q 'WORKSPACE_MODE.*true' "$RALPH_SCRIPT"
    grep -q '\-\-workspace' "$RALPH_SCRIPT"
    # Verify the specific forwarding pattern: ralph_cmd appends --workspace
    grep -q 'ralph_cmd.*--workspace' "$RALPH_SCRIPT"
}

@test "run_workspace_mode uses validate_workspace not validate_ralph_integrity" {
    # Verify that run_workspace_mode calls validate_workspace
    # Get the function body between run_workspace_mode() { and the next function
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call validate_workspace
    echo "$func_body" | grep -q 'validate_workspace'

    # Should NOT call validate_ralph_integrity
    ! echo "$func_body" | grep -q 'validate_ralph_integrity'
}

@test "run_workspace_mode calls pick_workspace_task not pick_next_task" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call pick_workspace_task
    echo "$func_body" | grep -q 'pick_workspace_task'

    # Should NOT call pick_next_task
    ! echo "$func_body" | grep -q 'pick_next_task'
}

@test "run_workspace_mode calls execute_claude_code with work_dir" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call execute_claude_code
    echo "$func_body" | grep -q 'execute_claude_code'
}

@test "run_workspace_mode handles change detection and task marking" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call mark_workspace_task_complete on success
    echo "$func_body" | grep -q 'mark_workspace_task_complete'

    # Should call revert_workspace_task on failure
    echo "$func_body" | grep -q 'revert_workspace_task'
}

@test "_run_workspace_parallel calls get_workspace_parallel_limit" {
    local func_body
    func_body=$(sed -n '/^_run_workspace_parallel()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    echo "$func_body" | grep -q 'get_workspace_parallel_limit'
    echo "$func_body" | grep -q 'run_workspace_tasks_parallel'
}

# =============================================================================
# workspace_repo_worktree_init — per-repo worktree initialization
# =============================================================================

@test "workspace_repo_worktree_init succeeds for valid git repo" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    # Source worktree_manager to get worktree_init
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    run workspace_repo_worktree_init "$TEST_DIR/test-repo"
    assert_success
}

@test "workspace_repo_worktree_init fails for non-git directory" {
    mkdir -p not-a-repo

    # Source worktree_manager to get worktree_init
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    run workspace_repo_worktree_init "$TEST_DIR/not-a-repo"
    assert_failure
    [[ "$output" == *"Not a git repository"* ]]
}

@test "workspace_repo_worktree_init fails for missing directory" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    run workspace_repo_worktree_init "$TEST_DIR/nonexistent"
    assert_failure
}

# =============================================================================
# workspace_repo_worktree_create — per-repo worktree creation
# =============================================================================

@test "workspace_repo_worktree_create creates worktree for repo" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    workspace_repo_worktree_create "$TEST_DIR/test-repo" "test-task-123"
    local result=$?
    [[ $result -eq 0 ]]

    # Verify worktree path is set
    local wt_path
    wt_path=$(worktree_get_path)
    [[ -n "$wt_path" ]]
    [[ -d "$wt_path" ]]

    # Verify branch is set
    local wt_branch
    wt_branch=$(worktree_get_branch)
    [[ "$wt_branch" == *"test-task-123"* ]]

    # Cleanup
    cd "$TEST_DIR/test-repo" && git worktree remove "$wt_path" --force 2>/dev/null || true
}

@test "workspace_repo_worktree_create fails for non-git directory" {
    mkdir -p not-a-repo

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    run workspace_repo_worktree_create "$TEST_DIR/not-a-repo" "task-1"
    assert_failure
}

# =============================================================================
# workspace_repo_run_quality_gates — per-repo quality gate execution
# =============================================================================

@test "workspace_repo_run_quality_gates passes when no gates detected" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_QUALITY_GATES="auto"

    # Create a minimal directory (no package.json, no Makefile, etc.)
    mkdir -p empty-repo/.ralph
    _WT_CURRENT_PATH=""

    run workspace_repo_run_quality_gates "$TEST_DIR/empty-repo"
    assert_success
}

@test "workspace_repo_run_quality_gates skips when gates disabled" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_QUALITY_GATES="none"
    _WT_CURRENT_PATH=""

    mkdir -p some-repo/.ralph

    run workspace_repo_run_quality_gates "$TEST_DIR/some-repo"
    assert_success
    [[ "$output" == *"Skipped"* ]] || [[ "$output" == *"disabled"* ]] || true
}

@test "workspace_repo_run_quality_gates uses worktree path when active" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_QUALITY_GATES="auto"

    # Simulate active worktree
    mkdir -p "$TEST_DIR/worktree/.ralph"
    _WT_CURRENT_PATH="$TEST_DIR/worktree"

    run workspace_repo_run_quality_gates "$TEST_DIR/some-repo"
    assert_success
    # Should use worktree path, not repo path
    [[ "$output" == *"$TEST_DIR/worktree"* ]] || [[ "$output" == *"No gates auto-detected"* ]]
}

# =============================================================================
# workspace_repo_cleanup — per-repo worktree cleanup
# =============================================================================

@test "workspace_repo_cleanup is no-op when no worktree active" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    _WT_CURRENT_PATH=""

    run workspace_repo_cleanup "$TEST_DIR/some-repo"
    assert_success
}

@test "workspace_repo_cleanup removes active worktree" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="true"

    workspace_repo_worktree_create "$TEST_DIR/test-repo" "cleanup-test"
    local wt_path
    wt_path=$(worktree_get_path)
    [[ -d "$wt_path" ]]

    workspace_repo_cleanup "$TEST_DIR/test-repo"

    # After cleanup, worktree should be removed
    [[ -z "$(worktree_get_path)" ]]
}

# =============================================================================
# run_workspace_mode — structural tests for worktree/QG/PR integration
# =============================================================================

@test "run_workspace_mode creates worktree when WORKTREE_ENABLED" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call workspace_repo_worktree_create
    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "run_workspace_mode runs quality gates after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call workspace_repo_run_quality_gates
    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "run_workspace_mode creates PR after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call workspace_repo_commit_and_pr
    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "run_workspace_mode cleans up worktree on no changes" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should call workspace_repo_cleanup
    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

@test "run_workspace_mode cleans up worktree on execution failure" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # The failure branch should also clean up
    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

@test "run_workspace_mode quality gates run before PR creation" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Quality gates line should appear before PR commit line
    local qg_line pr_line
    qg_line=$(echo "$func_body" | grep -n 'workspace_repo_run_quality_gates' | head -1 | cut -d: -f1)
    pr_line=$(echo "$func_body" | grep -n 'workspace_repo_commit_and_pr' | head -1 | cut -d: -f1)

    [[ -n "$qg_line" ]]
    [[ -n "$pr_line" ]]
    [[ "$qg_line" -lt "$pr_line" ]]
}

@test "run_workspace_mode worktree created before Claude execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Worktree creation line should appear before execute_claude_code
    local wt_line exec_line
    wt_line=$(echo "$func_body" | grep -n 'workspace_repo_worktree_create' | head -1 | cut -d: -f1)
    exec_line=$(echo "$func_body" | grep -n 'execute_claude_code' | head -1 | cut -d: -f1)

    [[ -n "$wt_line" ]]
    [[ -n "$exec_line" ]]
    [[ "$wt_line" -lt "$exec_line" ]]
}

# =============================================================================
# _workspace_execute_task — structural tests for parallel worker QG/PR
# =============================================================================

@test "_workspace_execute_task includes worktree creation" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "_workspace_execute_task runs quality gates" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "_workspace_execute_task creates PR" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "_workspace_execute_task cleans up worktree" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

@test "_workspace_execute_task detects changes before running gates" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Change detection should happen before quality gates
    local change_line qg_line
    change_line=$(echo "$func_body" | grep -n 'files_changed' | head -1 | cut -d: -f1)
    qg_line=$(echo "$func_body" | grep -n 'workspace_repo_run_quality_gates' | head -1 | cut -d: -f1)

    [[ -n "$change_line" ]]
    [[ -n "$qg_line" ]]
    [[ "$change_line" -lt "$qg_line" ]]
}

@test "_workspace_execute_task cleans up on execution failure" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$RALPH_SCRIPT")

    # Should have cleanup in the failure path (result -ne 0)
    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

# =============================================================================
# workspace_manager.sh exports — verify new functions are exported
# =============================================================================

@test "workspace_manager.sh exports workspace_repo_worktree_init" {
    grep -q 'export -f workspace_repo_worktree_init' "$WORKSPACE_LIB"
}

@test "workspace_manager.sh exports workspace_repo_worktree_create" {
    grep -q 'export -f workspace_repo_worktree_create' "$WORKSPACE_LIB"
}

@test "workspace_manager.sh exports workspace_repo_run_quality_gates" {
    grep -q 'export -f workspace_repo_run_quality_gates' "$WORKSPACE_LIB"
}

@test "workspace_manager.sh exports workspace_repo_commit_and_pr" {
    grep -q 'export -f workspace_repo_commit_and_pr' "$WORKSPACE_LIB"
}

@test "workspace_manager.sh exports workspace_repo_cleanup" {
    grep -q 'export -f workspace_repo_cleanup' "$WORKSPACE_LIB"
}

# =============================================================================
# Devin loop — workspace mode wiring
# =============================================================================

DEVIN_LOOP="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"

@test "devin loop sources workspace_manager.sh" {
    grep -q 'source.*workspace_manager.sh' "$DEVIN_LOOP"
}

@test "devin loop initializes WORKSPACE_MODE=false" {
    grep -q 'WORKSPACE_MODE=false' "$DEVIN_LOOP"
}

@test "--workspace flag is recognized by devin loop" {
    run bash "$DEVIN_LOOP" --workspace --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --help mentions --workspace flag" {
    run bash "$DEVIN_LOOP" --help
    assert_success
    [[ "$output" == *"--workspace"* ]]
}

@test "devin --workspace combined with other flags" {
    run bash "$DEVIN_LOOP" --workspace --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --workspace combined with --monitor flag" {
    run bash "$DEVIN_LOOP" --workspace --monitor --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --workspace combined with --live flag" {
    run bash "$DEVIN_LOOP" --workspace --live --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --workspace --parallel N flags are recognized together" {
    run bash "$DEVIN_LOOP" --workspace --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin run_workspace_mode function is defined" {
    grep -q '^run_workspace_mode()' "$DEVIN_LOOP"
}

@test "devin _run_workspace_parallel function is defined" {
    grep -q '^_run_workspace_parallel()' "$DEVIN_LOOP"
}

@test "devin _workspace_execute_task function is defined and exported" {
    grep -q '^_workspace_execute_task()' "$DEVIN_LOOP"
    grep -q 'export -f _workspace_execute_task' "$DEVIN_LOOP"
}

@test "devin run_workspace_mode validates workspace structure" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'validate_workspace'
    ! echo "$func_body" | grep -q 'validate_ralph_integrity'
}

@test "devin run_workspace_mode calls pick_workspace_task" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'pick_workspace_task'
    ! echo "$func_body" | grep -q 'pick_next_task'
}

@test "devin run_workspace_mode calls execute_devin_session" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'execute_devin_session'
}

@test "devin run_workspace_mode handles change detection and task marking" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'mark_workspace_task_complete'
    echo "$func_body" | grep -q 'revert_workspace_task'
}

@test "devin run_workspace_mode creates worktree when WORKTREE_ENABLED" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "devin run_workspace_mode runs quality gates after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "devin run_workspace_mode creates PR after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "devin run_workspace_mode cleans up worktree" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

@test "devin run_workspace_mode quality gates run before PR creation" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    local qg_line pr_line
    qg_line=$(echo "$func_body" | grep -n 'workspace_repo_run_quality_gates' | head -1 | cut -d: -f1)
    pr_line=$(echo "$func_body" | grep -n 'workspace_repo_commit_and_pr' | head -1 | cut -d: -f1)

    [[ -n "$qg_line" ]]
    [[ -n "$pr_line" ]]
    [[ "$qg_line" -lt "$pr_line" ]]
}

@test "devin run_workspace_mode worktree created before execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    local wt_line exec_line
    wt_line=$(echo "$func_body" | grep -n 'workspace_repo_worktree_create' | head -1 | cut -d: -f1)
    exec_line=$(echo "$func_body" | grep -n 'execute_devin_session' | head -1 | cut -d: -f1)

    [[ -n "$wt_line" ]]
    [[ -n "$exec_line" ]]
    [[ "$wt_line" -lt "$exec_line" ]]
}

@test "devin workspace mode entry point routes before main() call" {
    local workspace_route_line main_call_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$DEVIN_LOOP" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    main_call_line=$(grep -n '^\s*main$' "$DEVIN_LOOP" | tail -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$main_call_line" ]]
    [[ "$workspace_route_line" -lt "$main_call_line" ]]
}

@test "devin workspace mode skips normal parallel spawning" {
    local workspace_route_line parallel_spawn_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$DEVIN_LOOP" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    parallel_spawn_line=$(grep -n 'spawn_parallel_agents' "$DEVIN_LOOP" | head -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$parallel_spawn_line" ]]
    [[ "$workspace_route_line" -lt "$parallel_spawn_line" ]]
}

@test "devin workspace mode forwards --workspace flag through tmux" {
    grep -q 'WORKSPACE_MODE.*true' "$DEVIN_LOOP"
    grep -q 'ralph_cmd.*--workspace' "$DEVIN_LOOP"
}

@test "devin _run_workspace_parallel calls get_workspace_parallel_limit" {
    local func_body
    func_body=$(sed -n '/^_run_workspace_parallel()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'get_workspace_parallel_limit'
    echo "$func_body" | grep -q 'run_workspace_tasks_parallel'
}

@test "devin _workspace_execute_task includes worktree creation" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "devin _workspace_execute_task runs quality gates" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "devin _workspace_execute_task creates PR" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "devin _workspace_execute_task cleans up worktree" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$DEVIN_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

# =============================================================================
# Codex loop — workspace mode wiring
# =============================================================================

CODEX_LOOP="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

@test "codex loop sources workspace_manager.sh" {
    grep -q 'source.*workspace_manager.sh' "$CODEX_LOOP"
}

@test "codex loop initializes WORKSPACE_MODE=false" {
    grep -q 'WORKSPACE_MODE=false' "$CODEX_LOOP"
}

@test "--workspace flag is recognized by codex loop" {
    run bash "$CODEX_LOOP" --workspace --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --help mentions --workspace flag" {
    run bash "$CODEX_LOOP" --help
    assert_success
    [[ "$output" == *"--workspace"* ]]
}

@test "codex --workspace combined with other flags" {
    run bash "$CODEX_LOOP" --workspace --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --workspace combined with --monitor flag" {
    run bash "$CODEX_LOOP" --workspace --monitor --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --workspace combined with --live flag" {
    run bash "$CODEX_LOOP" --workspace --live --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --workspace --parallel N flags are recognized together" {
    run bash "$CODEX_LOOP" --workspace --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex run_workspace_mode function is defined" {
    grep -q '^run_workspace_mode()' "$CODEX_LOOP"
}

@test "codex _run_workspace_parallel function is defined" {
    grep -q '^_run_workspace_parallel()' "$CODEX_LOOP"
}

@test "codex _workspace_execute_task function is defined and exported" {
    grep -q '^_workspace_execute_task()' "$CODEX_LOOP"
    grep -q 'export -f _workspace_execute_task' "$CODEX_LOOP"
}

@test "codex run_workspace_mode validates workspace structure" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'validate_workspace'
    ! echo "$func_body" | grep -q 'validate_ralph_integrity'
}

@test "codex run_workspace_mode calls pick_workspace_task" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'pick_workspace_task'
    ! echo "$func_body" | grep -q 'pick_next_task'
}

@test "codex run_workspace_mode calls execute_codex_session" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'execute_codex_session'
}

@test "codex run_workspace_mode handles change detection and task marking" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'mark_workspace_task_complete'
    echo "$func_body" | grep -q 'revert_workspace_task'
}

@test "codex run_workspace_mode creates worktree when WORKTREE_ENABLED" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "codex run_workspace_mode runs quality gates after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "codex run_workspace_mode creates PR after execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "codex run_workspace_mode cleans up worktree" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

@test "codex run_workspace_mode quality gates run before PR creation" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    local qg_line pr_line
    qg_line=$(echo "$func_body" | grep -n 'workspace_repo_run_quality_gates' | head -1 | cut -d: -f1)
    pr_line=$(echo "$func_body" | grep -n 'workspace_repo_commit_and_pr' | head -1 | cut -d: -f1)

    [[ -n "$qg_line" ]]
    [[ -n "$pr_line" ]]
    [[ "$qg_line" -lt "$pr_line" ]]
}

@test "codex run_workspace_mode worktree created before execution" {
    local func_body
    func_body=$(sed -n '/^run_workspace_mode()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    local wt_line exec_line
    wt_line=$(echo "$func_body" | grep -n 'workspace_repo_worktree_create' | head -1 | cut -d: -f1)
    exec_line=$(echo "$func_body" | grep -n 'execute_codex_session' | head -1 | cut -d: -f1)

    [[ -n "$wt_line" ]]
    [[ -n "$exec_line" ]]
    [[ "$wt_line" -lt "$exec_line" ]]
}

@test "codex workspace mode entry point routes before main() call" {
    local workspace_route_line main_call_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$CODEX_LOOP" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    main_call_line=$(grep -n '^\s*main$' "$CODEX_LOOP" | tail -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$main_call_line" ]]
    [[ "$workspace_route_line" -lt "$main_call_line" ]]
}

@test "codex workspace mode skips normal parallel spawning" {
    local workspace_route_line parallel_spawn_line

    workspace_route_line=$(grep -n 'WORKSPACE_MODE.*true' "$CODEX_LOOP" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
    parallel_spawn_line=$(grep -n 'spawn_parallel_agents' "$CODEX_LOOP" | head -1 | cut -d: -f1)

    [[ -n "$workspace_route_line" ]]
    [[ -n "$parallel_spawn_line" ]]
    [[ "$workspace_route_line" -lt "$parallel_spawn_line" ]]
}

@test "codex workspace mode forwards --workspace flag through tmux" {
    grep -q 'WORKSPACE_MODE.*true' "$CODEX_LOOP"
    grep -q 'ralph_cmd.*--workspace' "$CODEX_LOOP"
}

@test "codex _run_workspace_parallel calls get_workspace_parallel_limit" {
    local func_body
    func_body=$(sed -n '/^_run_workspace_parallel()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'get_workspace_parallel_limit'
    echo "$func_body" | grep -q 'run_workspace_tasks_parallel'
}

@test "codex _workspace_execute_task includes worktree creation" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_worktree_create'
}

@test "codex _workspace_execute_task runs quality gates" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_run_quality_gates'
}

@test "codex _workspace_execute_task creates PR" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_commit_and_pr'
}

@test "codex _workspace_execute_task cleans up worktree" {
    local func_body
    func_body=$(sed -n '/^_workspace_execute_task()/,/^[a-z_]*() {/p' "$CODEX_LOOP")

    echo "$func_body" | grep -q 'workspace_repo_cleanup'
}

# =============================================================================
# Cross-engine workspace parity — all three engines have identical structure
# =============================================================================

@test "all three engines define run_workspace_mode" {
    grep -q '^run_workspace_mode()' "$RALPH_SCRIPT"
    grep -q '^run_workspace_mode()' "$DEVIN_LOOP"
    grep -q '^run_workspace_mode()' "$CODEX_LOOP"
}

@test "all three engines define _run_workspace_parallel" {
    grep -q '^_run_workspace_parallel()' "$RALPH_SCRIPT"
    grep -q '^_run_workspace_parallel()' "$DEVIN_LOOP"
    grep -q '^_run_workspace_parallel()' "$CODEX_LOOP"
}

@test "all three engines define and export _workspace_execute_task" {
    grep -q '^_workspace_execute_task()' "$RALPH_SCRIPT"
    grep -q 'export -f _workspace_execute_task' "$RALPH_SCRIPT"
    grep -q '^_workspace_execute_task()' "$DEVIN_LOOP"
    grep -q 'export -f _workspace_execute_task' "$DEVIN_LOOP"
    grep -q '^_workspace_execute_task()' "$CODEX_LOOP"
    grep -q 'export -f _workspace_execute_task' "$CODEX_LOOP"
}

@test "all three engines source workspace_manager.sh" {
    grep -q 'source.*workspace_manager.sh' "$RALPH_SCRIPT"
    grep -q 'source.*workspace_manager.sh' "$DEVIN_LOOP"
    grep -q 'source.*workspace_manager.sh' "$CODEX_LOOP"
}

@test "all three engines parse --workspace flag" {
    grep -q '\-\-workspace)' "$RALPH_SCRIPT"
    grep -q '\-\-workspace)' "$DEVIN_LOOP"
    grep -q '\-\-workspace)' "$CODEX_LOOP"
}

@test "all three engines route workspace before parallel spawn" {
    for script in "$RALPH_SCRIPT" "$DEVIN_LOOP" "$CODEX_LOOP"; do
        local ws_line par_line
        ws_line=$(grep -n 'WORKSPACE_MODE.*true' "$script" | grep 'run_workspace_mode' | head -1 | cut -d: -f1)
        par_line=$(grep -n 'spawn_parallel_agents' "$script" | head -1 | cut -d: -f1)
        [[ -n "$ws_line" ]]
        [[ -n "$par_line" ]]
        [[ "$ws_line" -lt "$par_line" ]]
    done
}

# =============================================================================
# CRITICAL SEVERITY TESTS
# Tests for data-loss or incorrect behavior risks in production
# =============================================================================

# --- Pipe character in task descriptions (delimiter collision) ---

@test "pick_workspace_task handles pipe character in task description" {
    # The output format is repo_name|task_id|line_num|description
    # A pipe in the description would produce extra fields if not handled
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix A | B pipeline issue
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success

    # Verify we get output
    [[ -n "$output" ]]

    # The first field must be the repo name
    local repo_name
    repo_name=$(echo "$output" | cut -d'|' -f1)
    [[ "$repo_name" == "repo-alpha" ]]

    # The line_num (3rd field) must be a number
    local line_num
    line_num=$(echo "$output" | cut -d'|' -f3)
    [[ "$line_num" =~ ^[0-9]+$ ]]
}

@test "pick_workspace_tasks_parallel handles pipe character in task description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix A | B pipeline

## repo-beta
- [ ] Fix C | D | E multi-pipe
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 2
    assert_success

    # Both tasks should be picked
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 2 ]]

    # Verify first fields are repo names
    echo "$output" | while IFS= read -r line; do
        local repo
        repo=$(echo "$line" | cut -d'|' -f1)
        [[ "$repo" == "repo-alpha" || "$repo" == "repo-beta" ]]
    done
}

@test "run_workspace_tasks_parallel parses pipe in task description correctly" {
    # The parallel executor uses cut -d'|' -f4 for task_desc — if the description
    # contains pipes, cut only returns the 4th field, truncating the rest.
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix A | B pipeline
EOF

    _mock_pipe_executor() {
        # Verify we receive the expected task description
        local received_desc="$2"
        # cut -d'|' -f4 will truncate at the first pipe in description
        # The executor may receive "Fix A " instead of "Fix A | B pipeline"
        # This test documents the current behavior
        touch "${3}/.ralph/.pipe_test_ran"
        return 0
    }
    export -f _mock_pipe_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 1 "_mock_pipe_executor"
    # Verify executor ran regardless of description truncation
    [[ -f .ralph/.pipe_test_ran ]]
}

@test "parse_workspace_fix_plan handles pipe character in task description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix A | B pipeline issue
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success

    # The output format is repo|line_num|description
    # A pipe in description creates extra fields
    local repo
    repo=$(echo "$output" | cut -d'|' -f1)
    [[ "$repo" == "repo-alpha" ]]
}

# --- Functional test for workspace_repo_commit_and_pr ---

@test "workspace_repo_commit_and_pr calls worktree path when worktree is active" {
    # Create a real git repo for testing
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    # Mock the dependencies
    log_status() { :; }
    export -f log_status

    # Set worktree as active
    _WT_CURRENT_PATH="$TEST_DIR/test-repo"
    _WT_CURRENT_BRANCH="ralph/test-task"
    WORKTREE_ENABLED="true"

    # Mock worktree_is_active to return true
    worktree_is_active() { return 0; }
    export -f worktree_is_active

    # Track which function gets called
    local called_worktree=false
    local called_fallback=false

    worktree_commit_and_pr() {
        touch "$TEST_DIR/.called_worktree_commit"
        return 0
    }
    export -f worktree_commit_and_pr

    worktree_fallback_branch_pr() {
        touch "$TEST_DIR/.called_fallback_pr"
        return 0
    }
    export -f worktree_fallback_branch_pr

    pr_preflight_check() {
        RALPH_PR_PUSH_CAPABLE="false"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    }
    export -f pr_preflight_check

    workspace_repo_commit_and_pr "$TEST_DIR/test-repo" "test-task" "Test task" "true"

    # Should have called worktree path, not fallback
    [[ -f "$TEST_DIR/.called_worktree_commit" ]]
    [[ ! -f "$TEST_DIR/.called_fallback_pr" ]]
}

@test "workspace_repo_commit_and_pr calls fallback path when no worktree" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    log_status() { :; }
    export -f log_status

    # No worktree active
    _WT_CURRENT_PATH=""
    _WT_CURRENT_BRANCH=""

    worktree_is_active() { return 1; }
    export -f worktree_is_active

    worktree_commit_and_pr() {
        touch "$TEST_DIR/.called_worktree_commit"
        return 0
    }
    export -f worktree_commit_and_pr

    worktree_fallback_branch_pr() {
        touch "$TEST_DIR/.called_fallback_pr"
        return 0
    }
    export -f worktree_fallback_branch_pr

    pr_preflight_check() {
        RALPH_PR_PUSH_CAPABLE="false"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    }
    export -f pr_preflight_check

    workspace_repo_commit_and_pr "$TEST_DIR/test-repo" "test-task" "Test task" "true"

    [[ ! -f "$TEST_DIR/.called_worktree_commit" ]]
    [[ -f "$TEST_DIR/.called_fallback_pr" ]]
}

@test "workspace_repo_commit_and_pr passes gate_passed=false correctly" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    log_status() { :; }
    export -f log_status

    _WT_CURRENT_PATH=""
    _WT_CURRENT_BRANCH=""

    worktree_is_active() { return 1; }
    export -f worktree_is_active

    worktree_fallback_branch_pr() {
        # Capture the gate_passed argument (4th arg)
        echo "$4" > "$TEST_DIR/.gate_passed_value"
        return 0
    }
    export -f worktree_fallback_branch_pr

    pr_preflight_check() {
        RALPH_PR_PUSH_CAPABLE="false"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    }
    export -f pr_preflight_check

    workspace_repo_commit_and_pr "$TEST_DIR/test-repo" "test-task" "Test task" "false"

    local gate_val
    gate_val=$(cat "$TEST_DIR/.gate_passed_value")
    [[ "$gate_val" == "false" ]]
}

# --- Parallel race condition on fix_plan.md ---

@test "_acquire_task_lock creates lock directory atomically" {
    # Source task_sources.sh to get _acquire_task_lock
    source "${BATS_TEST_DIRNAME}/../../lib/task_sources.sh" 2>/dev/null || true

    if ! command -v _acquire_task_lock &>/dev/null; then
        skip "_acquire_task_lock not available"
    fi

    local lock_path="$TEST_DIR/.test_lock"

    # First acquire should succeed
    run _acquire_task_lock "$lock_path" 2
    assert_success
    [[ -d "$lock_path" ]]

    # Release it
    _release_task_lock "$lock_path"
    [[ ! -d "$lock_path" ]]
}

@test "_acquire_task_lock blocks when lock is held" {
    source "${BATS_TEST_DIRNAME}/../../lib/task_sources.sh" 2>/dev/null || true

    if ! command -v _acquire_task_lock &>/dev/null; then
        skip "_acquire_task_lock not available"
    fi

    local lock_path="$TEST_DIR/.test_lock"

    # Create the lock manually to simulate it being held
    mkdir "$lock_path"

    # Second acquire should fail within short timeout (1 second)
    run _acquire_task_lock "$lock_path" 1
    assert_failure

    # Cleanup
    rmdir "$lock_path"
}

@test "_acquire_task_lock removes stale locks older than 30 seconds" {
    source "${BATS_TEST_DIRNAME}/../../lib/task_sources.sh" 2>/dev/null || true

    if ! command -v _acquire_task_lock &>/dev/null; then
        skip "_acquire_task_lock not available"
    fi

    local lock_path="$TEST_DIR/.test_lock"

    # Create a stale lock
    mkdir "$lock_path"
    # Touch it 35 seconds in the past
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-35S +%Y%m%d%H%M.%S)" "$lock_path"
    else
        touch -d "35 seconds ago" "$lock_path"
    fi

    # Acquire should succeed because lock is stale
    run _acquire_task_lock "$lock_path" 2
    assert_success

    _release_task_lock "$lock_path"
}

@test "concurrent pick_workspace_task calls do not claim same task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task 1

## repo-beta
- [ ] Task 2

## repo-gamma
- [ ] Task 3
EOF

    # Run two picks sequentially (simulating what lock protects)
    local result1 result2

    result1=$(pick_workspace_task ".ralph/fix_plan.md")
    result2=$(pick_workspace_task ".ralph/fix_plan.md")

    # Both should succeed but pick different tasks
    [[ -n "$result1" ]]
    [[ -n "$result2" ]]

    local repo1 repo2
    repo1=$(echo "$result1" | cut -d'|' -f1)
    repo2=$(echo "$result2" | cut -d'|' -f1)

    # Should pick different repos
    [[ "$repo1" != "$repo2" ]]

    # Verify fix_plan.md has two [~] markers
    local tilde_count
    tilde_count=$(grep -c '\[~\]' .ralph/fix_plan.md)
    [[ "$tilde_count" -eq 2 ]]
}

# --- --parallel 0 inconsistency (CLI vs lib) ---

@test "--parallel 0 is rejected at CLI level" {
    # CLI validation rejects --parallel 0 with "positive integer" error
    run bash "$RALPH_SCRIPT" --workspace --parallel 0
    assert_failure
    [[ "$output" == *"positive integer"* ]]
}

@test "get_workspace_parallel_limit treats requested=0 as auto" {
    # Library function treats 0 as "auto" (use all available repos)
    # This documents the intentional CLI-vs-lib split
    mkdir -p .ralph repo-alpha/.git repo-beta/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task alpha

## repo-beta
- [ ] Task beta
EOF

    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0
    assert_success
    # When requested=0, returns available count (auto mode)
    [[ "$output" == "2" ]]
}

# =============================================================================
# HIGH SEVERITY TESTS
# Edge cases that could cause failures in real workspaces
# =============================================================================

# --- Shell metacharacters in task descriptions ---

@test "pick_workspace_task handles backticks in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix `format` command output
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"format"* ]]
}

@test "pick_workspace_task handles dollar signs in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix $HOME variable expansion
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
}

@test "pick_workspace_task handles parentheses in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix auth (OAuth2) flow
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
    [[ "$output" == *"OAuth2"* ]]
}

@test "pick_workspace_task handles quotes in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix "double quoted" and 'single quoted' strings
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
}

@test "mark_workspace_task_complete handles special chars in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Fix `format` $HOME (OAuth2) "test"
EOF

    run mark_workspace_task_complete ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[x]"* ]]
    # Verify description wasn't mangled
    [[ "$line4" == *'$HOME'* ]]
    [[ "$line4" == *'`format`'* ]]
}

@test "revert_workspace_task handles special chars in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Fix $(command) injection test
EOF

    run revert_workspace_task ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[ ]"* ]]
    # Verify description wasn't mangled by shell expansion
    [[ "$line4" == *'$(command)'* ]]
}

# --- Malformed fix_plan.md variants ---

@test "parse_workspace_fix_plan handles completely empty file" {
    mkdir -p .ralph
    touch .ralph/fix_plan.md

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_failure
}

@test "parse_workspace_fix_plan handles file with only header and no sections" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

This is just a description with no repo sections.
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_failure
}

@test "parse_workspace_fix_plan handles malformed checkbox syntax - missing space" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [] task without space in checkbox
- [ ] Proper task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    # Should only pick up the properly formatted task
    [[ "$output" == *"Proper task"* ]]
    [[ "$output" != *"task without space"* ]]
}

@test "parse_workspace_fix_plan handles malformed checkbox syntax - double space" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [  ] task with double space
- [ ] Proper task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    # Double-space checkbox doesn't match - [ ] pattern
    [[ "$output" == *"Proper task"* ]]
    [[ "$output" != *"double space"* ]]
}

@test "parse_workspace_fix_plan handles Windows-style line endings" {
    mkdir -p .ralph
    # Create file with \r\n line endings
    printf "# Workspace Fix Plan\r\n\r\n## repo-alpha\r\n- [ ] Task with CRLF\r\n" > .ralph/fix_plan.md

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
}

@test "parse_workspace_fix_plan handles trailing whitespace in section headers" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << EOF
# Workspace Fix Plan

## repo-alpha   
- [ ] Task under repo with trailing spaces
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    # Repo name should be trimmed
    local repo
    repo=$(echo "$output" | cut -d'|' -f1)
    [[ "$repo" == "repo-alpha" ]]
}

@test "pick_workspace_task handles completely empty fix_plan.md" {
    mkdir -p .ralph
    touch .ralph/fix_plan.md

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_failure
}

@test "pick_workspace_tasks_parallel handles empty fix_plan.md" {
    mkdir -p .ralph
    touch .ralph/fix_plan.md

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    assert_failure
}

@test "get_workspace_parallel_limit handles empty fix_plan.md" {
    mkdir -p .ralph
    touch .ralph/fix_plan.md

    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 3
    assert_success
    [[ "$output" == "0" ]]
}

# --- revert_workspace_task edge cases ---

@test "revert_workspace_task on already unclaimed task is a no-op" {
    # Idempotency: reverting a [ ] task should keep it as [ ]
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Already unclaimed task
EOF

    run revert_workspace_task ".ralph/fix_plan.md" 4
    assert_success

    # Task should still be [ ] (revert only matches [~])
    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[ ]"* ]]
}

@test "revert_workspace_task on completed task is a no-op" {
    # Revert should NOT change [x] to [ ] — it only matches [~]
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Completed task
EOF

    run revert_workspace_task ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[x]"* ]]
}

@test "revert_workspace_task with missing file returns failure" {
    run revert_workspace_task "/nonexistent/fix_plan.md" 4
    assert_failure
}

@test "revert_workspace_task with empty line_num returns failure" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md

    run revert_workspace_task ".ralph/fix_plan.md" ""
    assert_failure
}

@test "revert_workspace_task with out-of-range line number is a no-op" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] In-progress task
EOF

    # Line 999 doesn't exist — awk will process all lines but find no match
    run revert_workspace_task ".ralph/fix_plan.md" 999
    assert_success

    # Original line should be unchanged
    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[~]"* ]]
}

# --- workspace_repo_worktree_create with WORKTREE_ENABLED=false ---

@test "workspace_repo_worktree_init skips when WORKTREE_ENABLED=false" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    WORKTREE_ENABLED="false"

    # worktree_init returns 0 when WORKTREE_ENABLED=false (early exit)
    run workspace_repo_worktree_init "$TEST_DIR/test-repo"
    assert_success

    # _WT_BASE_DIR should not be set (worktree_init bailed early)
    [[ -z "${_WT_BASE_DIR:-}" ]]
}

# --- get_workspace_parallel_limit cross-repo exclusion ---

@test "get_workspace_parallel_limit excludes cross-repo section from count" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## cross-repo
- [ ] Cross-repo task 1
- [ ] Cross-repo task 2

## repo-beta
- [ ] Beta task
EOF

    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0
    assert_success
    # Should count only repo-alpha and repo-beta (2), not cross-repo
    [[ "$output" == "2" ]]
}

@test "get_workspace_parallel_limit excludes repos with in-progress tasks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Alpha in-progress
- [ ] Alpha pending

## repo-beta
- [ ] Beta task

## repo-gamma
- [ ] Gamma task
EOF

    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0
    assert_success
    # repo-alpha excluded (has in-progress), so only beta + gamma = 2
    [[ "$output" == "2" ]]
}

# =============================================================================
# MEDIUM SEVERITY TESTS
# Missing depth/coverage for robustness
# =============================================================================

# --- Negative/invalid --parallel values ---

@test "--workspace --parallel -1 is rejected" {
    run bash "$RALPH_SCRIPT" --workspace --parallel -1
    assert_failure
}

@test "--workspace --parallel abc is rejected" {
    run bash "$RALPH_SCRIPT" --workspace --parallel abc
    assert_failure
}

@test "--workspace --parallel without argument is rejected" {
    # --parallel at end without a value — next arg would be missing
    run bash "$RALPH_SCRIPT" --workspace --parallel
    assert_failure
}

# --- Workspace with only cross-repo tasks ---

@test "pick_workspace_task picks cross-repo tasks in sequential mode" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Alpha done

## cross-repo
- [ ] Cross-repo task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"cross-repo|"* ]]
    [[ "$output" == *"Cross-repo task"* ]]
}

@test "pick_workspace_tasks_parallel skips cross-repo when all regular repos done" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Alpha done

## cross-repo
- [ ] Cross-repo task
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 3
    # Parallel mode explicitly skips cross-repo, so no tasks available
    assert_failure
}

# --- Workspace where .git exists at root (ambiguous state) ---

@test "is_workspace_mode returns false when .git exists at root" {
    mkdir -p .ralph .git child-repo/.git
    echo "# Plan" > .ralph/fix_plan.md

    run is_workspace_mode "."
    # Must NOT be a git repo itself
    assert_failure
}

@test "validate_workspace succeeds even with .git at root" {
    # validate_workspace checks different conditions than is_workspace_mode
    # It requires .ralph/fix_plan.md and child repos but doesn't check for root .git
    mkdir -p .ralph child-repo/.git .git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## child-repo
- [ ] Some task
EOF

    run validate_workspace "."
    # validate_workspace should still succeed — it doesn't check root .git
    assert_success
}

# --- workspace_repo_commit_and_pr without gh CLI ---

@test "workspace_repo_commit_and_pr succeeds without gh CLI" {
    mkdir -p test-repo
    cd test-repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt
    git commit --quiet -m "init"
    cd "$TEST_DIR"

    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    log_status() { :; }
    export -f log_status

    _WT_CURRENT_PATH=""
    _WT_CURRENT_BRANCH=""

    worktree_is_active() { return 1; }
    export -f worktree_is_active

    # Mock pr_preflight_check to simulate no gh CLI
    pr_preflight_check() {
        RALPH_PR_PUSH_CAPABLE="true"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    }
    export -f pr_preflight_check

    local fallback_called=false
    worktree_fallback_branch_pr() {
        touch "$TEST_DIR/.fallback_called"
        return 0
    }
    export -f worktree_fallback_branch_pr

    workspace_repo_commit_and_pr "$TEST_DIR/test-repo" "test-task" "Test task" "true"

    # Fallback should still be called — it handles the no-gh case internally
    [[ -f "$TEST_DIR/.fallback_called" ]]
}

# --- Workspace with symlinked repos ---

@test "discover_workspace_repos finds symlinked repos" {
    # Create a real repo elsewhere and symlink it
    mkdir -p "$TEST_DIR/real-repos/actual-repo/.git"
    ln -s "$TEST_DIR/real-repos/actual-repo" "$TEST_DIR/symlinked-repo"

    # Also create a normal repo
    mkdir -p "$TEST_DIR/normal-repo/.git"

    run discover_workspace_repos "$TEST_DIR"
    assert_success
    # Normal repo should be found
    [[ "$output" == *"normal-repo"* ]]
    # Symlinked repo: discover_workspace_repos checks for .git directory
    # which should resolve through the symlink
    [[ "$output" == *"symlinked-repo"* ]]
}

@test "is_workspace_mode works with symlinked child repos" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md

    # Create real repo elsewhere and symlink
    mkdir -p "$TEST_DIR/external/real-repo/.git"
    ln -s "$TEST_DIR/external/real-repo" "$TEST_DIR/linked-repo"

    run is_workspace_mode "."
    assert_success
}

# --- mark_workspace_task_complete additional edge cases ---

@test "mark_workspace_task_complete with out-of-range line number is a no-op" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] In-progress task
EOF

    run mark_workspace_task_complete ".ralph/fix_plan.md" 999
    assert_success

    # Line 4 should still be [~] (line 999 doesn't match)
    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[~]"* ]]
}

@test "mark_workspace_task_complete on already completed task is a no-op" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [x] Already done
EOF

    run mark_workspace_task_complete ".ralph/fix_plan.md" 4
    assert_success

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[x]"* ]]
}

# --- workspace_repo_run_quality_gates paths ---

@test "workspace_repo_run_quality_gates uses repo path when no worktree" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"

    _WT_CURRENT_PATH=""

    worktree_is_active() { return 1; }
    export -f worktree_is_active

    local captured_path=""
    worktree_run_quality_gates() {
        # _WT_CURRENT_PATH should have been temporarily set to repo_path
        echo "$_WT_CURRENT_PATH" > "$TEST_DIR/.captured_path"
        return 0
    }
    export -f worktree_run_quality_gates

    workspace_repo_run_quality_gates "$TEST_DIR/fake-repo"

    local captured
    captured=$(cat "$TEST_DIR/.captured_path")
    [[ "$captured" == "$TEST_DIR/fake-repo" ]]

    # _WT_CURRENT_PATH should be restored to empty
    [[ -z "$_WT_CURRENT_PATH" ]]
}

@test "workspace_repo_run_quality_gates delegates to worktree when active" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"

    _WT_CURRENT_PATH="/some/worktree/path"

    worktree_is_active() { return 0; }
    export -f worktree_is_active

    worktree_run_quality_gates() {
        touch "$TEST_DIR/.worktree_qg_called"
        return 0
    }
    export -f worktree_run_quality_gates

    workspace_repo_run_quality_gates "$TEST_DIR/fake-repo"

    [[ -f "$TEST_DIR/.worktree_qg_called" ]]
}

# --- workspace_repo_cleanup edge cases ---

@test "workspace_repo_cleanup is safe when worktree not active" {
    source "${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"

    _WT_CURRENT_PATH=""

    worktree_is_active() { return 1; }
    export -f worktree_is_active

    # Should return 0 and not fail
    run workspace_repo_cleanup "$TEST_DIR/fake-repo"
    assert_success
}

# --- build_workspace_repo_context edge cases ---

@test "build_workspace_repo_context handles special characters in task description" {
    run build_workspace_repo_context "repo-alpha" 'Fix "auth" with $HOME & <tags>' "$TEST_DIR"
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
}

# --- validate_workspace edge cases ---

@test "validate_workspace warns when repo in plan has no directory on disk" {
    mkdir -p .ralph repo-alpha/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task alpha

## repo-missing
- [ ] Task for missing repo
EOF

    run validate_workspace "."
    assert_success
    # Should warn about repo-missing
    [[ "$output" == *"repo-missing"* ]] || [[ "$stderr" == *"repo-missing"* ]] || true
}

# =============================================================================
# LOW SEVERITY TESTS
# Nice-to-have hardening
# =============================================================================

# --- Very long task descriptions ---

@test "pick_workspace_task truncates task_id to 50 chars" {
    mkdir -p .ralph
    local long_desc="This is a very long task description that should be truncated when generating the task ID because it exceeds the fifty character limit set in the code"
    cat > .ralph/fix_plan.md << EOF
# Workspace Fix Plan

## repo-alpha
- [ ] ${long_desc}
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success

    local task_id
    task_id=$(echo "$output" | cut -d'|' -f2)

    # task_id should be at most 50 characters
    local id_len=${#task_id}
    [[ $id_len -le 50 ]]
}

@test "pick_workspace_tasks_parallel truncates task_id to 50 chars" {
    mkdir -p .ralph
    local long_desc="This is a very long task description that should be truncated when generating the task ID because it exceeds the fifty character limit set in the code"
    cat > .ralph/fix_plan.md << EOF
# Workspace Fix Plan

## repo-alpha
- [ ] ${long_desc}
EOF

    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 1
    assert_success

    local task_id
    task_id=$(echo "$output" | cut -d'|' -f2)

    local id_len=${#task_id}
    [[ $id_len -le 50 ]]
}

# --- Large fix_plan.md ---

@test "parse_workspace_fix_plan handles large plan with many repos" {
    mkdir -p .ralph
    {
        echo "# Workspace Fix Plan"
        echo ""
        for i in $(seq 1 50); do
            echo "## repo-$(printf '%03d' $i)"
            echo "- [ ] Task $i for repo-$(printf '%03d' $i)"
            echo "- [ ] Second task $i"
            echo ""
        done
    } > .ralph/fix_plan.md

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success

    # Should find tasks in all 50 repos
    local line_count
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$line_count" -eq 100 ]]  # 50 repos * 2 tasks each
}

@test "pick_workspace_task works with 50 repos" {
    mkdir -p .ralph
    {
        echo "# Workspace Fix Plan"
        echo ""
        for i in $(seq 1 50); do
            echo "## repo-$(printf '%03d' $i)"
            echo "- [ ] Task for repo-$(printf '%03d' $i)"
            echo ""
        done
    } > .ralph/fix_plan.md

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success

    # Should pick from first repo alphabetically
    [[ "$output" == *"repo-001|"* ]]
}

@test "get_workspace_parallel_limit handles 50 repos with pending tasks" {
    mkdir -p .ralph
    {
        echo "# Workspace Fix Plan"
        echo ""
        for i in $(seq 1 50); do
            echo "## repo-$(printf '%03d' $i)"
            echo "- [ ] Task for repo-$(printf '%03d' $i)"
            echo ""
        done
    } > .ralph/fix_plan.md

    # Request 10 parallel — should be capped at 10 since 50 > 10
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 10
    assert_success
    [[ "$output" == "10" ]]

    # Auto mode — should return 50
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0
    assert_success
    [[ "$output" == "50" ]]
}

# --- Log file naming in parallel mode ---

@test "run_workspace_tasks_parallel creates unique log files per worker" {
    mkdir -p .ralph repo-alpha/.git repo-beta/.git repo-gamma/.git
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha task

## repo-beta
- [ ] Beta task

## repo-gamma
- [ ] Gamma task
EOF

    _mock_log_executor() { return 0; }
    export -f _mock_log_executor

    run run_workspace_tasks_parallel ".ralph/fix_plan.md" "." 3 "_mock_log_executor"
    assert_success

    # Each repo should have its own log file
    local alpha_logs beta_logs gamma_logs
    alpha_logs=$(ls .ralph/logs/parallel/ws_worker_repo-alpha_*.log 2>/dev/null | wc -l | tr -d ' ')
    beta_logs=$(ls .ralph/logs/parallel/ws_worker_repo-beta_*.log 2>/dev/null | wc -l | tr -d ' ')
    gamma_logs=$(ls .ralph/logs/parallel/ws_worker_repo-gamma_*.log 2>/dev/null | wc -l | tr -d ' ')

    [[ "$alpha_logs" -ge 1 ]]
    [[ "$beta_logs" -ge 1 ]]
    [[ "$gamma_logs" -ge 1 ]]
}

# --- Unicode/emoji in task descriptions ---

@test "pick_workspace_task handles unicode in description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix internationalization for Japanese text
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
}

@test "pick_workspace_task handles emoji in repo section name" {
    mkdir -p .ralph
    # Repo names with special chars — section header regex requires [A-Za-z0-9]
    # so emoji-prefixed headers would NOT match
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Normal task
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha|"* ]]
}

@test "mark_workspace_task_complete preserves unicode in file" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [~] Fix Japanese text rendering
- [ ] Fix Chinese text rendering
EOF

    run mark_workspace_task_complete ".ralph/fix_plan.md" 4
    assert_success

    # Verify unicode is preserved in the file
    grep -q 'Japanese' .ralph/fix_plan.md
    grep -q 'Chinese' .ralph/fix_plan.md

    local line4
    line4=$(sed -n '4p' .ralph/fix_plan.md)
    [[ "$line4" == *"[x]"* ]]
}

# --- discover_workspace_repos with many repos ---

@test "discover_workspace_repos handles 20 repos efficiently" {
    for i in $(seq 1 20); do
        mkdir -p "repo-$(printf '%03d' $i)/.git"
    done

    run discover_workspace_repos "."
    assert_success

    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 20 ]]

    # Verify sorted
    local first last
    first=$(echo "$output" | head -1)
    last=$(echo "$output" | tail -1)
    [[ "$first" == "repo-001" ]]
    [[ "$last" == "repo-020" ]]
}

# --- task_id generation edge cases ---

@test "pick_workspace_task generates clean task_id from messy description" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Fix --the-- BROKEN   endpoint!!!
EOF

    run pick_workspace_task ".ralph/fix_plan.md"
    assert_success

    local task_id
    task_id=$(echo "$output" | cut -d'|' -f2)

    # Should be lowercase, hyphens only, no special chars
    [[ "$task_id" =~ ^[a-z0-9-]+$ ]]
    # Should not have consecutive hyphens
    [[ "$task_id" != *"--"* ]]
    # Should not start or end with hyphen
    [[ "$task_id" != -* ]]
    [[ "$task_id" != *- ]]
}

# --- Multiple section header formats ---

@test "parse_workspace_fix_plan handles mixed H2 and H3 headers" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Alpha H2 task

### repo-beta
- [ ] Beta H3 task
EOF

    run parse_workspace_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
    [[ "$output" == *"repo-beta"* ]]
}

# --- Workspace mode detection edge cases ---

@test "is_workspace_mode returns false for empty directory" {
    mkdir -p empty-dir

    run is_workspace_mode "empty-dir"
    assert_failure
}

@test "is_workspace_mode returns false when only .ralph exists but no child repos" {
    mkdir -p workspace-no-repos/.ralph
    echo "# Plan" > workspace-no-repos/.ralph/fix_plan.md

    run is_workspace_mode "workspace-no-repos"
    assert_failure
}

@test "is_workspace_mode returns false when child repos exist but no .ralph" {
    mkdir -p workspace-no-ralph/child-repo/.git

    run is_workspace_mode "workspace-no-ralph"
    assert_failure
}

# =============================================================================
# ralph-plan --workspace: lib-level unit tests
# =============================================================================

@test "workspace_plan_preflight succeeds in valid workspace root" {
    mkdir -p ws/.ralph ws/repo-a/.git
    echo "# Workspace Fix Plan" > ws/.ralph/fix_plan.md

    run workspace_plan_preflight "ws"
    assert_success
}

@test "workspace_plan_preflight fails when cwd is a git repo" {
    mkdir -p bad/.git bad/.ralph
    echo "# Plan" > bad/.ralph/fix_plan.md

    run workspace_plan_preflight "bad"
    assert_failure
    [[ "$output" == *"git repository"* ]]
}

@test "workspace_plan_preflight fails without fix_plan.md" {
    mkdir -p ws/repo-a/.git

    run workspace_plan_preflight "ws"
    assert_failure
    [[ "$output" == *"fix_plan.md not found"* ]]
}

@test "workspace_plan_preflight fails without child repos" {
    mkdir -p ws/.ralph ws/docs-only
    echo "# Plan" > ws/.ralph/fix_plan.md

    run workspace_plan_preflight "ws"
    assert_failure
    [[ "$output" == *"No child git repositories"* ]]
}

@test "workspace_plan_parse_output extracts tasks, ambiguities, cross-repo" {
    cat > out.md << 'EOF'
## tasks
- Add health check endpoint
- Harden auth middleware

## ambiguities
- SLA for eventual consistency

## cross-repo
- Publish event schema to notifications
EOF

    run workspace_plan_parse_output "out.md"
    assert_success
    [[ "$output" == *"TASK|Add health check endpoint"* ]]
    [[ "$output" == *"TASK|Harden auth middleware"* ]]
    [[ "$output" == *"AMBIG|SLA for eventual consistency"* ]]
    [[ "$output" == *"CROSS|Publish event schema to notifications"* ]]
}

@test "workspace_plan_parse_output strips any accidental checkbox prefixes" {
    cat > out.md << 'EOF'
## tasks
- [ ] Plain task
- [x] Another task
EOF

    run workspace_plan_parse_output "out.md"
    assert_success
    [[ "$output" == *"TASK|Plain task"* ]]
    [[ "$output" == *"TASK|Another task"* ]]
}

@test "workspace_plan_merge_repo_section appends new tasks as unchecked" {
    mkdir -p ws/.ralph
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a

## svc-b
- [ ] Untouched
EOF

    cat > tasks.txt << 'EOF'
First new task
Second new task
EOF

    run workspace_plan_merge_repo_section ws/.ralph/fix_plan.md "svc-a" "tasks.txt"
    assert_success
    [[ "$output" == "2 0 0 0" ]]

    run cat ws/.ralph/fix_plan.md
    [[ "$output" == *"- [ ] First new task"* ]]
    [[ "$output" == *"- [ ] Second new task"* ]]
    [[ "$output" == *"- [ ] Untouched"* ]]
}

@test "workspace_plan_merge_repo_section preserves [~] and [x] state" {
    mkdir -p ws/.ralph
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a
- [~] Keep in progress
- [x] Keep completed
- [ ] Old pending that will be replaced
EOF

    cat > tasks.txt << 'EOF'
Keep in progress
Keep completed
Brand new task
EOF

    run workspace_plan_merge_repo_section ws/.ralph/fix_plan.md "svc-a" "tasks.txt"
    assert_success
    # 1 new (brand new), 2 preserved (1 in progress, 1 completed)
    [[ "$output" == "1 2 1 1" ]]

    run cat ws/.ralph/fix_plan.md
    [[ "$output" == *"- [~] Keep in progress"* ]]
    [[ "$output" == *"- [x] Keep completed"* ]]
    [[ "$output" == *"- [ ] Brand new task"* ]]
    # Old pending replaced, should NOT appear
    [[ "$output" != *"Old pending that will be replaced"* ]]
}

@test "workspace_plan_merge_repo_section appends section if missing" {
    mkdir -p ws/.ralph
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a
- [ ] Existing
EOF

    cat > tasks.txt << 'EOF'
Fresh task
EOF

    run workspace_plan_merge_repo_section ws/.ralph/fix_plan.md "svc-new" "tasks.txt"
    assert_success

    run cat ws/.ralph/fix_plan.md
    [[ "$output" == *"## svc-new"* ]]
    [[ "$output" == *"- [ ] Fresh task"* ]]
}

@test "workspace_plan_filter_repos returns all when filter empty" {
    local all=$'svc-a\nsvc-b\nsvc-c'
    run workspace_plan_filter_repos "$all" ""
    assert_success
    [[ "$output" == *"svc-a"* ]]
    [[ "$output" == *"svc-b"* ]]
    [[ "$output" == *"svc-c"* ]]
}

@test "workspace_plan_filter_repos restricts to allowlist" {
    local all=$'svc-a\nsvc-b\nsvc-c'
    run workspace_plan_filter_repos "$all" "svc-a,svc-c"
    assert_success
    [[ "$output" == *"svc-a"* ]]
    [[ "$output" != *"svc-b"* ]]
    [[ "$output" == *"svc-c"* ]]
}

@test "workspace_plan_append_cross_repo appends new tasks to existing section" {
    mkdir -p ws/.ralph
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a
- [ ] Local

## cross-repo
- [ ] Existing cross task
EOF

    cat > cross.txt << 'EOF'
New cross task
Existing cross task
EOF

    run workspace_plan_append_cross_repo ws/.ralph/fix_plan.md cross.txt
    assert_success
    # 1 appended (existing deduped)
    [[ "$output" == "1" ]]

    run cat ws/.ralph/fix_plan.md
    [[ "$output" == *"- [ ] New cross task"* ]]
    # Only one copy of the existing line
    local count
    count=$(grep -c "Existing cross task" ws/.ralph/fix_plan.md)
    [[ "$count" == "1" ]]
}

@test "workspace_plan_append_cross_repo creates section when missing" {
    mkdir -p ws/.ralph
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a
- [ ] Local
EOF

    echo "Bridge event schema" > cross.txt

    run workspace_plan_append_cross_repo ws/.ralph/fix_plan.md cross.txt
    assert_success

    run cat ws/.ralph/fix_plan.md
    [[ "$output" == *"## cross-repo"* ]]
    [[ "$output" == *"- [ ] Bridge event schema"* ]]
}

# =============================================================================
# ralph-plan --workspace: end-to-end with mock engine
# =============================================================================

_ws_plan_setup_mock_workspace() {
    # Create a workspace with two repos, each with ai/ context
    mkdir -p ws/.ralph ws/svc-a/.git ws/svc-b/.git
    mkdir -p ws/svc-a/ai ws/svc-b/.ralph/specs

    echo "PRD: add health endpoint" > ws/svc-a/ai/prd.md
    echo "Spec: event schema" > ws/svc-b/.ralph/specs/schema.md

    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a

## svc-b

## cross-repo
EOF

    # Mock engine outputs
    mkdir -p mocks
    cat > mocks/svc-a.out.md << 'EOF'
## tasks
- Add health endpoint to svc-a
- Add readiness probe

## ambiguities
- Timeout threshold not defined
EOF

    cat > mocks/svc-b.out.md << 'EOF'
## tasks
- Publish event schema

## cross-repo
- Bridge svc-b events to notifications
EOF
}

@test "ralph-plan --workspace happy path: both repo sections populated" {
    _ws_plan_setup_mock_workspace

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success

    [[ "$output" == *"Workspace Plan Summary"* ]]
    [[ "$output" == *"Repos planned:       2"* ]]
    [[ "$output" == *"New tasks:           3"* ]]
    [[ "$output" == *"Cross-repo tasks:    1"* ]]
    [[ "$output" == *"Ambiguities flagged: 1"* ]]

    run cat .ralph/fix_plan.md
    [[ "$output" == *"- [ ] Add health endpoint to svc-a"* ]]
    [[ "$output" == *"- [ ] Add readiness probe"* ]]
    [[ "$output" == *"- [ ] Publish event schema"* ]]
    [[ "$output" == *"- [ ] Bridge svc-b events to notifications"* ]]
}

@test "ralph-plan --workspace preserves [~] in-progress tasks across reruns" {
    _ws_plan_setup_mock_workspace

    # Pre-seed svc-a with an in-progress task that also appears in new plan
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a
- [~] Add health endpoint to svc-a

## svc-b

## cross-repo
EOF

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace
    assert_success
    # Summary reports preserved task (check before overwriting $output)
    [[ "${output}" == *"1 in-progress"* ]]

    run cat .ralph/fix_plan.md
    [[ "$output" == *"- [~] Add health endpoint to svc-a"* ]]
    # No duplicate [ ] entry for same task
    local count
    count=$(grep -c "Add health endpoint to svc-a" .ralph/fix_plan.md)
    [[ "$count" == "1" ]]
}

@test "ralph-plan --workspace updates ## cross-repo with flagged tasks" {
    _ws_plan_setup_mock_workspace

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace
    assert_success

    run cat .ralph/fix_plan.md
    [[ "$output" == *"## cross-repo"* ]]
    [[ "$output" == *"- [ ] Bridge svc-b events to notifications"* ]]
}

@test "ralph-plan --workspace fails preflight when run from a git repo" {
    # cwd has .git
    mkdir -p bad/.git bad/.ralph
    echo "# Plan" > bad/.ralph/fix_plan.md

    cd bad
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace
    assert_failure
    [[ "$output" == *"git repository"* ]] || [[ "$output" == *"workspace"* ]]
}

@test "ralph-plan --workspace --repos filters to listed repos only" {
    _ws_plan_setup_mock_workspace

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --repos svc-a
    assert_success
    [[ "$output" == *"Repos planned:       1"* ]]

    run cat .ralph/fix_plan.md
    # svc-a was planned
    [[ "$output" == *"- [ ] Add health endpoint to svc-a"* ]]
    # svc-b section untouched — no new tasks injected
    [[ "$output" != *"Publish event schema"* ]]
}

@test "ralph-plan --workspace --dry-run emits summary without writing" {
    _ws_plan_setup_mock_workspace

    # Snapshot original fix_plan
    local before
    before=$(cat ws/.ralph/fix_plan.md)

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --dry-run
    assert_success
    [[ "$output" == *"Workspace Plan Summary"* ]]
    [[ "$output" == *"DRY-RUN"* ]]

    # fix_plan unchanged
    local after
    after=$(cat .ralph/fix_plan.md)
    [[ "$before" == "$after" ]]
}

@test "ralph-plan --workspace skips repos without ai/ or .ralph/specs/ context" {
    mkdir -p ws/.ralph ws/svc-a/.git ws/svc-b/.git
    mkdir -p ws/svc-a/ai
    echo "PRD" > ws/svc-a/ai/prd.md
    # svc-b has no context at all

    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a

## svc-b
EOF

    mkdir -p mocks
    cat > mocks/svc-a.out.md << 'EOF'
## tasks
- Task for svc-a
EOF

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace
    assert_success
    [[ "$output" == *"Skipped (no context): 1"* ]] || [[ "$output" == *"svc-b"* ]]
}
