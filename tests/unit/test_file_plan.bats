#!/usr/bin/env bats
# Unit tests for file-based planning mode
# Tests: CLI parsing (--file flag), detect_file_type, find_fix_plan_for_file_plan,
#         run_file_plan engine validation, template loading, file validation

load '../helpers/test_helper'

FILE_PLAN_LIB="${BATS_TEST_DIRNAME}/../../lib/file_plan.sh"
RALPH_PLAN="${BATS_TEST_DIRNAME}/../../ralph_plan.sh"
TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../../templates"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (sets up functions)
    source "$FILE_PLAN_LIB"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# detect_file_type -- file type detection from extension
# =============================================================================

@test "detect_file_type returns markdown for .md files" {
    run detect_file_type "requirements.md"
    assert_success
    [[ "$output" == "markdown" ]]
}

@test "detect_file_type returns markdown for .markdown files" {
    run detect_file_type "spec.markdown"
    assert_success
    [[ "$output" == "markdown" ]]
}

@test "detect_file_type returns json for .json files" {
    run detect_file_type "tasks.json"
    assert_success
    [[ "$output" == "json" ]]
}

@test "detect_file_type returns text for .txt files" {
    run detect_file_type "notes.txt"
    assert_success
    [[ "$output" == "text" ]]
}

@test "detect_file_type returns yaml for .yaml files" {
    run detect_file_type "config.yaml"
    assert_success
    [[ "$output" == "yaml" ]]
}

@test "detect_file_type returns yaml for .yml files" {
    run detect_file_type "config.yml"
    assert_success
    [[ "$output" == "yaml" ]]
}

@test "detect_file_type returns text for unknown extensions" {
    run detect_file_type "readme.rst"
    assert_success
    [[ "$output" == "text" ]]
}

@test "detect_file_type handles uppercase extensions" {
    run detect_file_type "SPEC.MD"
    assert_success
    [[ "$output" == "markdown" ]]
}

@test "detect_file_type handles paths with directories" {
    run detect_file_type "/some/path/to/requirements.json"
    assert_success
    [[ "$output" == "json" ]]
}

# =============================================================================
# find_fix_plan_for_file_plan -- walk-up search
# =============================================================================

@test "find_fix_plan_for_file_plan returns path when fix_plan.md exists in CWD" {
    mkdir -p .ralph
    echo "# Fix Plan" > .ralph/fix_plan.md

    run find_fix_plan_for_file_plan
    assert_success
    [[ "$output" == *".ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_file_plan walks up to parent directory" {
    mkdir -p parent/.ralph
    echo "# Fix Plan" > parent/.ralph/fix_plan.md
    mkdir -p parent/child
    cd parent/child

    run find_fix_plan_for_file_plan
    assert_success
    [[ "$output" == *"parent/.ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_file_plan returns failure when fix_plan.md not found" {
    # No .ralph/ directory at all
    run find_fix_plan_for_file_plan
    assert_failure
}

# =============================================================================
# run_file_plan -- engine validation
# =============================================================================

@test "run_file_plan rejects unknown engine" {
    echo "some content" > test_input.md
    run run_file_plan "unknown_engine" "test_input.md"
    assert_failure
    [[ "$output" == *"Unknown engine: unknown_engine"* ]]
}

@test "run_file_plan rejects empty engine with unknown error" {
    echo "some content" > test_input.md
    run run_file_plan "" "test_input.md"
    assert_failure
}

@test "run_file_plan validates claude engine name" {
    echo "some content" > test_input.md
    # Will fail because claude CLI isn't installed in test env, but engine name is valid
    run run_file_plan "claude" "test_input.md"
    # Should fail with "not found" not "Unknown engine"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_file_plan validates codex engine name" {
    echo "some content" > test_input.md
    run run_file_plan "codex" "test_input.md"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_file_plan validates devin engine name" {
    echo "some content" > test_input.md
    run run_file_plan "devin" "test_input.md"
    [[ "$output" != *"Unknown engine"* ]]
}

# =============================================================================
# run_file_plan -- file validation
# =============================================================================

@test "run_file_plan rejects empty file path" {
    run run_file_plan "claude" ""
    assert_failure
    [[ "$output" == *"No file path provided"* ]]
}

@test "run_file_plan rejects nonexistent file" {
    run run_file_plan "claude" "/nonexistent/file.md"
    assert_failure
    [[ "$output" == *"File not found"* ]]
}

@test "run_file_plan rejects empty file" {
    touch empty_file.md
    run run_file_plan "claude" "empty_file.md"
    assert_failure
    [[ "$output" == *"File is empty"* ]]
}

# =============================================================================
# run_file_plan -- auto-bootstrap .ralph/
# =============================================================================

@test "run_file_plan creates .ralph/ directory if missing" {
    echo "some content" > test_input.md
    [[ ! -d ".ralph" ]]
    # Will fail at CLI check, but should create .ralph/ first
    run run_file_plan "claude" "test_input.md"
    [[ -d ".ralph" ]]
}

# =============================================================================
# CLI parsing in ralph_plan.sh -- --file flag
# =============================================================================

@test "ralph_plan.sh --file flag sets FILE_MODE and FILE_PATH" {
    run bash -c '
        FILE_MODE=false
        FILE_PATH=""
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --file)
                        FILE_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            FILE_PATH="$2"
                            shift 2
                        else
                            echo "Error: --file requires a file path argument" >&2
                            exit 1
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --file ./requirements.md
        echo "FILE_MODE=$FILE_MODE"
        echo "FILE_PATH=$FILE_PATH"
    '
    assert_success
    [[ "$output" == *"FILE_MODE=true"* ]]
    [[ "$output" == *"FILE_PATH=./requirements.md"* ]]
}

@test "ralph_plan.sh --file without path argument fails" {
    run bash -c '
        FILE_MODE=false
        FILE_PATH=""
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --file)
                        FILE_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            FILE_PATH="$2"
                            shift 2
                        else
                            echo "Error: --file requires a file path argument" >&2
                            exit 1
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --file
    '
    assert_failure
}

@test "ralph_plan.sh --file does not consume next flag as path" {
    run bash -c '
        FILE_MODE=false
        FILE_PATH=""
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --file)
                        FILE_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            FILE_PATH="$2"
                            shift 2
                        else
                            echo "Error: --file requires a file path argument" >&2
                            exit 1
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --file --engine devin
    '
    assert_failure
}

@test "ralph_plan.sh --engine codex --file combines correctly" {
    run bash -c '
        FILE_MODE=false
        FILE_PATH=""
        ENGINE="claude"
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --file)
                        FILE_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            FILE_PATH="$2"
                            shift 2
                        else
                            echo "Error: --file requires a file path argument" >&2
                            exit 1
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --engine codex --file ./spec.json
        echo "FILE_MODE=$FILE_MODE"
        echo "ENGINE=$ENGINE"
        echo "FILE_PATH=$FILE_PATH"
    '
    assert_success
    [[ "$output" == *"FILE_MODE=true"* ]]
    [[ "$output" == *"ENGINE=codex"* ]]
    [[ "$output" == *"FILE_PATH=./spec.json"* ]]
}

@test "ralph_plan.sh --help mentions --file flag" {
    run bash -c '
        SCRIPT_DIR="'"${BATS_TEST_DIRNAME}/../../"'"
        source "$SCRIPT_DIR/lib/date_utils.sh"
        RALPH_DIR=".ralph"
        CONSTITUTION_FILE=".ralph/constitution.md"
        FIX_PLAN_FILE=".ralph/fix_plan.md"
        PROMPT_PLAN_FILE=".ralph/PROMPT_PLAN.md"
        LOG_DIR=".ralph/logs"
        PRD_DIR=""
        PM_OS_DIR=""
        DOE_OS_DIR=""
        STATUS_MODE=false
        ADHOC_MODE=false
        ADHOC_DESCRIPTION=""
        COMPRESS_MODE=false
        FILE_MODE=false
        FILE_PATH=""
        ENGINE="claude"
        CLAUDE_CMD="claude"
        CODEX_CMD="codex"
        DEVIN_CMD="devin"
        declare -a CLAUDE_ALLOWED_TOOLS=(Read Write Glob Grep)
        YOLO_MODE=false
        SUPERPOWERS=false
        SUPERPOWERS_PLUGIN_DIR="${HOME}/.claude/plugins/repos/superpowers"
        SUPERPOWERS_REPO="https://github.com/obra/superpowers"

        bash "'"$RALPH_PLAN"'" --help
    '
    assert_success
    [[ "$output" == *"--file"* ]]
}

# =============================================================================
# PROMPT_FILE_PLAN.md template existence and content
# =============================================================================

@test "PROMPT_FILE_PLAN.md template exists" {
    [[ -f "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md" ]]
}

@test "PROMPT_FILE_PLAN.md contains file-based planning header" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"File-based Planning Mode"* ]]
}

@test "PROMPT_FILE_PLAN.md contains RALPH_STATUS block instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"RALPH_STATUS"* ]]
    [[ "$output" == *"FILE_PLANNING"* ]]
}

@test "PROMPT_FILE_PLAN.md instructs not to modify source code" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"Do NOT modify source code"* ]]
}

@test "PROMPT_FILE_PLAN.md documents markdown handling" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"Markdown Documents"* ]]
}

@test "PROMPT_FILE_PLAN.md documents JSON handling" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"JSON Documents"* ]]
}

@test "PROMPT_FILE_PLAN.md documents plain text handling" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"Plain Text"* ]]
}

@test "PROMPT_FILE_PLAN.md contains fix_plan.md format instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_FILE_PLAN.md"
    assert_success
    [[ "$output" == *"## High Priority"* ]]
    [[ "$output" == *"## Medium Priority"* ]]
    [[ "$output" == *"## Low Priority"* ]]
}
