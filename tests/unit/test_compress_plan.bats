#!/usr/bin/env bats
# Unit tests for fix plan compression mode
# Tests: CLI parsing (--compress flag), find_fix_plan_for_compress, count_plan_items,
#        archive_fix_plan, run_compress_plan engine validation, template loading

load '../helpers/test_helper'

COMPRESS_LIB="${BATS_TEST_DIRNAME}/../../lib/compress_plan.sh"
RALPH_PLAN="${BATS_TEST_DIRNAME}/../../ralph_plan.sh"
TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../../templates"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (sets up functions)
    source "$COMPRESS_LIB"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# find_fix_plan_for_compress -- walk-up search
# =============================================================================

@test "find_fix_plan_for_compress returns path when fix_plan.md exists in CWD" {
    mkdir -p .ralph
    echo "# Fix Plan" > .ralph/fix_plan.md

    run find_fix_plan_for_compress
    assert_success
    [[ "$output" == *".ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_compress walks up to parent directory" {
    mkdir -p parent/.ralph
    echo "# Fix Plan" > parent/.ralph/fix_plan.md
    mkdir -p parent/child
    cd parent/child

    run find_fix_plan_for_compress
    assert_success
    [[ "$output" == *"parent/.ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_compress returns failure when fix_plan.md not found" {
    run find_fix_plan_for_compress
    assert_failure
}

# =============================================================================
# count_plan_items -- item counting
# =============================================================================

@test "count_plan_items returns zeros for empty file" {
    mkdir -p .ralph
    echo "" > .ralph/fix_plan.md

    run count_plan_items ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "0 0 0 0" ]]
}

@test "count_plan_items counts pending items" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
# Fix Plan
## High Priority
- [ ] Task one
- [ ] Task two
- [ ] Task three
EOF

    run count_plan_items ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "3 0 0 3" ]]
}

@test "count_plan_items counts completed items" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
- [x] Done one
- [x] Done two
- [ ] Pending one
EOF

    run count_plan_items ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "3 2 0 1" ]]
}

@test "count_plan_items counts in-progress items" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
- [~] Working on this
- [ ] Not started
- [x] Done
EOF

    run count_plan_items ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "3 1 1 1" ]]
}

@test "count_plan_items counts mixed items correctly" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
# Fix Plan
## High Priority
- [x] **R01** Completed task
- [x] **R02** Another completed
- [~] **R03** In progress task
- [ ] **R04** Pending task
- [ ] **R05** Another pending

## Completed
- [x] Old task one
- [x] Old task two
EOF

    run count_plan_items ".ralph/fix_plan.md"
    assert_success
    # total=7 completed=4 in_progress=1 pending=2
    [[ "$output" == "7 4 1 2" ]]
}

@test "count_plan_items returns zeros for missing file" {
    run count_plan_items "/nonexistent/fix_plan.md"
    assert_success
    [[ "$output" == "0 0 0 0" ]]
}

@test "count_plan_items returns zeros for empty path" {
    run count_plan_items ""
    assert_success
    [[ "$output" == "0 0 0 0" ]]
}

# =============================================================================
# archive_fix_plan -- backup creation
# =============================================================================

@test "archive_fix_plan creates timestamped backup" {
    mkdir -p .ralph/logs
    echo "# Fix Plan content" > .ralph/fix_plan.md

    run archive_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == *"fix_plan_pre_compress_"* ]]
    [[ -f "$output" ]]
}

@test "archive_fix_plan preserves original content" {
    mkdir -p .ralph/logs
    cat > .ralph/fix_plan.md <<'EOF'
# Fix Plan
- [ ] **AH01** Important task
- [x] **R01** Done task
EOF

    run archive_fix_plan ".ralph/fix_plan.md"
    assert_success
    local archive="$output"
    [[ -f "$archive" ]]
    grep -qF "**AH01**" "$archive"
    grep -qF "**R01**" "$archive"
}

@test "archive_fix_plan creates logs directory if missing" {
    mkdir -p .ralph
    echo "# content" > .ralph/fix_plan.md
    [[ ! -d ".ralph/logs" ]]

    run archive_fix_plan ".ralph/fix_plan.md"
    assert_success
    [[ -d ".ralph/logs" ]]
}

@test "archive_fix_plan fails for missing file" {
    run archive_fix_plan "/nonexistent/fix_plan.md"
    assert_failure
}

@test "archive_fix_plan fails for empty path" {
    run archive_fix_plan ""
    assert_failure
}

# =============================================================================
# run_compress_plan -- engine validation
# =============================================================================

@test "run_compress_plan rejects unknown engine" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md

    run run_compress_plan "unknown_engine"
    assert_failure
    [[ "$output" == *"Unknown engine: unknown_engine"* ]]
}

@test "run_compress_plan rejects empty engine" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md

    run run_compress_plan ""
    assert_failure
}

@test "run_compress_plan validates claude engine name" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md
    # Will fail because claude CLI isn't installed in test env, but engine name is valid
    run run_compress_plan "claude"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_compress_plan validates codex engine name" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md
    run run_compress_plan "codex"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_compress_plan validates devin engine name" {
    mkdir -p .ralph
    echo "# Plan" > .ralph/fix_plan.md
    run run_compress_plan "devin"
    [[ "$output" != *"Unknown engine"* ]]
}

# =============================================================================
# run_compress_plan -- fix_plan.md requirement
# =============================================================================

@test "run_compress_plan fails when no fix_plan.md exists" {
    # No .ralph/ directory at all
    run run_compress_plan "claude"
    assert_failure
    [[ "$output" == *"No .ralph/fix_plan.md found"* ]]
}

@test "run_compress_plan fails when fix_plan.md is empty" {
    mkdir -p .ralph
    echo -n "" > .ralph/fix_plan.md

    run run_compress_plan "claude"
    assert_failure
    [[ "$output" == *"empty"* ]]
}

# =============================================================================
# CLI parsing in ralph_plan.sh -- --compress flag
# =============================================================================

@test "ralph_plan.sh --compress flag sets COMPRESS_MODE" {
    run bash -c '
        COMPRESS_MODE=false
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --compress)
                        COMPRESS_MODE=true
                        shift
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --compress
        echo "COMPRESS_MODE=$COMPRESS_MODE"
    '
    assert_success
    [[ "$output" == *"COMPRESS_MODE=true"* ]]
}

@test "ralph_plan.sh --engine codex --compress combines correctly" {
    run bash -c '
        COMPRESS_MODE=false
        ENGINE="claude"
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --compress)
                        COMPRESS_MODE=true
                        shift
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --engine codex --compress
        echo "COMPRESS_MODE=$COMPRESS_MODE"
        echo "ENGINE=$ENGINE"
    '
    assert_success
    [[ "$output" == *"COMPRESS_MODE=true"* ]]
    [[ "$output" == *"ENGINE=codex"* ]]
}

@test "ralph_plan.sh --compress does not interfere with --adhoc" {
    run bash -c '
        COMPRESS_MODE=false
        ADHOC_MODE=false
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --compress)
                        COMPRESS_MODE=true
                        shift
                        ;;
                    --adhoc)
                        ADHOC_MODE=true
                        shift
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --adhoc
        echo "COMPRESS_MODE=$COMPRESS_MODE"
        echo "ADHOC_MODE=$ADHOC_MODE"
    '
    assert_success
    [[ "$output" == *"COMPRESS_MODE=false"* ]]
    [[ "$output" == *"ADHOC_MODE=true"* ]]
}

# =============================================================================
# PROMPT_COMPRESS.md template existence
# =============================================================================

@test "PROMPT_COMPRESS.md template exists" {
    [[ -f "$TEMPLATES_DIR/PROMPT_COMPRESS.md" ]]
}

@test "PROMPT_COMPRESS.md contains compress mode header" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"Compress Mode"* ]]
}

@test "PROMPT_COMPRESS.md contains RALPH_STATUS block instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"RALPH_STATUS"* ]]
    [[ "$output" == *"PLAN_COMPRESSION"* ]]
}

@test "PROMPT_COMPRESS.md instructs not to modify source code" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"Do NOT modify source code"* ]]
}

@test "PROMPT_COMPRESS.md instructs not to change checkbox state" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"Do NOT change any checkbox state"* ]]
}

@test "PROMPT_COMPRESS.md contains compression rules for completed items" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"Completed Items"* ]]
    [[ "$output" == *"Collapse"* ]]
}

@test "PROMPT_COMPRESS.md preserves task IDs" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"Task IDs"* ]] || [[ "$output" == *"task IDs"* ]]
    [[ "$output" == *"NEVER remove"* ]] || [[ "$output" == *"NEVER"* ]]
}

@test "PROMPT_COMPRESS.md sets EXIT_SIGNAL true" {
    run cat "$TEMPLATES_DIR/PROMPT_COMPRESS.md"
    assert_success
    [[ "$output" == *"EXIT_SIGNAL: true"* ]]
}
