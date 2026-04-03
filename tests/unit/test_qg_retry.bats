#!/usr/bin/env bats
# Unit tests for quality gate retry behaviour
# Tests: worktree_build_qg_fix_prompt, MAX_QG_RETRIES config, retry loop structure

load '../helpers/test_helper'

WORKTREE_MANAGER="${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"
RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
CODEX_LOOP="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"
DEVIN_LOOP="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    source "$WORKTREE_MANAGER"

    # Set after sourcing (source resets _WT_CURRENT_PATH to "")
    _WT_CURRENT_PATH="$TEST_DIR/worktree"
    mkdir -p "$_WT_CURRENT_PATH/.ralph"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# worktree_build_qg_fix_prompt — output structure
# =============================================================================

@test "worktree_build_qg_fix_prompt includes attempt number in heading" {
    echo "FAIL: pnpm run typecheck (exit 2)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 2 3
    assert_success
    [[ "$output" == *"Attempt 2/3"* ]]
}

@test "worktree_build_qg_fix_prompt lists failed gates" {
    printf "PASS: pnpm run lint\nFAIL: pnpm run typecheck (exit 2)\nFAIL: pnpm test (exit 1)\nPASS: pnpm run build\n" \
        > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *'`pnpm run typecheck (exit 2)`'* ]]
    [[ "$output" == *'`pnpm test (exit 1)`'* ]]
}

@test "worktree_build_qg_fix_prompt does not list passing gates in Failed Gates section" {
    printf "PASS: pnpm run lint\nFAIL: pnpm test (exit 1)\n" \
        > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    # The Failed Gates section should not mention the passing gate
    local failed_section
    failed_section=$(echo "$output" | sed -n '/^## Failed Gates/,/^## /p')
    [[ "$failed_section" != *"pnpm run lint"* ]]
}

@test "worktree_build_qg_fix_prompt includes fix instructions" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"Fix ALL errors"* ]]
    [[ "$output" == *"gates will be re-run automatically"* ]]
}

@test "worktree_build_qg_fix_prompt handles missing results file" {
    rm -f "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"no gate results file found"* ]]
}

@test "worktree_build_qg_fix_prompt includes Full Error Output section" {
    echo "FAIL: echo error_output (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"## Full Error Output"* ]]
}

@test "worktree_build_qg_fix_prompt instructs agent not to modify gate config" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"do not modify quality gate configuration"* ]]
}

@test "worktree_build_qg_fix_prompt includes subagent strategy section" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"## Strategy: Use Subagents"* ]]
}

@test "worktree_build_qg_fix_prompt instructs use of subagent/task spawning" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"subagent/task spawning capability"* ]]
}

@test "worktree_build_qg_fix_prompt lists per-gate subagent tasks for multiple failures" {
    printf "FAIL: pnpm run typecheck (exit 2)\nFAIL: pnpm test (exit 1)\nFAIL: pnpm run build (exit 1)\n" \
        > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"one subagent per failing gate"* ]]
    [[ "$output" == *"Subagent 1"* ]]
    [[ "$output" == *"Subagent 2"* ]]
    [[ "$output" == *"Subagent 3"* ]]
    [[ "$output" == *"pnpm run typecheck"* ]]
    [[ "$output" == *"pnpm test"* ]]
    [[ "$output" == *"pnpm run build"* ]]
}

@test "worktree_build_qg_fix_prompt uses single subagent for single failure" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"Spawn a subagent to investigate"* ]]
    # Should NOT have numbered subagent tasks
    [[ "$output" != *"Subagent 1"* ]]
}

@test "worktree_build_qg_fix_prompt instructs conflict verification for multiple failures" {
    printf "FAIL: pnpm run typecheck (exit 2)\nFAIL: pnpm test (exit 1)\n" \
        > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"verify their changes do not conflict"* ]]
}

@test "worktree_build_qg_fix_prompt instructions mention subagents" {
    echo "FAIL: pnpm test (exit 1)" > "$_WT_CURRENT_PATH/.ralph/.quality_gate_results"

    run worktree_build_qg_fix_prompt 1 3
    assert_success
    [[ "$output" == *"Use subagents to fix the errors"* ]]
}

# =============================================================================
# MAX_QG_RETRIES config defaults
# =============================================================================

@test "ralph_loop.sh sets MAX_QG_RETRIES default to 3" {
    local line
    line=$(grep -n 'MAX_QG_RETRIES=' "$RALPH_LOOP" | grep -v '#' | head -1)
    [[ "$line" == *'MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"'* ]]
}

@test "codex loop sets MAX_QG_RETRIES default to 3" {
    local line
    line=$(grep -n 'MAX_QG_RETRIES=' "$CODEX_LOOP" | grep -v '#' | head -1)
    [[ "$line" == *'MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"'* ]]
}

@test "devin loop sets MAX_QG_RETRIES default to 3" {
    local line
    line=$(grep -n 'MAX_QG_RETRIES=' "$DEVIN_LOOP" | grep -v '#' | head -1)
    [[ "$line" == *'MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"'* ]]
}

# =============================================================================
# QG retry loop structure in loop scripts
# =============================================================================

@test "ralph_loop.sh has QG retry loop with worktree_build_qg_fix_prompt" {
    grep -q 'worktree_build_qg_fix_prompt' "$RALPH_LOOP"
}

@test "codex loop has QG retry loop with worktree_build_qg_fix_prompt" {
    grep -q 'worktree_build_qg_fix_prompt' "$CODEX_LOOP"
}

@test "devin loop has QG retry loop with worktree_build_qg_fix_prompt" {
    grep -q 'worktree_build_qg_fix_prompt' "$DEVIN_LOOP"
}

@test "ralph_loop.sh retry loop iterates up to MAX_QG_RETRIES" {
    grep -q 'qg_attempt -lt \$MAX_QG_RETRIES' "$RALPH_LOOP" || \
    grep -q 'qg_attempt -lt $MAX_QG_RETRIES' "$RALPH_LOOP"
}

@test "codex loop retry iterates up to MAX_QG_RETRIES" {
    grep -q 'qg_attempt -lt \$MAX_QG_RETRIES' "$CODEX_LOOP" || \
    grep -q 'qg_attempt -lt $MAX_QG_RETRIES' "$CODEX_LOOP"
}

@test "devin loop retry iterates up to MAX_QG_RETRIES" {
    grep -q 'qg_attempt -lt \$MAX_QG_RETRIES' "$DEVIN_LOOP" || \
    grep -q 'qg_attempt -lt $MAX_QG_RETRIES' "$DEVIN_LOOP"
}

@test "ralph_loop.sh re-runs quality gates after each fix attempt" {
    local count
    count=$(grep -c 'worktree_run_quality_gates' "$RALPH_LOOP")
    [[ $count -ge 2 ]]  # initial run + retry
}

@test "codex loop re-runs quality gates after each fix attempt" {
    local count
    count=$(grep -c 'worktree_run_quality_gates' "$CODEX_LOOP")
    [[ $count -ge 2 ]]
}

@test "devin loop re-runs quality gates after each fix attempt" {
    local count
    count=$(grep -c 'worktree_run_quality_gates' "$DEVIN_LOOP")
    [[ $count -ge 2 ]]
}

@test "ralph_loop.sh creates failure PR only after retries exhausted" {
    # The "still failing" message should appear, meaning PR is only created after retry loop
    grep -q 'still failing after.*fix attempts' "$RALPH_LOOP"
}

@test "codex loop creates failure PR only after retries exhausted" {
    grep -q 'still failing after.*fix attempts' "$CODEX_LOOP"
}

@test "devin loop creates failure PR only after retries exhausted" {
    grep -q 'still failing after.*fix attempts' "$DEVIN_LOOP"
}

@test "ralph_loop.sh auto-commits before QG retry" {
    grep -q 'pre-QG-retry auto-commit' "$RALPH_LOOP"
}

@test "ralph_loop.sh enables Task tool for QG fix subagents" {
    grep -q 'Task' "$RALPH_LOOP" | head -1 || \
    grep -q 'CLAUDE_ALLOWED_TOOLS.*Task' "$RALPH_LOOP"
}

@test "ralph_loop.sh saves and restores CLAUDE_ALLOWED_TOOLS around QG fix" {
    grep -q '_saved_allowed_tools' "$RALPH_LOOP"
    grep -q 'Restore original allowed tools' "$RALPH_LOOP"
}

@test "codex loop auto-commits before QG retry" {
    grep -q 'pre-QG-retry auto-commit' "$CODEX_LOOP"
}

@test "devin loop auto-commits before QG retry" {
    grep -q 'pre-QG-retry auto-commit' "$DEVIN_LOOP"
}

# =============================================================================
# worktree_build_qg_fix_prompt exists in all engine copies
# =============================================================================

@test "worktree_build_qg_fix_prompt exists in lib/worktree_manager.sh" {
    grep -q 'worktree_build_qg_fix_prompt()' "$WORKTREE_MANAGER"
}

@test "worktree_build_qg_fix_prompt exists in codex/lib/worktree_manager.sh" {
    grep -q 'worktree_build_qg_fix_prompt()' "${BATS_TEST_DIRNAME}/../../codex/lib/worktree_manager.sh"
}

@test "worktree_build_qg_fix_prompt exists in devin/lib/worktree_manager.sh" {
    grep -q 'worktree_build_qg_fix_prompt()' "${BATS_TEST_DIRNAME}/../../devin/lib/worktree_manager.sh"
}
