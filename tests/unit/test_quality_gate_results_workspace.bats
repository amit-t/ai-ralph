#!/usr/bin/env bats
# Unit tests: worktree_run_quality_gates must create the worktree's .ralph/
# directory before writing .quality_gate_results. In workspace continuous mode
# the per-repo worktree has no .ralph/ (the workspace root owns it), so the
# write produced:
#   worktree_manager.sh: line 604: <worktree>/.ralph/.quality_gate_results:
#     No such file or directory

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

    # Minimal repo so git commands in worktree_manager are happy.
    git init -q
    git config user.email t@e.com && git config user.name t
    echo "init" > a.txt && git add a.txt && git commit -qm init

    source "$REPO_ROOT/lib/worktree_manager.sh"

    # Worktree without .ralph/ — mirrors workspace per-repo worktree state.
    WORKTREE_NO_RALPH="$(mktemp -d)/wt"
    mkdir -p "$WORKTREE_NO_RALPH"
    # Force a known gate sequence — two no-op trues so the function exits clean.
    export WORKTREE_QUALITY_GATES="true ; true"
    export WORKTREE_GATE_TIMEOUT=5
}

teardown() {
    rm -rf "$TEST_DIR" "$WORKTREE_NO_RALPH"
}

@test "worktree_run_quality_gates: writes results file even when .ralph/ absent in worktree" {
    [ -d "$WORKTREE_NO_RALPH/.ralph" ] && skip "precondition: worktree must lack .ralph/"
    _WT_CURRENT_PATH="$WORKTREE_NO_RALPH"
    run worktree_run_quality_gates
    [ "$status" -eq 0 ]
    [ -f "$WORKTREE_NO_RALPH/.ralph/.quality_gate_results" ]
}

@test "worktree_run_quality_gates: no 'No such file' bash error on write" {
    [ -d "$WORKTREE_NO_RALPH/.ralph" ] && skip "precondition: worktree must lack .ralph/"
    _WT_CURRENT_PATH="$WORKTREE_NO_RALPH"
    local err
    err=$(worktree_run_quality_gates 2>&1 1>/dev/null)
    [[ "$err" != *".quality_gate_results: No such file or directory"* ]]
}
