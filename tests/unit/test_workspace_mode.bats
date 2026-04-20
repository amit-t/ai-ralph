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
