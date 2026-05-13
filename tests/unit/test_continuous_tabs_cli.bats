#!/usr/bin/env bats
# CLI tests for the --no-tabs / --continuous-worker-id / --workspace-task flags
# added by the continuous-with-tabs proposal.
#
# See docs/proposals/continuous-with-tabs.md.

load '../helpers/test_helper'

RALPH_BIN="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
DEVIN_BIN="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
CODEX_BIN="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph
    : > .ralph/PROMPT.md
    : > .ralph/fix_plan.md
    # Disable tabs by default so the dispatch doesn't try to spawn anything.
    export RALPH_DISABLE_TABS=true
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# --no-tabs (Claude)
# =============================================================================

@test "claude --help documents --no-tabs" {
    run bash "$RALPH_BIN" --help
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q -- "--no-tabs"
    echo "$output" | grep -q "Force the single-pane orchestrator"
}

@test "claude --no-tabs parses cleanly with --parallel N M" {
    # We can't actually run continuous mode without a real environment, but
    # we can at least confirm the flag parses without producing an
    # "Unknown option" error. We trigger the dispatch and let it error on
    # missing CLI, which is fine — the parse stage must succeed first.
    run bash "$RALPH_BIN" --parallel 1 1 --no-tabs --help
    [[ "$status" -eq 0 ]]
}

@test "claude --no-tabs alone is accepted (does not require continuous mode)" {
    # The flag should be a no-op outside continuous mode. We pipe --help so
    # the parser doesn't fall through to main().
    run bash -c "echo '' | bash '$RALPH_BIN' --no-tabs --help"
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# --no-tabs (Devin)
# =============================================================================

@test "devin --help documents --no-tabs" {
    run bash "$DEVIN_BIN" --help
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q -- "--no-tabs"
}

@test "devin --no-tabs parses cleanly" {
    run bash "$DEVIN_BIN" --no-tabs --help
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# --no-tabs (Codex)
# =============================================================================

@test "codex --help documents --no-tabs" {
    run bash "$CODEX_BIN" --help
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q -- "--no-tabs"
}

@test "codex --no-tabs parses cleanly" {
    run bash "$CODEX_BIN" --no-tabs --help
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# --continuous-worker-id validation
# =============================================================================

@test "claude --continuous-worker-id requires a value" {
    run bash "$RALPH_BIN" --continuous-worker-id
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a worker id"
}

@test "claude --continuous-worker-id + --parallel N M is rejected" {
    run bash "$RALPH_BIN" --continuous-worker-id ws-1 --parallel 2 5
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "cannot be combined with --parallel N M"
}

@test "claude --continuous-worker-id + --parallel N (batch) is rejected" {
    run bash "$RALPH_BIN" --continuous-worker-id ws-1 --parallel 2
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "cannot be combined with --parallel N"
}

@test "claude --continuous-worker-id + --monitor is rejected" {
    run bash "$RALPH_BIN" --continuous-worker-id ws-1 --task R05 --monitor
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "cannot be combined with --monitor"
}

@test "claude --continuous-worker-id without --task or --workspace-task is rejected" {
    # No --task and no --workspace-task → must error before main runs.
    run bash "$RALPH_BIN" --continuous-worker-id ws-1
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "without --task or --workspace-task"
}

@test "devin --continuous-worker-id requires a value" {
    run bash "$DEVIN_BIN" --continuous-worker-id
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a worker id"
}

@test "codex --continuous-worker-id requires a value" {
    run bash "$CODEX_BIN" --continuous-worker-id
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a worker id"
}

# =============================================================================
# --workspace-task validation
# =============================================================================

@test "claude --workspace-task requires a descriptor" {
    run bash "$RALPH_BIN" --workspace-task
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a descriptor"
}

@test "devin --workspace-task requires a descriptor" {
    run bash "$DEVIN_BIN" --workspace-task
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a descriptor"
}

@test "codex --workspace-task requires a descriptor" {
    run bash "$CODEX_BIN" --workspace-task
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "requires a descriptor"
}

# =============================================================================
# Aliases reference --no-tabs
# =============================================================================

@test "rpc.p.notabs alias exists in main ALIASES.sh" {
    grep -q "rpc.p.notabs" "${BATS_TEST_DIRNAME}/../../ALIASES.sh"
}

@test "rpd.p.notabs alias exists in devin ALIASES.sh" {
    grep -q "rpd.p.notabs" "${BATS_TEST_DIRNAME}/../../devin/ALIASES.sh"
}

@test "rpx.p.notabs alias exists in codex ALIASES.sh" {
    grep -q "rpx.p.notabs" "${BATS_TEST_DIRNAME}/../../codex/ALIASES.sh"
}

@test "rpc.ws.p.notabs alias exists in main ALIASES.sh" {
    grep -q "rpc.ws.p.notabs" "${BATS_TEST_DIRNAME}/../../ALIASES.sh"
}

@test "rpd.ws.p.notabs alias exists in devin ALIASES.sh" {
    grep -q "rpd.ws.p.notabs" "${BATS_TEST_DIRNAME}/../../devin/ALIASES.sh"
}

@test "rpx.ws.p.notabs alias exists in codex ALIASES.sh" {
    grep -q "rpx.ws.p.notabs" "${BATS_TEST_DIRNAME}/../../codex/ALIASES.sh"
}
