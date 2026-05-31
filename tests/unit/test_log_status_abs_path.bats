#!/usr/bin/env bats
# Unit tests: log_status must keep writing to the workspace-root log file even
# when called from a subshell that has cd'd into a worktree (or any other
# directory). Background: workspace continuous mode produced bash errors like
#   ralph_loop_devin.sh: line 313: .ralph/logs/ralph.log: No such file or directory
# because $LOG_DIR was relative ("$RALPH_DIR/logs") and resolved against the
# subshell CWD (a worktree without .ralph/logs/).

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    mkdir -p "$LOG_DIR"
    # Colour vars referenced by log_status
    export BLUE="" YELLOW="" RED="" GREEN="" PURPLE="" NC=""
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: extract log_status() definition from an engine script into a sourceable
# snippet so we can exercise it in isolation.
_load_log_status_from() {
    local script="$1"
    local tmp
    tmp="$(mktemp)"
    awk '/^log_status\(\) \{/,/^\}/' "$script" > "$tmp"
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"
}

@test "log_status (devin): writes to log file when CWD is workspace root" {
    _load_log_status_from "$REPO_ROOT/devin/ralph_loop_devin.sh"
    log_status "INFO" "hello-from-root"
    grep -q "hello-from-root" "$LOG_DIR/ralph.log"
}

@test "log_status (devin): no bash error when CWD changes to dir without .ralph/logs/" {
    _load_log_status_from "$REPO_ROOT/devin/ralph_loop_devin.sh"
    log_status "INFO" "prime-the-cache"
    local sub
    sub="$(mktemp -d)"
    # Run in a subshell that cds away; should NOT print a redirection error.
    local stderr
    stderr=$( (cd "$sub" && log_status "INFO" "from-subshell") 2>&1 1>/dev/null )
    rm -rf "$sub"
    [[ "$stderr" != *"No such file or directory"* ]]
}

@test "log_status (devin): subshell write lands in the original workspace log" {
    _load_log_status_from "$REPO_ROOT/devin/ralph_loop_devin.sh"
    log_status "INFO" "prime-the-cache"
    local sub
    sub="$(mktemp -d)"
    ( cd "$sub" && log_status "INFO" "from-subshell-marker" )
    rm -rf "$sub"
    grep -q "from-subshell-marker" "$LOG_DIR/ralph.log"
}

@test "log_status (codex): no bash error when CWD changes" {
    _load_log_status_from "$REPO_ROOT/codex/ralph_loop_codex.sh"
    log_status "INFO" "prime-the-cache"
    local sub
    sub="$(mktemp -d)"
    local stderr
    stderr=$( (cd "$sub" && log_status "INFO" "from-subshell") 2>&1 1>/dev/null )
    rm -rf "$sub"
    [[ "$stderr" != *"No such file or directory"* ]]
}

@test "log_status (claude): no bash error when CWD changes" {
    _load_log_status_from "$REPO_ROOT/ralph_loop.sh"
    log_status "INFO" "prime-the-cache"
    local sub
    sub="$(mktemp -d)"
    local stderr
    stderr=$( (cd "$sub" && log_status "INFO" "from-subshell") 2>&1 1>/dev/null )
    rm -rf "$sub"
    [[ "$stderr" != *"No such file or directory"* ]]
}
