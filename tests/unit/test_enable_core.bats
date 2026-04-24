#!/usr/bin/env bats
# Unit tests for lib/enable_core.sh
# Tests idempotency, safe file creation, project detection, and template generation

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to enable_core.sh
ENABLE_CORE="${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"
ORIGINAL_HOME="$HOME"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Isolate HOME so tests that write to ~/.ralph don't leak to real home dir
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    # Source the library (disable set -e for testing)
    set +e
    source "$ENABLE_CORE"
    set -e
}

teardown() {
    export HOME="$ORIGINAL_HOME"
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# IDEMPOTENCY CHECKS (5 tests)
# =============================================================================

@test "check_existing_ralph returns 'none' when no .ralph directory exists" {
    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "none"
}

@test "check_existing_ralph returns 'complete' when all required files exist" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md

    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "complete"
}

@test "check_existing_ralph returns 'partial' when some files are missing" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    # Missing fix_plan.md and AGENT.md

    check_existing_ralph || true

    assert_equal "$RALPH_STATE" "partial"
    [[ " ${RALPH_MISSING_FILES[*]} " =~ ".ralph/fix_plan.md" ]]
    [[ " ${RALPH_MISSING_FILES[*]} " =~ ".ralph/AGENT.md" ]]
}

@test "is_ralph_enabled returns 0 when fully enabled" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md

    run is_ralph_enabled
    assert_success
}

@test "is_ralph_enabled returns 1 when not enabled" {
    run is_ralph_enabled
    assert_failure
}

# =============================================================================
# SAFE FILE OPERATIONS (5 tests)
# =============================================================================

@test "safe_create_file creates file that doesn't exist" {
    run safe_create_file "test.txt" "test content"

    assert_success
    [[ -f "test.txt" ]]
    [[ "$(cat test.txt)" == "test content" ]]
}

@test "safe_create_file skips existing file" {
    echo "original content" > existing.txt

    run safe_create_file "existing.txt" "new content"

    assert_failure  # Returns 1 for skip
    assert_equal "$(cat existing.txt)" "original content"
    [[ "$output" =~ "SKIP" ]] || [[ "$output" =~ "already exists" ]]
}

@test "safe_create_file creates parent directories" {
    run safe_create_file "nested/dir/file.txt" "nested content"

    assert_success
    [[ -f "nested/dir/file.txt" ]]
    [[ "$(cat nested/dir/file.txt)" == "nested content" ]]
}

@test "safe_create_dir creates directory that doesn't exist" {
    run safe_create_dir "new_dir"

    assert_success
    [[ -d "new_dir" ]]
}

@test "safe_create_dir succeeds when directory already exists" {
    mkdir existing_dir

    run safe_create_dir "existing_dir"

    assert_success
    [[ -d "existing_dir" ]]
}

# =============================================================================
# DIRECTORY STRUCTURE (2 tests)
# =============================================================================

@test "create_ralph_structure creates all required directories" {
    run create_ralph_structure

    assert_success
    [[ -d ".ralph" ]]
    [[ -d ".ralph/specs" ]]
    [[ -d ".ralph/examples" ]]
    [[ -d ".ralph/logs" ]]
    [[ -d ".ralph/docs/generated" ]]
}

@test "create_ralph_structure is idempotent" {
    create_ralph_structure
    echo "test" > .ralph/specs/test.txt

    run create_ralph_structure

    assert_success
    [[ -f ".ralph/specs/test.txt" ]]
}

# =============================================================================
# PROJECT DETECTION (6 tests)
# =============================================================================

@test "detect_project_context identifies TypeScript from package.json" {
    cat > package.json << 'EOF'
{
    "name": "my-ts-project",
    "devDependencies": {
        "typescript": "^5.0.0"
    }
}
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "typescript"
    assert_equal "$DETECTED_PROJECT_NAME" "my-ts-project"
}

@test "detect_project_context identifies JavaScript from package.json" {
    cat > package.json << 'EOF'
{
    "name": "my-js-project"
}
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "javascript"
}

@test "detect_project_context identifies Python from pyproject.toml" {
    cat > pyproject.toml << 'EOF'
[project]
name = "my-python-project"
EOF

    detect_project_context

    assert_equal "$DETECTED_PROJECT_TYPE" "python"
}

@test "detect_project_context identifies Next.js framework" {
    cat > package.json << 'EOF'
{
    "name": "nextjs-app",
    "dependencies": {
        "next": "^14.0.0"
    }
}
EOF

    detect_project_context

    assert_equal "$DETECTED_FRAMEWORK" "nextjs"
}

@test "detect_project_context identifies FastAPI framework" {
    cat > pyproject.toml << 'EOF'
[project]
name = "fastapi-app"
dependencies = ["fastapi>=0.100.0"]
EOF

    detect_project_context

    assert_equal "$DETECTED_FRAMEWORK" "fastapi"
}

@test "detect_project_context falls back to folder name" {
    detect_project_context

    # Should use the temp directory name
    [[ -n "$DETECTED_PROJECT_NAME" ]]
}

# =============================================================================
# GIT DETECTION (3 tests)
# =============================================================================

@test "detect_git_info detects git repository" {
    git init >/dev/null 2>&1

    detect_git_info

    assert_equal "$DETECTED_GIT_REPO" "true"
}

@test "detect_git_info detects non-git directory" {
    detect_git_info

    assert_equal "$DETECTED_GIT_REPO" "false"
}

@test "detect_git_info detects GitHub remote" {
    git init >/dev/null 2>&1
    git remote add origin git@github.com:user/repo.git 2>/dev/null || true

    detect_git_info

    assert_equal "$DETECTED_GIT_GITHUB" "true"
}

# =============================================================================
# TASK SOURCE DETECTION (2 tests)
# =============================================================================

@test "detect_task_sources detects .beads directory" {
    mkdir -p .beads

    detect_task_sources

    assert_equal "$DETECTED_BEADS_AVAILABLE" "true"
}

@test "detect_task_sources finds PRD files" {
    mkdir -p docs
    echo "# Requirements" > docs/requirements.md

    detect_task_sources

    [[ ${#DETECTED_PRD_FILES[@]} -gt 0 ]]
}

# =============================================================================
# TEMPLATE GENERATION (4 tests)
# =============================================================================

@test "generate_prompt_md includes project name" {
    output=$(generate_prompt_md "my-project" "typescript")

    [[ "$output" =~ "my-project" ]]
}

@test "generate_prompt_md includes project type" {
    output=$(generate_prompt_md "my-project" "python")

    [[ "$output" =~ "python" ]]
}

@test "generate_agent_md includes build command" {
    output=$(generate_agent_md "npm run build" "npm test" "npm start")

    [[ "$output" =~ "npm run build" ]]
    [[ "$output" =~ "npm test" ]]
}

@test "generate_ralphrc includes project configuration" {
    output=$(generate_ralphrc "my-project" "typescript" "local,beads")

    [[ "$output" =~ "PROJECT_NAME=\"my-project\"" ]]
    [[ "$output" =~ "PROJECT_TYPE=\"typescript\"" ]]
    [[ "$output" =~ "TASK_SOURCES=\"local,beads\"" ]]
}

# =============================================================================
# FULL ENABLE FLOW (3 tests)
# =============================================================================

@test "enable_ralph_in_directory creates all required files" {
    export ENABLE_FORCE="false"
    export ENABLE_SKIP_TASKS="true"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success
    [[ -f ".ralph/PROMPT.md" ]]
    [[ -f ".ralph/fix_plan.md" ]]
    [[ -f ".ralph/AGENT.md" ]]
    [[ -f ".ralphrc" ]]
}

@test "enable_ralph_in_directory returns ALREADY_ENABLED when complete and no force" {
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Fix Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md

    export ENABLE_FORCE="false"

    run enable_ralph_in_directory

    assert_equal "$status" "$ENABLE_ALREADY_ENABLED"
}

@test "enable_ralph_in_directory overwrites with force flag" {
    mkdir -p .ralph
    echo "old content" > .ralph/PROMPT.md
    echo "old fix plan" > .ralph/fix_plan.md
    echo "old agent" > .ralph/AGENT.md

    export ENABLE_FORCE="true"
    export ENABLE_PROJECT_NAME="new-project"

    run enable_ralph_in_directory

    assert_success

    # Verify files were actually overwritten, not just skipped
    local prompt_content
    prompt_content=$(cat .ralph/PROMPT.md)

    # Should contain new project name, not "old content"
    [[ "$prompt_content" != "old content" ]]
    [[ "$prompt_content" == *"new-project"* ]]
}

# =============================================================================
# FIX_PLAN.MD PRESERVATION (4 tests)
# Verify fix_plan.md is preserved on re-enable to protect work progress
# =============================================================================

@test "enable_ralph_in_directory preserves fix_plan.md with force and no new tasks" {
    mkdir -p .ralph
    echo "old content" > .ralph/PROMPT.md
    echo "- [x] My completed task" > .ralph/fix_plan.md
    echo "old agent" > .ralph/AGENT.md

    export ENABLE_FORCE="true"
    export ENABLE_PROJECT_NAME="new-project"
    export ENABLE_TASK_CONTENT=""

    run enable_ralph_in_directory

    assert_success

    # fix_plan.md should be preserved (no new tasks imported)
    local fix_plan_content
    fix_plan_content=$(cat .ralph/fix_plan.md)
    [[ "$fix_plan_content" == "- [x] My completed task" ]]
}

@test "enable_ralph_in_directory overwrites fix_plan.md with force AND new task content" {
    mkdir -p .ralph
    echo "old content" > .ralph/PROMPT.md
    echo "- [x] My completed task" > .ralph/fix_plan.md
    echo "old agent" > .ralph/AGENT.md

    export ENABLE_FORCE="true"
    export ENABLE_PROJECT_NAME="new-project"
    export ENABLE_TASK_CONTENT="- [ ] New imported task from beads"

    run enable_ralph_in_directory

    assert_success

    # fix_plan.md should be overwritten with new task content
    local fix_plan_content
    fix_plan_content=$(cat .ralph/fix_plan.md)
    [[ "$fix_plan_content" == *"New imported task from beads"* ]]
}

@test "enable_ralph_in_directory preserves fix_plan.md without force flag" {
    # Create a partial .ralph (missing AGENT.md so state is "partial")
    mkdir -p .ralph
    echo "prompt" > .ralph/PROMPT.md
    echo "- [x] My completed task" > .ralph/fix_plan.md

    export ENABLE_FORCE="false"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success

    # fix_plan.md should be preserved
    local fix_plan_content
    fix_plan_content=$(cat .ralph/fix_plan.md)
    [[ "$fix_plan_content" == "- [x] My completed task" ]]
}

@test "enable_ralph_in_directory creates fix_plan.md when missing" {
    # Create a partial .ralph without fix_plan.md
    mkdir -p .ralph
    echo "prompt" > .ralph/PROMPT.md

    export ENABLE_FORCE="false"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success

    # fix_plan.md should be created
    [[ -f ".ralph/fix_plan.md" ]]
    local fix_plan_content
    fix_plan_content=$(cat .ralph/fix_plan.md)
    [[ "$fix_plan_content" == *"Ralph Fix Plan"* ]]
}

@test "safe_create_file overwrites existing file when ENABLE_FORCE is true" {
    # Create existing file with old content
    echo "original content" > test_file.txt

    export ENABLE_FORCE="true"

    run safe_create_file "test_file.txt" "new content"

    assert_success

    # Verify file was overwritten
    local content
    content=$(cat test_file.txt)
    [[ "$content" == "new content" ]]
}

@test "safe_create_file skips existing file when ENABLE_FORCE is false" {
    # Create existing file with old content
    echo "original content" > test_file.txt

    export ENABLE_FORCE="false"

    run safe_create_file "test_file.txt" "new content"

    # Should return 1 (skipped)
    assert_failure

    # Verify file was NOT overwritten
    local content
    content=$(cat test_file.txt)
    [[ "$content" == "original content" ]]
}

# =============================================================================
# PROTECTED FILES SECTION (Issue #149) (2 tests)
# Verify generate_prompt_md includes "Protected Files" warning before "Testing Guidelines"
# so Claude sees protection rules early in the prompt.
# =============================================================================

@test "generate_prompt_md output contains Protected Files section" {
    output=$(generate_prompt_md "my-project" "typescript")

    [[ "$output" =~ "Protected Files" ]]
    [[ "$output" =~ ".ralph/" ]]
    [[ "$output" =~ ".ralphrc" ]]
    [[ "$output" =~ "NEVER delete" ]]
}

@test "generate_prompt_md Protected Files section appears before Testing Guidelines" {
    output=$(generate_prompt_md "my-project" "typescript")

    # Find position of Protected Files and Testing Guidelines
    local protected_pos testing_pos
    protected_pos=$(echo "$output" | grep -n "Protected Files" | head -1 | cut -d: -f1)
    testing_pos=$(echo "$output" | grep -n "Testing Guidelines" | head -1 | cut -d: -f1)

    # Protected Files should come before Testing Guidelines
    [[ -n "$protected_pos" ]]
    [[ -n "$testing_pos" ]]
    [[ "$protected_pos" -lt "$testing_pos" ]]
}

# =============================================================================
# .GITIGNORE INJECTION (Issue #174) (5 tests)
# =============================================================================

@test "enable_ralph_in_directory creates .gitignore with Ralph entries when none exists" {
    export ENABLE_FORCE="false"
    export ENABLE_SKIP_TASKS="true"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success
    [[ -f ".gitignore" ]]
    grep -qF "# Ralph — ignore everything except key files" .gitignore
    grep -qF ".ralph/*" .gitignore
    grep -qF "!.ralph/fix_plan.md" .gitignore
    grep -qF "!.ralph/PROMPT.md" .gitignore
    grep -qF "!.ralph/PROMPT_PLAN.md" .gitignore
    grep -qF "!.ralph/constitution.md" .gitignore
}

@test "enable_ralph_in_directory appends Ralph entries to existing .gitignore" {
    # Pre-existing .gitignore with custom content
    echo "my-custom-ignore" > .gitignore

    export ENABLE_FORCE="false"
    export ENABLE_SKIP_TASKS="true"
    export ENABLE_PROJECT_NAME="test-project"

    run enable_ralph_in_directory

    assert_success
    # Should preserve existing content AND add Ralph entries
    grep -qF "my-custom-ignore" .gitignore
    grep -qF ".ralph/*" .gitignore
    grep -qF "!.ralph/fix_plan.md" .gitignore
}

@test "enable_ralph_in_directory is idempotent — does not duplicate entries" {
    export ENABLE_FORCE="false"
    export ENABLE_SKIP_TASKS="true"
    export ENABLE_PROJECT_NAME="test-project"

    # First run
    enable_ralph_in_directory

    # Count occurrences of the marker
    local count_before
    count_before=$(grep -cF "# Ralph — ignore everything except key files" .gitignore)

    # Second run (force to re-enable)
    export ENABLE_FORCE="true"
    run enable_ralph_in_directory

    assert_success
    local count_after
    count_after=$(grep -cF "# Ralph — ignore everything except key files" .gitignore)
    [[ "$count_after" -eq "$count_before" ]]
}

@test "inject_ralph_gitignore skips when Ralph entries already present" {
    # Create .gitignore with Ralph entries already present
    cat > .gitignore << 'EOF'
node_modules/
# Ralph — ignore everything except key files
.ralph/*
!.ralph/fix_plan.md
!.ralph/PROMPT.md
!.ralph/PROMPT_PLAN.md
!.ralph/constitution.md
EOF

    run inject_ralph_gitignore

    assert_success
    # Should only appear once
    local count
    count=$(grep -cF ".ralph/*" .gitignore)
    [[ "$count" -eq 1 ]]
}

@test "inject_ralph_gitignore appends with blank line separator" {
    echo "node_modules/" > .gitignore

    run inject_ralph_gitignore

    assert_success
    # The file should have the original content followed by Ralph block
    head -1 .gitignore | grep -qF "node_modules/"
    grep -qF ".ralph/*" .gitignore
}

# =============================================================================
# WORKSPACE MODE (14 tests)
# =============================================================================

@test "detect_workspace_context returns false for git repo" {
    git init > /dev/null 2>&1

    detect_workspace_context

    assert_equal "$DETECTED_WORKSPACE" "false"
}

@test "detect_workspace_context returns false for empty directory" {
    detect_workspace_context

    assert_equal "$DETECTED_WORKSPACE" "false"
}

@test "detect_workspace_context detects workspace with child git repos" {
    mkdir -p repo-alpha/.git repo-beta/.git

    detect_workspace_context

    assert_equal "$DETECTED_WORKSPACE" "true"
    assert_equal "${#DETECTED_WORKSPACE_REPOS[@]}" "2"
}

@test "detect_workspace_context skips hidden directories" {
    mkdir -p .hidden-repo/.git repo-alpha/.git

    detect_workspace_context

    assert_equal "$DETECTED_WORKSPACE" "true"
    assert_equal "${#DETECTED_WORKSPACE_REPOS[@]}" "1"
    assert_equal "${DETECTED_WORKSPACE_REPOS[0]}" "repo-alpha"
}

@test "detect_workspace_context skips non-git child directories" {
    mkdir -p not-a-repo repo-alpha/.git

    detect_workspace_context

    assert_equal "$DETECTED_WORKSPACE" "true"
    assert_equal "${#DETECTED_WORKSPACE_REPOS[@]}" "1"
    assert_equal "${DETECTED_WORKSPACE_REPOS[0]}" "repo-alpha"
}

@test "generate_workspace_prompt_md contains workspace instructions" {
    local output
    output=$(generate_workspace_prompt_md)

    echo "$output" | grep -qF "Workspace Mode"
    echo "$output" | grep -qF "Working Directory Constraint"
    echo "$output" | grep -qF "RALPH_STATUS"
    echo "$output" | grep -qF "Cross-Repository Tasks"
}

@test "generate_workspace_fix_plan_md creates per-repo sections" {
    local repos
    repos=$(printf 'alpha\nbeta\ngamma\n')

    local output
    output=$(generate_workspace_fix_plan_md "$repos")

    echo "$output" | grep -qF "# Workspace Fix Plan"
    echo "$output" | grep -qF "## alpha"
    echo "$output" | grep -qF "## beta"
    echo "$output" | grep -qF "## gamma"
    echo "$output" | grep -qF "## cross-repo"
}

@test "generate_workspace_fix_plan_md uses pre-imported tasks when provided" {
    local tasks="# Custom Plan

## my-repo
- [ ] Custom task"

    local output
    output=$(generate_workspace_fix_plan_md "" "$tasks")

    echo "$output" | grep -qF "Custom task"
    echo "$output" | grep -qF "## my-repo"
}

@test "generate_workspace_ralphrc sets WORKSPACE_MODE=true" {
    local output
    output=$(generate_workspace_ralphrc "my-workspace" "3")

    echo "$output" | grep -qF 'WORKSPACE_MODE=true'
    echo "$output" | grep -qF 'PROJECT_TYPE="workspace"'
    echo "$output" | grep -qF 'WORKSPACE_REPO_COUNT=3'
    echo "$output" | grep -qF 'PROJECT_NAME="my-workspace"'
}

@test "enable_workspace_in_directory creates all workspace files" {
    mkdir -p repo-alpha/.git repo-beta/.git

    export ENABLE_FORCE="false"
    export ENABLE_WORKSPACE_NAME="test-ws"
    export ENABLE_TASK_CONTENT=""

    run enable_workspace_in_directory

    assert_success
    [[ -d ".ralph" ]]
    [[ -f ".ralph/PROMPT.md" ]]
    [[ -f ".ralph/fix_plan.md" ]]
    [[ -f ".ralph/AGENT.md" ]]
    [[ -f ".ralphrc" ]]
}

@test "enable_workspace_in_directory fix_plan has repo sections" {
    mkdir -p repo-alpha/.git repo-beta/.git

    export ENABLE_FORCE="false"
    export ENABLE_WORKSPACE_NAME="test-ws"
    export ENABLE_TASK_CONTENT=""

    enable_workspace_in_directory

    grep -qF "## repo-alpha" .ralph/fix_plan.md
    grep -qF "## repo-beta" .ralph/fix_plan.md
    grep -qF "## cross-repo" .ralph/fix_plan.md
}

@test "enable_workspace_in_directory fails when not a workspace" {
    git init > /dev/null 2>&1

    export ENABLE_FORCE="false"
    export ENABLE_WORKSPACE_NAME="test"
    export ENABLE_TASK_CONTENT=""

    run enable_workspace_in_directory

    assert_failure
}

@test "enable_workspace_in_directory returns already enabled without force" {
    mkdir -p repo-alpha/.git
    mkdir -p .ralph
    echo "# PROMPT" > .ralph/PROMPT.md
    echo "# Plan" > .ralph/fix_plan.md
    echo "# Agent" > .ralph/AGENT.md

    export ENABLE_FORCE="false"
    export ENABLE_WORKSPACE_NAME="test-ws"
    export ENABLE_TASK_CONTENT=""

    run enable_workspace_in_directory

    assert_equal "$status" "$ENABLE_ALREADY_ENABLED"
}
