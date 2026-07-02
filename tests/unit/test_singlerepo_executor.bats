#!/usr/bin/env bats
# Unit tests for _singlerepo_execute_task across all 3 engines.
#
# This function is the core executor for single-repo continuous mode (only
# called from _continuous_singlerepo_executor in worker_pool.sh dispatch).
# It's ~80 lines per engine, identical except for the execute_*_session call.
#
# We mock every external dependency (engine CLI, worktree manager, PR manager,
# git) and exercise each branch:
#   - engine returns non-zero → return 1, no PR
#   - engine returns 0 but no files changed → return 1 (no-op revert)
#   - engine returns 0 + files changed + gates pass → return 0, PR created
#   - engine returns 0 + files changed + gates fail → return 0 (PR with label)
#
# See docs/proposals/continuous-parallel-execution.md §5.4 (executor abstraction).

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"

    # A real fix_plan so the function's `sed -n line p` works.
    cat > "${RALPH_DIR}/fix_plan.md" << 'EOF'
- [~] Test task one
- [~] Test task two
EOF

    # Track which mocks were called (in order) for assertion.
    : > "${TEST_DIR}/.calls"

    # ── Mock: every engine's session entrypoint ─────────────────────────────
    # Default: succeed, simulate a file change. Tests override per-case.
    execute_claude_code()  { echo "execute_claude_code $*"  >> "${TEST_DIR}/.calls"; return 0; }
    execute_devin_session() { echo "execute_devin_session $*" >> "${TEST_DIR}/.calls"; return 0; }
    execute_codex_session() { echo "execute_codex_session $*" >> "${TEST_DIR}/.calls"; return 0; }
    export -f execute_claude_code execute_devin_session execute_codex_session

    # ── Mock: worktree manager ──────────────────────────────────────────────
    # Default: worktree creation fails so the function takes the
    # non-worktree (cwd) path. Tests can override to enable worktrees.
    WORKTREE_ENABLED=false
    WORKTREE_QUALITY_GATES="auto"
    PR_ENABLED=true
    export WORKTREE_ENABLED WORKTREE_QUALITY_GATES PR_ENABLED

    worktree_create()         { echo "worktree_create $*"      >> "${TEST_DIR}/.calls"; return 0; }
    worktree_get_path()       { echo "${TEST_DIR}"; }
    worktree_is_active()      { echo "worktree_is_active"      >> "${TEST_DIR}/.calls"; return 1; }
    worktree_cleanup()        { echo "worktree_cleanup $*"     >> "${TEST_DIR}/.calls"; return 0; }
    worktree_run_quality_gates() { echo "worktree_run_quality_gates" >> "${TEST_DIR}/.calls"; return 0; }
    worktree_commit_and_pr()  { echo "worktree_commit_and_pr $*" >> "${TEST_DIR}/.calls"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 0; }
    export -f worktree_create worktree_get_path worktree_is_active worktree_cleanup
    export -f worktree_run_quality_gates worktree_commit_and_pr worktree_fallback_branch_pr

    # ── Set up a tiny git repo so `git rev-parse HEAD` and `git status`
    #    succeed (the function's change-detection branch).
    git init -q "${TEST_DIR}" 2>/dev/null
    (cd "${TEST_DIR}" && git config user.email "t@t" && git config user.name "T")
    # `.ralph/` and the test scratch files are gitignored — in production
    # `.ralph/` is always in the project's .gitignore, so without this line
    # `git status --porcelain` would falsely report .ralph/ as a change and
    # the executor would mistake fixtures for real work.
    cat > "${TEST_DIR}/.gitignore" << 'GITIGNORE'
.ralph/
.calls
.trap_snapshot
GITIGNORE
    (cd "${TEST_DIR}" && git add .gitignore && touch initial.txt && git add initial.txt \
        && git commit -q -m initial 2>/dev/null) || true

    # By default, no uncommitted changes — change-detection sees 0 files
    # changed so the executor returns 1 (no-op). Tests that want a "files
    # changed" outcome create a file before calling the function.
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Extract _singlerepo_execute_task from a given engine script and source it
# into the current shell. This avoids running the engine's whole CLI parser.
_load_singlerepo_executor() {
    local engine_script="$1"
    local fn_text
    fn_text=$(awk '/^_singlerepo_execute_task\(\) \{/,/^}/' "$engine_script")
    [[ -n "$fn_text" ]] || fail "Could not extract _singlerepo_execute_task from $engine_script"
    eval "$fn_text"
}

# =============================================================================
# Branch 1: engine returns non-zero → return 1, no PR, worktree cleaned up
# =============================================================================

@test "claude executor: engine non-zero rc → return 1 and no PR" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() { return 7; }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
    ! grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "devin executor: engine non-zero rc → return 1 and no PR" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
    execute_devin_session() { return 9; }
    export -f execute_devin_session

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
}

@test "codex executor: engine non-zero rc → return 1 and no PR" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"
    execute_codex_session() { return 11; }
    export -f execute_codex_session

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 2: engine returns 0, but no files changed → return 1 (no-op revert)
# =============================================================================

@test "claude executor: engine ok but no files changed → return 1 (no-op)" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    # Engine succeeds, default mocks, no file mutation in $TEST_DIR.

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
    ! grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "devin executor: engine ok but no files changed → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
}

@test "codex executor: engine ok but no files changed → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 3: engine returns 0 + files changed → return 0 + PR created
# =============================================================================

@test "claude executor: engine ok + files changed → return 0 + PR created (fallback)" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() {
        # Simulate a file change in cwd (which equals $TEST_DIR).
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    # No worktree active → fallback branch PR taken.
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "devin executor: engine ok + files changed → return 0 + PR created" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
    execute_devin_session() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_devin_session

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "codex executor: engine ok + files changed → return 0 + PR created" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"
    execute_codex_session() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_codex_session

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 4: PR_ENABLED=false → no PR call, but task still marked complete (rc 0)
# =============================================================================

@test "claude executor: PR_ENABLED=false skips PR creation but returns 0" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_claude_code
    PR_ENABLED=false
    export PR_ENABLED

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    ! grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
    ! grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 5: WORKTREE_ENABLED=true → worktree path taken
# =============================================================================

@test "claude executor: WORKTREE_ENABLED=true uses worktree_commit_and_pr" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    WORKTREE_ENABLED=true
    export WORKTREE_ENABLED
    # worktree_create succeeds (default mock returns 0), and worktree_is_active
    # must return 0 for the worktree path.
    worktree_is_active() { echo "worktree_is_active" >> "${TEST_DIR}/.calls"; return 0; }
    export -f worktree_is_active

    execute_claude_code() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    grep -q "worktree_create" "${TEST_DIR}/.calls"
    grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
    # worktree_cleanup must run on exit.
    grep -q "worktree_cleanup" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 6: Quality gates fail but PR still gets created (with failure flag).
# Per AGENTS.md: gate failures don't revert the task; they label the PR.
# =============================================================================

@test "claude executor: quality-gates fail → PR still created, executor returns 0" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    WORKTREE_ENABLED=true
    export WORKTREE_ENABLED
    worktree_is_active() { return 0; }
    worktree_run_quality_gates() {
        echo "worktree_run_quality_gates" >> "${TEST_DIR}/.calls"
        return 1  # gates fail
    }
    worktree_commit_and_pr() {
        echo "worktree_commit_and_pr $*" >> "${TEST_DIR}/.calls"
        return 0
    }
    export -f worktree_is_active worktree_run_quality_gates worktree_commit_and_pr

    execute_claude_code() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    # Gate ran, PR still created with the gate-failed flag (3rd positional arg).
    grep -q "worktree_run_quality_gates" "${TEST_DIR}/.calls"
    grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
    # The 3rd arg to commit_and_pr should be "false" when gates failed.
    grep -E "worktree_commit_and_pr task-1 .* false" "${TEST_DIR}/.calls" \
        || grep -E "worktree_commit_and_pr .*false" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 7: WORKTREE_QUALITY_GATES=none → gates skipped entirely
# =============================================================================

@test "claude executor: WORKTREE_QUALITY_GATES=none skips gate run" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    WORKTREE_ENABLED=true
    WORKTREE_QUALITY_GATES=none
    export WORKTREE_ENABLED WORKTREE_QUALITY_GATES
    worktree_is_active() { return 0; }
    export -f worktree_is_active

    execute_claude_code() {
        echo "modified" > "${TEST_DIR}/some_file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-1|1|"
    assert_success
    ! grep -q "worktree_run_quality_gates" "${TEST_DIR}/.calls"
    grep -q "worktree_commit_and_pr" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 8: descriptor parsing — task_id, line_num, bead_id all extracted
# =============================================================================

@test "claude executor: descriptor with all three fields parses correctly" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() {
        # Capture args so we can verify the executor passed task_id and line_num.
        echo "execute_claude_code loop=$1 work=$2 task_id=$3 line=$4 desc=$5" \
            >> "${TEST_DIR}/.calls"
        echo "modified" > "${TEST_DIR}/file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "my-task-id|1|BEAD-42"
    assert_success
    grep -q "task_id=my-task-id" "${TEST_DIR}/.calls"
    grep -q "line=1" "${TEST_DIR}/.calls"
}

@test "claude executor: empty bead_id (descriptor has trailing pipe) is handled" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() {
        echo "execute_claude_code task_id=$3" >> "${TEST_DIR}/.calls"
        echo "modified" > "${TEST_DIR}/file.txt"
        return 0
    }
    export -f execute_claude_code

    run _singlerepo_execute_task "task-no-bead|2|"
    assert_success
    grep -q "task_id=task-no-bead" "${TEST_DIR}/.calls"
}

# =============================================================================
# Branch 5: engine ok + files changed, but PR workflow fails → return 1
# (task left open for the pool's K-retry/skip-list — never a silent [x])
# =============================================================================

@test "claude executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    execute_claude_code() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_claude_code worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "devin executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
    execute_devin_session() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_devin_session worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}

@test "codex executor: PR step fails → return 1" {
    _load_singlerepo_executor "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"
    execute_codex_session() { echo "modified" > "${TEST_DIR}/some_file.txt"; return 0; }
    worktree_fallback_branch_pr() { echo "worktree_fallback_branch_pr $*" >> "${TEST_DIR}/.calls"; return 1; }
    export -f execute_codex_session worktree_fallback_branch_pr

    run _singlerepo_execute_task "task-1|1|"
    assert_failure
    grep -q "worktree_fallback_branch_pr" "${TEST_DIR}/.calls"
}
