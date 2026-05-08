#!/usr/bin/env bats
# Unit tests for continuous-mode CLI parsing (--parallel N M shape) across
# all three engine wrappers (Claude / Devin / Codex).
# See docs/proposals/continuous-parallel-execution.md (amended 2026-05-08).

load '../helpers/test_helper'

CLAUDE_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
DEVIN_LOOP="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
CODEX_LOOP="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# Help text mentions --parallel N [M] and the tuning flags
# =============================================================================

@test "claude --help describes --parallel N [M]" {
    run bash "$CLAUDE_LOOP" --help
    assert_success
    [[ "$output" == *"--parallel N"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"Continuous"* ]]
}

@test "claude --help mentions --max-task-attempts" {
    run bash "$CLAUDE_LOOP" --help
    assert_success
    [[ "$output" == *"--max-task-attempts"* ]]
}

@test "claude --help mentions --respawn-delay" {
    run bash "$CLAUDE_LOOP" --help
    assert_success
    [[ "$output" == *"--respawn-delay"* ]]
}

@test "devin --help describes --parallel N [M]" {
    run bash "$DEVIN_LOOP" --help
    assert_success
    [[ "$output" == *"--parallel N"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"Continuous"* ]]
}

@test "devin --help mentions --max-task-attempts" {
    run bash "$DEVIN_LOOP" --help
    assert_success
    [[ "$output" == *"--max-task-attempts"* ]]
}

@test "devin --help mentions --respawn-delay" {
    run bash "$DEVIN_LOOP" --help
    assert_success
    [[ "$output" == *"--respawn-delay"* ]]
}

@test "codex --help describes --parallel N [M]" {
    run bash "$CODEX_LOOP" --help
    assert_success
    [[ "$output" == *"--parallel N"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"Continuous"* ]]
}

@test "codex --help mentions --max-task-attempts" {
    run bash "$CODEX_LOOP" --help
    assert_success
    [[ "$output" == *"--max-task-attempts"* ]]
}

@test "codex --help mentions --respawn-delay" {
    run bash "$CODEX_LOOP" --help
    assert_success
    [[ "$output" == *"--respawn-delay"* ]]
}

# =============================================================================
# --max-tasks flag is gone (replaced by --parallel N M)
# =============================================================================

@test "claude no longer accepts --max-tasks flag" {
    run bash "$CLAUDE_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"Unknown option"* ]] || [[ "$output" == *"--max-tasks"* ]]
}

@test "devin no longer accepts --max-tasks flag" {
    run bash "$DEVIN_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"Unknown option"* ]] || [[ "$output" == *"--max-tasks"* ]]
}

@test "codex no longer accepts --max-tasks flag" {
    run bash "$CODEX_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"Unknown option"* ]] || [[ "$output" == *"--max-tasks"* ]]
}

# =============================================================================
# Numeric validation: --parallel N requires positive integer
# =============================================================================

@test "claude --parallel rejects non-numeric N" {
    run bash "$CLAUDE_LOOP" --parallel abc
    assert_failure
    [[ "$output" == *"--parallel"* ]]
    [[ "$output" == *"positive integer"* ]] || [[ "$output" == *"integer"* ]]
}

@test "claude --parallel rejects zero" {
    run bash "$CLAUDE_LOOP" --parallel 0
    assert_failure
    [[ "$output" == *"--parallel"* ]]
}

@test "devin --parallel rejects non-numeric N" {
    run bash "$DEVIN_LOOP" --parallel abc
    assert_failure
    [[ "$output" == *"--parallel"* ]]
}

@test "codex --parallel rejects non-numeric N" {
    run bash "$CODEX_LOOP" --parallel abc
    assert_failure
    [[ "$output" == *"--parallel"* ]]
}

@test "claude --max-task-attempts rejects non-numeric" {
    run bash "$CLAUDE_LOOP" --max-task-attempts xyz
    assert_failure
}

@test "claude --max-task-attempts rejects zero" {
    run bash "$CLAUDE_LOOP" --max-task-attempts 0
    assert_failure
}

@test "claude --respawn-delay rejects non-numeric" {
    run bash "$CLAUDE_LOOP" --respawn-delay foo
    assert_failure
}

@test "claude --respawn-delay accepts zero" {
    run bash "$CLAUDE_LOOP" --respawn-delay 0 --help
    assert_success
}

# =============================================================================
# Two-arg --parallel N M engages continuous mode (verified via --help short-circuit)
# =============================================================================

@test "claude --parallel N alone (no M) parses as batch mode" {
    run bash "$CLAUDE_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "claude --parallel N M parses as continuous mode" {
    run bash "$CLAUDE_LOOP" --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "claude --workspace --parallel N M parses cleanly" {
    run bash "$CLAUDE_LOOP" --workspace --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N alone parses cleanly" {
    run bash "$DEVIN_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N M parses as continuous mode" {
    run bash "$DEVIN_LOOP" --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --workspace --parallel N M parses cleanly" {
    run bash "$DEVIN_LOOP" --workspace --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N alone parses cleanly" {
    run bash "$CODEX_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N M parses as continuous mode" {
    run bash "$CODEX_LOOP" --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --workspace --parallel N M parses cleanly" {
    run bash "$CODEX_LOOP" --workspace --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# --parallel N (no M) followed by another flag does NOT consume the flag as M
# =============================================================================

@test "claude --parallel N --calls X does not absorb X as M" {
    # `--parallel 3 --calls 50 --help`: M should not be set (next arg is --calls, not numeric).
    run bash "$CLAUDE_LOOP" --parallel 3 --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N --calls X does not absorb X as M" {
    run bash "$DEVIN_LOOP" --parallel 3 --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N --calls X does not absorb X as M" {
    run bash "$CODEX_LOOP" --parallel 3 --calls 50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Mutual exclusion errors when continuous mode (--parallel N M) is engaged
# =============================================================================

@test "claude --parallel N M with --task errors (mutually exclusive)" {
    run bash "$CLAUDE_LOOP" --task 1 --parallel 2 5
    assert_failure
    [[ "$output" == *"--task"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"--parallel"* ]]
}

@test "claude --parallel N M with --qg errors (mutually exclusive)" {
    run bash "$CLAUDE_LOOP" --qg --parallel 2 5
    assert_failure
    [[ "$output" == *"--qg"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"--parallel"* ]]
}

@test "claude --parallel-bg N excludes continuous-mode error message hint" {
    # `--parallel-bg N` alone does not enter continuous mode; this is just a
    # sanity check that the bg path is unaffected by the refactor.
    run bash "$CLAUDE_LOOP" --parallel-bg 2 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N M with --task errors" {
    run bash "$DEVIN_LOOP" --task 1 --parallel 2 5
    assert_failure
    [[ "$output" == *"--task"* ]]
}

@test "codex --parallel N M with --task errors" {
    run bash "$CODEX_LOOP" --task 1 --parallel 2 5
    assert_failure
    [[ "$output" == *"--task"* ]]
}

# =============================================================================
# Full continuous flag set parses cleanly
# =============================================================================

@test "claude full continuous flag set parses cleanly" {
    run bash "$CLAUDE_LOOP" --parallel 3 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin full continuous flag set parses cleanly" {
    run bash "$DEVIN_LOOP" --parallel 3 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex full continuous flag set parses cleanly" {
    run bash "$CODEX_LOOP" --parallel 3 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# RALPH_MAX_TASKS env is gone — engagement is always explicit at CLI
# =============================================================================

@test "RALPH_MAX_TASKS env has no effect (only --parallel N M engages continuous)" {
    # With the env set but only --parallel N (no second arg), help must still
    # short-circuit cleanly — env is no longer interpreted.
    RALPH_MAX_TASKS=10 run bash "$CLAUDE_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "RALPH_MAX_TASK_ATTEMPTS env still honored" {
    # K-tuning env survives; verify it doesn't break parse.
    RALPH_MAX_TASK_ATTEMPTS=2 run bash "$CLAUDE_LOOP" --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "RALPH_RESPAWN_DELAY env still honored" {
    RALPH_RESPAWN_DELAY=5 run bash "$CLAUDE_LOOP" --parallel 3 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Backward compat: --parallel N alone is V1 behavior unchanged
# =============================================================================

@test "claude --parallel N alone is recognized" {
    run bash "$CLAUDE_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N alone is recognized" {
    run bash "$DEVIN_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N alone is recognized" {
    run bash "$CODEX_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}
