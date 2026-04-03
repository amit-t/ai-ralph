#!/usr/bin/env bats
# Unit tests for quality gate behaviour
# Tests: worktree_build_qg_fix_prompt, MAX_QG_RETRIES config, --qg mode, PR-on-failure

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
# Main loop: no inline QG retry — gates run once, PR always created
# =============================================================================

@test "ralph_loop.sh main loop does NOT have inline QG retry while-loop" {
    # The main execute_claude_code function should NOT contain the old retry loop
    # Only run_qg_mode should have it
    local inline_retry_count
    inline_retry_count=$(sed -n '/^execute_claude_code/,/^[^ ]/p' "$RALPH_LOOP" | grep -c 'qg_attempt -lt' || true)
    [[ "$inline_retry_count" -eq 0 ]]
}

@test "codex loop does NOT have inline QG retry while-loop" {
    ! grep -q 'qg_attempt -lt' "$CODEX_LOOP"
}

@test "devin loop does NOT have inline QG retry while-loop" {
    ! grep -q 'qg_attempt -lt' "$DEVIN_LOOP"
}

@test "ralph_loop.sh main loop creates PR when quality gates fail" {
    grep -q 'Quality gates failed.*creating PR with failure details' "$RALPH_LOOP"
}

@test "codex loop creates PR when quality gates fail" {
    grep -q 'Quality gates failed.*creating PR with failure details' "$CODEX_LOOP"
}

@test "devin loop creates PR when quality gates fail" {
    grep -q 'Quality gates failed.*creating PR with failure details' "$DEVIN_LOOP"
}

@test "ralph_loop.sh main loop runs quality gates once (no retry)" {
    # In the worktree PR section, worktree_run_quality_gates appears exactly once
    local count
    count=$(sed -n '/quality gates.*commit.*push.*PR/,/worktree_cleanup/p' "$RALPH_LOOP" | grep -c 'worktree_run_quality_gates' || true)
    [[ $count -eq 1 ]]
}

# =============================================================================
# ralph --qg standalone mode
# =============================================================================

@test "ralph_loop.sh has run_qg_mode function" {
    grep -q 'run_qg_mode()' "$RALPH_LOOP"
}

@test "ralph_loop.sh --qg flag sets QG_MODE=true" {
    grep -q -- '--qg)' "$RALPH_LOOP"
    grep -q 'QG_MODE=true' "$RALPH_LOOP"
}

@test "ralph_loop.sh dispatches to run_qg_mode when QG_MODE=true" {
    grep -q 'QG_MODE.*true.*run_qg_mode\|run_qg_mode' "$RALPH_LOOP"
}

@test "run_qg_mode has QG fix retry loop with MAX_QG_RETRIES" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    echo "$qg_section" | grep -q 'qg_attempt -lt.*MAX_QG_RETRIES\|qg_attempt -lt \$MAX_QG_RETRIES'
}

@test "run_qg_mode calls worktree_build_qg_fix_prompt" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    echo "$qg_section" | grep -q 'worktree_build_qg_fix_prompt'
}

@test "run_qg_mode re-runs quality gates after each fix attempt" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    local count
    count=$(echo "$qg_section" | grep -c 'worktree_run_quality_gates')
    [[ $count -ge 2 ]]  # initial run + retry
}

@test "run_qg_mode auto-commits before QG fix" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    echo "$qg_section" | grep -q 'QG fix auto-commit'
}

@test "run_qg_mode enables Task tool for QG fix subagents" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    echo "$qg_section" | grep -q 'CLAUDE_ALLOWED_TOOLS.*Task\|Task'
}

@test "run_qg_mode saves and restores CLAUDE_ALLOWED_TOOLS" {
    local qg_section
    qg_section=$(sed -n '/^run_qg_mode()/,/^}/p' "$RALPH_LOOP")
    echo "$qg_section" | grep -q '_saved_allowed_tools'
    echo "$qg_section" | grep -q 'Restore original allowed tools'
}

@test "ralph_loop.sh --qg appears in help text" {
    grep -q -- '--qg' "$RALPH_LOOP"
    grep -q 'Quality Gate Mode' "$RALPH_LOOP"
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
