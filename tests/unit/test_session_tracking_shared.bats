#!/usr/bin/env bats
# Unit tests for lib/session_tracking.sh — shared session-tracking helpers.
# Background: init_session_tracking / update_session_last_used used to live in
# ralph_loop.sh (Claude engine) only. devin/ralph_loop_devin.sh and
# codex/ralph_loop_codex.sh called them without defining them, producing
# "command not found" at runtime in workspace continuous mode.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    source "$REPO_ROOT/lib/date_utils.sh"
    source "$REPO_ROOT/lib/session_tracking.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "session_tracking: init/update functions are defined after sourcing" {
    declare -F init_session_tracking >/dev/null
    declare -F update_session_last_used >/dev/null
    declare -F generate_session_id >/dev/null
}

@test "session_tracking: init creates session file when RALPH_SESSION_FILE set" {
    export RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"
    run init_session_tracking
    [ "$status" -eq 0 ]
    [ -f "$RALPH_SESSION_FILE" ]
    jq -e '.session_id and .created_at and .last_used' "$RALPH_SESSION_FILE" >/dev/null
}

@test "session_tracking: init falls back to default path when RALPH_SESSION_FILE unset" {
    unset RALPH_SESSION_FILE
    run init_session_tracking
    [ "$status" -eq 0 ]
    [ -f "$RALPH_DIR/.ralph_session" ]
}

@test "session_tracking: update bumps last_used timestamp" {
    export RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"
    init_session_tracking
    local before
    before=$(jq -r '.last_used' "$RALPH_SESSION_FILE")
    sleep 1
    update_session_last_used
    local after
    after=$(jq -r '.last_used' "$RALPH_SESSION_FILE")
    [ "$before" != "$after" ]
}

@test "session_tracking: update no-ops when session file missing" {
    export RALPH_SESSION_FILE="$RALPH_DIR/.never_created"
    run update_session_last_used
    [ "$status" -eq 0 ]
    [ ! -f "$RALPH_SESSION_FILE" ]
}

@test "session_tracking: init recovers from corrupted session file" {
    export RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"
    echo "not json" > "$RALPH_SESSION_FILE"
    run init_session_tracking
    [ "$status" -eq 0 ]
    jq -e '.reset_reason == "corrupted_file_recovery"' "$RALPH_SESSION_FILE" >/dev/null
}

@test "session_tracking: devin engine sources session_tracking.sh" {
    grep -q 'lib/session_tracking.sh' "$REPO_ROOT/devin/ralph_loop_devin.sh"
}

@test "session_tracking: codex engine sources session_tracking.sh" {
    grep -q 'lib/session_tracking.sh' "$REPO_ROOT/codex/ralph_loop_codex.sh"
}

@test "session_tracking: claude engine sources session_tracking.sh" {
    grep -q 'lib/session_tracking.sh' "$REPO_ROOT/ralph_loop.sh"
}

@test "session_tracking: definitions removed from ralph_loop.sh body" {
    # The function bodies must live in lib/session_tracking.sh now, not duplicated
    # in ralph_loop.sh. Drift between copies was the root cause of the original bug.
    run grep -n '^init_session_tracking()' "$REPO_ROOT/ralph_loop.sh"
    [ "$status" -ne 0 ]
    run grep -n '^update_session_last_used()' "$REPO_ROOT/ralph_loop.sh"
    [ "$status" -ne 0 ]
}
