#!/usr/bin/env bats
# Unit tests for codex/lib/codex_adapter.sh — command building against the REAL
# (clap-based) Codex CLI.
#
# Background: the adapter was originally written against a fictional, Claude-
# shaped `codex` CLI and emitted flags the real CLI rejects (e.g.
# `--permission-mode`, `--prompt-file`, `-p`, `-r`), producing:
#   error: unexpected argument '--permission-mode' found
# These tests pin the constructed argv to the real interface:
#   codex exec [resume <id>] --json [--model M] [<sandbox>] "<prompt>"

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # CODEX_CMD is overridden so no real binary is required for arg-building.
    source "$REPO_ROOT/codex/lib/codex_adapter.sh"
    CODEX_CMD="codex"
    PROMPT_FILE="$TEST_DIR/PROMPT.md"
    printf 'Do the task.\n' > "$PROMPT_FILE"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: true if $1 appears as an element of CODEX_CMD_ARGS
args_contains() {
    local needle="$1" a
    for a in "${CODEX_CMD_ARGS[@]}"; do
        [[ "$a" == "$needle" ]] && return 0
    done
    return 1
}

@test "codex_adapter: functions defined after sourcing" {
    declare -F build_codex_command >/dev/null
    declare -F check_codex_cli >/dev/null
    declare -F codex_extract_session_id >/dev/null
    declare -F codex_get_latest_session_id >/dev/null
    declare -F codex_list_sessions >/dev/null
}

@test "build: fresh non-interactive starts with 'codex exec' and is --json" {
    CODEX_PERMISSION_MODE=dangerous CODEX_MODEL="" \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    assert_equal "${CODEX_CMD_ARGS[0]}" "codex"
    assert_equal "${CODEX_CMD_ARGS[1]}" "exec"
    args_contains "--json"
}

@test "build: NEVER emits fictional Claude-shaped flags" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    ! args_contains "--permission-mode"
    ! args_contains "--prompt-file"
    ! args_contains "-p"
    ! args_contains "-r"
}

@test "build: dangerous mode emits bypass flag (no sandbox -s)" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    args_contains "--dangerously-bypass-approvals-and-sandbox"
    ! args_contains "-s"
}

@test "build: auto mode maps to '-s workspace-write' on a fresh session" {
    CODEX_PERMISSION_MODE=auto \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    args_contains "-s"
    args_contains "workspace-write"
    ! args_contains "--dangerously-bypass-approvals-and-sandbox"
}

@test "build: model is passed via --model" {
    CODEX_PERMISSION_MODE=auto CODEX_MODEL="gpt-5-codex" \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    args_contains "--model"
    args_contains "gpt-5-codex"
}

@test "build: resume uses 'exec resume <id>' subcommand, not -r" {
    local sid="019ef756-d51f-73f0-a4b4-94abb6a32d5c"
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "$sid" "true" ""
    assert_equal "${CODEX_CMD_ARGS[1]}" "exec"
    assert_equal "${CODEX_CMD_ARGS[2]}" "resume"
    assert_equal "${CODEX_CMD_ARGS[3]}" "$sid"
    ! args_contains "-r"
}

@test "build: resume in auto mode omits -s (exec resume rejects it)" {
    local sid="019ef756-d51f-73f0-a4b4-94abb6a32d5c"
    CODEX_PERMISSION_MODE=auto \
        build_codex_command "$PROMPT_FILE" "" "$sid" "true" ""
    ! args_contains "-s"
    ! args_contains "workspace-write"
}

@test "build: resume in dangerous mode still emits bypass flag" {
    local sid="019ef756-d51f-73f0-a4b4-94abb6a32d5c"
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "$sid" "true" ""
    args_contains "--dangerously-bypass-approvals-and-sandbox"
}

@test "build: interactive (print_mode=false) fresh is bare 'codex', no exec/--json" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "" "false" ""
    assert_equal "${CODEX_CMD_ARGS[0]}" "codex"
    [ "${CODEX_CMD_ARGS[1]}" != "exec" ]
    ! args_contains "--json"
    ! args_contains "--dangerously-bypass-approvals-and-sandbox"
}

@test "build: interactive resume is 'codex resume <id>'" {
    local sid="019ef756-d51f-73f0-a4b4-94abb6a32d5c"
    build_codex_command "$PROMPT_FILE" "" "$sid" "false" ""
    assert_equal "${CODEX_CMD_ARGS[1]}" "resume"
    assert_equal "${CODEX_CMD_ARGS[2]}" "$sid"
}

@test "build: prompt text is the final positional argument" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "" "true" ""
    local last="${CODEX_CMD_ARGS[${#CODEX_CMD_ARGS[@]}-1]}"
    [[ "$last" == *"Do the task."* ]]
}

@test "build: worktree directive is prepended ahead of the prompt body" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "" "" "true" "WORKDIR: stay in /x"
    local last="${CODEX_CMD_ARGS[${#CODEX_CMD_ARGS[@]}-1]}"
    [[ "$last" == "WORKDIR: stay in /x"* ]]
    [[ "$last" == *"Do the task."* ]]
}

@test "build: loop context is appended to the prompt body" {
    CODEX_PERMISSION_MODE=dangerous \
        build_codex_command "$PROMPT_FILE" "loop=3" "" "true" ""
    local last="${CODEX_CMD_ARGS[${#CODEX_CMD_ARGS[@]}-1]}"
    [[ "$last" == *"RALPH LOOP CONTEXT: loop=3"* ]]
}

@test "build: missing prompt file returns non-zero" {
    run build_codex_command "$TEST_DIR/nope.md" "" "" "true" ""
    assert_failure
}

@test "extract: pulls thread_id from --json output" {
    local f="$TEST_DIR/out.jsonl"
    printf '%s\n' '{"type":"thread.started","thread_id":"019ef75a-b356-7dc2-a550-f9b155282a4b"}' > "$f"
    printf '%s\n' '{"type":"turn.completed"}' >> "$f"
    run codex_extract_session_id "$f"
    assert_success
    assert_output "019ef75a-b356-7dc2-a550-f9b155282a4b"
}

@test "extract: tolerates terminal noise around the JSON line" {
    local f="$TEST_DIR/out.jsonl"
    printf '\033[2mnoise\033[0m {"type":"thread.started","thread_id":"019ef75a-b356-7dc2-a550-f9b155282a4b"} trailing\n' > "$f"
    run codex_extract_session_id "$f"
    assert_success
    assert_output "019ef75a-b356-7dc2-a550-f9b155282a4b"
}

@test "extract: returns non-zero when no id present" {
    local f="$TEST_DIR/out.jsonl"
    printf '%s\n' '{"type":"turn.completed"}' > "$f"
    run codex_extract_session_id "$f"
    assert_failure
}

@test "latest/list: read UUIDs from the rollout store" {
    export CODEX_HOME="$TEST_DIR/.codex"
    local d="$CODEX_HOME/sessions/2026/06/24"
    mkdir -p "$d"
    local sid="019ef75a-b356-7dc2-a550-f9b155282a4b"
    printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"$sid\"}}" \
        > "$d/rollout-2026-06-24T07-25-23-$sid.jsonl"
    # Re-source so CODEX_SESSIONS_DIR picks up the overridden CODEX_HOME.
    source "$REPO_ROOT/codex/lib/codex_adapter.sh"
    run codex_get_latest_session_id
    assert_success
    assert_output "$sid"
    run codex_list_sessions 5
    assert_success
    assert_output "$sid"
}
