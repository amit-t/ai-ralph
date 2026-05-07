#!/usr/bin/env bats
# Unit tests for --max-tasks / --max-task-attempts / --respawn-delay CLI parsing
# across all three engine wrappers (Claude / Devin / Codex).
# See docs/proposals/continuous-parallel-execution.md §3, §4, §13

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
# Help text mentions the new flags
# =============================================================================

@test "claude --help mentions --max-tasks" {
    run bash "$CLAUDE_LOOP" --help
    assert_success
    [[ "$output" == *"--max-tasks"* ]]
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

@test "devin --help mentions --max-tasks" {
    run bash "$DEVIN_LOOP" --help
    assert_success
    [[ "$output" == *"--max-tasks"* ]]
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

@test "codex --help mentions --max-tasks" {
    run bash "$CODEX_LOOP" --help
    assert_success
    [[ "$output" == *"--max-tasks"* ]]
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
# Numeric validation: positive integer
# =============================================================================

@test "claude --max-tasks rejects non-numeric" {
    run bash "$CLAUDE_LOOP" --max-tasks abc
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"positive integer"* ]] || [[ "$output" == *"integer"* ]]
}

@test "claude --max-tasks rejects zero" {
    run bash "$CLAUDE_LOOP" --max-tasks 0
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
}

@test "claude --max-tasks rejects negative" {
    run bash "$CLAUDE_LOOP" --max-tasks -3
    assert_failure
}

@test "devin --max-tasks rejects non-numeric" {
    run bash "$DEVIN_LOOP" --max-tasks abc
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
}

@test "devin --max-tasks rejects zero" {
    run bash "$DEVIN_LOOP" --max-tasks 0
    assert_failure
}

@test "codex --max-tasks rejects non-numeric" {
    run bash "$CODEX_LOOP" --max-tasks abc
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
}

@test "codex --max-tasks rejects zero" {
    run bash "$CODEX_LOOP" --max-tasks 0
    assert_failure
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
# Mutual exclusion errors
# =============================================================================

@test "claude --max-tasks without --parallel errors" {
    run bash "$CLAUDE_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--parallel"* ]]
}

@test "claude --max-tasks with --task errors (mutually exclusive)" {
    run bash "$CLAUDE_LOOP" --task 1 --parallel 2 --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--task"* ]]
}

@test "claude --max-tasks with --qg errors (mutually exclusive)" {
    run bash "$CLAUDE_LOOP" --qg --parallel 2 --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--qg"* ]]
}

@test "claude --max-tasks with --parallel-bg errors" {
    run bash "$CLAUDE_LOOP" --parallel-bg 2 --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--parallel"* ]]
}

@test "devin --max-tasks without --parallel errors" {
    run bash "$DEVIN_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--parallel"* ]]
}

@test "devin --max-tasks with --task errors" {
    run bash "$DEVIN_LOOP" --task 1 --parallel 2 --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--task"* ]]
}

@test "codex --max-tasks without --parallel errors" {
    run bash "$CODEX_LOOP" --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--parallel"* ]]
}

@test "codex --max-tasks with --task errors" {
    run bash "$CODEX_LOOP" --task 1 --parallel 2 --max-tasks 5
    assert_failure
    [[ "$output" == *"--max-tasks"* ]]
    [[ "$output" == *"--task"* ]]
}

# =============================================================================
# Valid combinations parse without error (verified via --help short-circuit)
# =============================================================================

@test "claude --parallel N --max-tasks M --help parses cleanly" {
    run bash "$CLAUDE_LOOP" --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "claude --workspace --parallel N --max-tasks M --help parses cleanly" {
    run bash "$CLAUDE_LOOP" --workspace --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N --max-tasks M --help parses cleanly" {
    run bash "$DEVIN_LOOP" --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --workspace --parallel N --max-tasks M --help parses cleanly" {
    run bash "$DEVIN_LOOP" --workspace --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N --max-tasks M --help parses cleanly" {
    run bash "$CODEX_LOOP" --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --workspace --parallel N --max-tasks M --help parses cleanly" {
    run bash "$CODEX_LOOP" --workspace --parallel 3 --max-tasks 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "claude full continuous flag set parses cleanly" {
    run bash "$CLAUDE_LOOP" --parallel 3 --max-tasks 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin full continuous flag set parses cleanly" {
    run bash "$DEVIN_LOOP" --parallel 3 --max-tasks 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex full continuous flag set parses cleanly" {
    run bash "$CODEX_LOOP" --parallel 3 --max-tasks 10 --max-task-attempts 2 --respawn-delay 1 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Backward compatibility: --parallel N (no --max-tasks) is unchanged
# =============================================================================

@test "claude --parallel N alone is still recognized" {
    run bash "$CLAUDE_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "devin --parallel N alone is still recognized" {
    run bash "$DEVIN_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "codex --parallel N alone is still recognized" {
    run bash "$CODEX_LOOP" --parallel 3 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Env overrides
# =============================================================================

@test "claude RALPH_MAX_TASKS env requires --parallel" {
    RALPH_MAX_TASKS=10 run bash "$CLAUDE_LOOP"
    # Without --parallel, env-driven --max-tasks should still error.
    assert_failure
    [[ "$output" == *"--max-tasks"* ]] || [[ "$output" == *"RALPH_MAX_TASKS"* ]]
}

@test "claude CLI flag overrides env" {
    # Both set; no behavior assertion beyond clean parse with --help.
    RALPH_MAX_TASKS=10 run bash "$CLAUDE_LOOP" --parallel 3 --max-tasks 20 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}
