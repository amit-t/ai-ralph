#!/usr/bin/env bats
# Integration tests for --continuous-worker-id worker mode in each engine.
# Verifies the engine sets up the completion-protocol trap and writes a
# completion JSON on exit, without needing real Claude/Devin/Codex CLIs.
#
# See docs/proposals/continuous-with-tabs.md.

load '../helpers/test_helper'

RALPH_BIN="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
DEVIN_BIN="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
CODEX_BIN="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "$RALPH_DIR/logs"
    : > "$RALPH_DIR/PROMPT.md"
    : > "$RALPH_DIR/fix_plan.md"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# Worker mode dispatch
# =============================================================================

@test "claude worker-mode without --task fails fast with helpful error" {
    run bash "$RALPH_BIN" --continuous-worker-id ws-test-1
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "without --task or --workspace-task"
}

@test "devin worker-mode without --task fails fast with helpful error" {
    run bash "$DEVIN_BIN" --continuous-worker-id ws-test-1
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "without --task or --workspace-task"
}

@test "codex worker-mode without --task fails fast with helpful error" {
    run bash "$CODEX_BIN" --continuous-worker-id ws-test-1
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "without --task or --workspace-task"
}

# =============================================================================
# Sources lib/worker_pool_tabs.sh
# =============================================================================

@test "ralph_loop.sh sources lib/worker_pool_tabs.sh" {
    grep -q 'source "$SCRIPT_DIR/lib/worker_pool_tabs.sh"' "$RALPH_BIN"
}

@test "ralph_loop_devin.sh sources lib/worker_pool_tabs.sh" {
    grep -q 'source "$RALPH_ROOT/lib/worker_pool_tabs.sh"' "$DEVIN_BIN"
}

@test "ralph_loop_codex.sh sources lib/worker_pool_tabs.sh" {
    grep -q 'source "$RALPH_ROOT/lib/worker_pool_tabs.sh"' "$CODEX_BIN"
}

# =============================================================================
# Worker-mode validation
# =============================================================================

@test "all 3 engines reject --continuous-worker-id + --parallel N M" {
    for bin in "$RALPH_BIN" "$DEVIN_BIN" "$CODEX_BIN"; do
        run bash "$bin" --continuous-worker-id ws-1 --parallel 2 5
        [[ "$status" -ne 0 ]] || {
            echo "Expected $bin to reject worker-id + continuous; got status=$status"
            false
        }
    done
}

@test "all 3 engines reject --continuous-worker-id + --parallel N (batch)" {
    for bin in "$RALPH_BIN" "$DEVIN_BIN" "$CODEX_BIN"; do
        run bash "$bin" --continuous-worker-id ws-1 --parallel 2
        [[ "$status" -ne 0 ]] || {
            echo "Expected $bin to reject worker-id + batch; got status=$status"
            false
        }
    done
}

# =============================================================================
# GC hook
# =============================================================================

@test "ralph_loop.sh calls gc_stale_continuous_artifacts at startup" {
    grep -q 'gc_stale_continuous_artifacts' "$RALPH_BIN"
}

@test "ralph_loop_devin.sh calls gc_stale_continuous_artifacts at startup" {
    grep -q 'gc_stale_continuous_artifacts' "$DEVIN_BIN"
}

@test "ralph_loop_codex.sh calls gc_stale_continuous_artifacts at startup" {
    grep -q 'gc_stale_continuous_artifacts' "$CODEX_BIN"
}

# =============================================================================
# Dispatch: tabs vs single-pane
# =============================================================================

@test "ralph_loop.sh dispatches to run_continuous_worker_pool_tabs when terminal supports tabs" {
    grep -q 'tabs_supported_by_terminal' "$RALPH_BIN"
    grep -q 'run_continuous_worker_pool_tabs' "$RALPH_BIN"
}

@test "ralph_loop_devin.sh dispatches to run_continuous_worker_pool_tabs" {
    grep -q 'tabs_supported_by_terminal' "$DEVIN_BIN"
    grep -q 'run_continuous_worker_pool_tabs' "$DEVIN_BIN"
}

@test "ralph_loop_codex.sh dispatches to run_continuous_worker_pool_tabs" {
    grep -q 'tabs_supported_by_terminal' "$CODEX_BIN"
    grep -q 'run_continuous_worker_pool_tabs' "$CODEX_BIN"
}

# =============================================================================
# RALPH_TABS_ENGINE_CMD per engine
# =============================================================================

@test "ralph_loop.sh sets RALPH_TABS_ENGINE_CMD=ralph" {
    grep -q 'RALPH_TABS_ENGINE_CMD="ralph"' "$RALPH_BIN"
}

@test "ralph_loop_devin.sh sets RALPH_TABS_ENGINE_CMD=ralph-devin" {
    grep -q 'RALPH_TABS_ENGINE_CMD="ralph-devin"' "$DEVIN_BIN"
}

@test "ralph_loop_codex.sh sets RALPH_TABS_ENGINE_CMD=ralph-codex" {
    grep -q 'RALPH_TABS_ENGINE_CMD="ralph-codex"' "$CODEX_BIN"
}
