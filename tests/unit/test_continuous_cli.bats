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

# =============================================================================
# `--parallel N 0` and similar typos produce a clear error (not "Unknown option")
# =============================================================================

@test "claude --parallel N 0 errors with a clear M-must-be-positive message" {
    run bash "$CLAUDE_LOOP" --parallel 3 0
    assert_failure
    [[ "$output" == *"continuous-mode M"* ]]
    [[ "$output" == *"positive integer"* ]] || [[ "$output" == *">= 1"* ]]
    # Must NOT bleed through to the generic "Unknown option" path.
    [[ "$output" != *"Unknown option: 0"* ]]
}

@test "devin --parallel N 0 errors with a clear M-must-be-positive message" {
    run bash "$DEVIN_LOOP" --parallel 3 0
    assert_failure
    [[ "$output" == *"continuous-mode M"* ]]
    [[ "$output" != *"Unknown option: 0"* ]]
}

@test "codex --parallel N 0 errors with a clear M-must-be-positive message" {
    run bash "$CODEX_LOOP" --parallel 3 0
    assert_failure
    [[ "$output" == *"continuous-mode M"* ]]
    [[ "$output" != *"Unknown option: 0"* ]]
}

@test "claude --parallel N 007 (leading-zero numeric) errors clearly" {
    run bash "$CLAUDE_LOOP" --parallel 3 007
    assert_failure
    [[ "$output" == *"continuous-mode M"* ]]
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

# --monitor + --parallel N M is rejected with a clear error message that
# tells the user how to monitor a continuous run (run ralph-monitor in
# another terminal, status.json IS kept up-to-date by the orchestrator).
@test "claude --monitor + --parallel N M is rejected" {
    run bash "$CLAUDE_LOOP" --monitor --parallel 2 5
    assert_failure
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"continuous"* ]]
    [[ "$output" == *"ralph-monitor"* ]]
    [[ "$output" == *"status.json"* ]]
}

@test "claude -m + --parallel N M is rejected (short flag)" {
    run bash "$CLAUDE_LOOP" -m --parallel 2 5
    assert_failure
    [[ "$output" == *"--monitor"* ]]
}

@test "devin --monitor + --parallel N M is rejected" {
    run bash "$DEVIN_LOOP" --monitor --parallel 2 5
    assert_failure
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"continuous"* ]]
    [[ "$output" == *"ralph-monitor-devin"* ]]
}

@test "codex --monitor + --parallel N M is rejected" {
    run bash "$CODEX_LOOP" --monitor --parallel 2 5
    assert_failure
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"continuous"* ]]
    [[ "$output" == *"ralph-monitor-codex"* ]]
}

@test "claude --monitor + --parallel N (batch only) is still allowed" {
    # --monitor only conflicts with continuous mode (N M with two args),
    # not with batch parallel (N alone).  This is a parse-time check —
    # we just want it to NOT fail with the continuous-mode rejection.
    run bash "$CLAUDE_LOOP" --monitor --parallel 2 --help
    [[ "$output" != *"--monitor / -m is not yet supported"* ]]
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
# Numeric caps: --parallel N is capped at 10 to prevent fork-bombing
# =============================================================================

@test "claude --parallel 11 (over cap) errors with capped-at-10 message" {
    run bash "$CLAUDE_LOOP" --parallel 11
    assert_failure
    [[ "$output" == *"capped at 10"* ]]
}

@test "claude --parallel 100 errors with capped-at-10 message" {
    run bash "$CLAUDE_LOOP" --parallel 100
    assert_failure
    [[ "$output" == *"capped at 10"* ]]
}

@test "devin --parallel 11 errors" {
    run bash "$DEVIN_LOOP" --parallel 11
    assert_failure
    [[ "$output" == *"capped at 10"* ]]
}

@test "codex --parallel 11 errors" {
    run bash "$CODEX_LOOP" --parallel 11
    assert_failure
    [[ "$output" == *"capped at 10"* ]]
}

@test "claude --parallel 10 (at cap) is accepted" {
    run bash "$CLAUDE_LOOP" --parallel 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "claude --parallel 10 20 (continuous, N at cap) is accepted" {
    run bash "$CLAUDE_LOOP" --parallel 10 20 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Engine auto-exit + continuous mode is mutually exclusive (codex / devin)
# =============================================================================

@test "codex --no-codex-auto-exit + continuous mode is rejected" {
    run bash "$CODEX_LOOP" --no-codex-auto-exit --parallel 2 5
    assert_failure
    [[ "$output" == *"--no-codex-auto-exit"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"--parallel"* ]]
}

@test "devin --no-devin-auto-exit + continuous mode is rejected" {
    run bash "$DEVIN_LOOP" --no-devin-auto-exit --parallel 2 5
    assert_failure
    [[ "$output" == *"--no-devin-auto-exit"* ]]
    [[ "$output" == *"continuous"* ]] || [[ "$output" == *"--parallel"* ]]
}

@test "codex --no-codex-auto-exit + batch --parallel (no M) still allowed" {
    # Batch parallel without M is the existing interactive use case.
    run bash "$CODEX_LOOP" --no-codex-auto-exit --parallel 2 --help
    assert_success
}

@test "devin --no-devin-auto-exit + batch --parallel (no M) still allowed" {
    run bash "$DEVIN_LOOP" --no-devin-auto-exit --parallel 2 --help
    assert_success
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

# =============================================================================
# Engine-specific _continuous_update_status writes the 4 proposal-mandated
# fields (mode, target_M, concurrency_N, attempts_completed) on top of the
# standard status.json shape.
# =============================================================================

@test "claude _continuous_update_status writes mode/target_M/concurrency_N/attempts_completed" {
    local td
    td="$(mktemp -d)"
    export RALPH_DIR="${td}/.ralph"
    export STATUS_FILE="${RALPH_DIR}/status.json"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100
    export WORKTREE_ENABLED=false

    # Source just the function definition by extracting it.
    eval "$(awk '/^_continuous_update_status\(\)/,/^export -f _continuous_update_status/' "$CLAUDE_LOOP")"
    # Stubs for helpers the function references.
    get_iso_timestamp() { echo "2026-05-08T12:00:00Z"; }
    get_next_hour_time() { echo "2026-05-08T13:00:00Z"; }
    worktree_get_branch() { echo ""; }
    worktree_get_path() { echo ""; }
    export -f get_iso_timestamp get_next_hour_time worktree_get_branch worktree_get_path

    _continuous_update_status "continuous:executing" "running" 7 100 3

    [[ -f "$STATUS_FILE" ]]
    local content
    content=$(cat "$STATUS_FILE")
    # Required new fields
    [[ "$content" == *'"mode": "continuous"'* ]]
    [[ "$content" == *'"target_M": 100'* ]]
    [[ "$content" == *'"concurrency_N": 3'* ]]
    [[ "$content" == *'"attempts_completed": 7'* ]]
    # Standard fields preserved
    [[ "$content" == *'"engine": "claude"'* ]]
    [[ "$content" == *'"last_action": "continuous:executing"'* ]]
    [[ "$content" == *'"status": "running"'* ]]

    # Output must be valid JSON (jq parse).
    echo "$content" | jq . > /dev/null

    rm -rf "$td"
}

@test "devin _continuous_update_status writes engine=devin + 4 mandated fields" {
    local td
    td="$(mktemp -d)"
    export RALPH_DIR="${td}/.ralph"
    export STATUS_FILE="${RALPH_DIR}/status.json"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100
    export WORKTREE_ENABLED=false
    export DEVIN_SESSION_ID="dev-session-x"

    eval "$(awk '/^_continuous_update_status\(\)/,/^export -f _continuous_update_status/' "$DEVIN_LOOP")"
    get_iso_timestamp() { echo "2026-05-08T12:00:00Z"; }
    get_next_hour_time() { echo "2026-05-08T13:00:00Z"; }
    worktree_get_branch() { echo ""; }
    worktree_get_path() { echo ""; }
    export -f get_iso_timestamp get_next_hour_time worktree_get_branch worktree_get_path

    _continuous_update_status "continuous:starting" "running" 0 50 2

    local content
    content=$(cat "$STATUS_FILE")
    [[ "$content" == *'"engine": "devin"'* ]]
    [[ "$content" == *'"mode": "continuous"'* ]]
    [[ "$content" == *'"target_M": 50'* ]]
    [[ "$content" == *'"concurrency_N": 2'* ]]
    [[ "$content" == *'"attempts_completed": 0'* ]]
    [[ "$content" == *'"devin_session_id": "dev-session-x"'* ]]
    echo "$content" | jq . > /dev/null

    rm -rf "$td"
}

@test "codex _continuous_update_status writes engine=codex + 4 mandated fields" {
    local td
    td="$(mktemp -d)"
    export RALPH_DIR="${td}/.ralph"
    export STATUS_FILE="${RALPH_DIR}/status.json"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100
    export WORKTREE_ENABLED=false
    export CODEX_SESSION_ID="codex-session-y"

    eval "$(awk '/^_continuous_update_status\(\)/,/^export -f _continuous_update_status/' "$CODEX_LOOP")"
    get_iso_timestamp() { echo "2026-05-08T12:00:00Z"; }
    get_next_hour_time() { echo "2026-05-08T13:00:00Z"; }
    worktree_get_branch() { echo ""; }
    worktree_get_path() { echo ""; }
    export -f get_iso_timestamp get_next_hour_time worktree_get_branch worktree_get_path

    _continuous_update_status "continuous:completed" "stopped" 50 50 2 "target reached (M)"

    local content
    content=$(cat "$STATUS_FILE")
    [[ "$content" == *'"engine": "codex"'* ]]
    [[ "$content" == *'"mode": "continuous"'* ]]
    [[ "$content" == *'"target_M": 50'* ]]
    [[ "$content" == *'"concurrency_N": 2'* ]]
    [[ "$content" == *'"attempts_completed": 50'* ]]
    [[ "$content" == *'"exit_reason": "target reached (M)"'* ]]
    [[ "$content" == *'"codex_session_id": "codex-session-y"'* ]]
    echo "$content" | jq . > /dev/null

    rm -rf "$td"
}
