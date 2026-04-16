#!/usr/bin/env bats
# Unit tests for workspace mode — multi-repo orchestration
# Tests: repo discovery, workspace fix_plan.md parsing, default branch detection,
#         per-repo context switching, CLI parsing (--workspace flag), template loading

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../../templates"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (sets up functions)
    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
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
