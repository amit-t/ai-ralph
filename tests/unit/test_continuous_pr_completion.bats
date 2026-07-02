#!/usr/bin/env bats
# Continuous workspace executors must not mark a fix-plan row [x] when the
# push/PR pipeline reported failure (rc 2 from _workspace_execute_task) and
# the safety net could not salvage it.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"
    export LOG_DIR="${RALPH_DIR}/logs"
    printf -- '- [~] repo1 task one\n' > "${RALPH_DIR}/fix_plan.md"
    : > "${TEST_DIR}/.calls"
    log_status() { echo "[$1] $2"; }
    export -f log_status
}

teardown() { cd /; rm -rf "$TEST_DIR"; }

_load_fn() {  # $1=script $2=function name
    local fn_text
    fn_text=$(awk "/^$2\\(\\) \\{/,/^}/" "$1")
    [[ -n "$fn_text" ]] || fail "cannot extract $2 from $1"
    eval "$fn_text"
}

_mock_marking() {
    mark_workspace_task_complete() { echo marked >> "${TEST_DIR}/.calls"; }
    revert_workspace_task() { echo reverted >> "${TEST_DIR}/.calls"; }
    export -f mark_workspace_task_complete revert_workspace_task
}

# ── devin ─────────────────────────────────────────────────────────────────────

@test "devin ws executor: exec ok → marked complete even if safety net warns" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 0; }
    _workspace_push_and_pr()  { return 1; }   # branch-name guess miss — must not block
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

@test "devin ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    run grep -q marked "${TEST_DIR}/.calls"
    assert_failure
    grep -q reverted "${TEST_DIR}/.calls"
}

@test "devin ws executor: PR failed (rc 2), safety net salvages → marked complete" {
    _load_fn "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

# ── claude ────────────────────────────────────────────────────────────────────

@test "claude ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    run grep -q marked "${TEST_DIR}/.calls"
    assert_failure
}

@test "claude ws executor: PR failed (rc 2), safety net salvages → marked" {
    _load_fn "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}

# ── codex ─────────────────────────────────────────────────────────────────────

@test "codex ws executor: PR failed (rc 2), safety net fails → NOT marked, rc 1" {
    _load_fn "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 1; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_failure
    run grep -q marked "${TEST_DIR}/.calls"
    assert_failure
}

@test "codex ws executor: PR failed (rc 2), safety net salvages → marked" {
    _load_fn "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh" "_continuous_workspace_executor"
    _mock_marking
    _workspace_execute_task() { return 2; }
    _workspace_push_and_pr()  { return 0; }
    export -f _workspace_execute_task _workspace_push_and_pr
    run _continuous_workspace_executor "repo1|T-1|1|task one"
    assert_success
    grep -q marked "${TEST_DIR}/.calls"
}
