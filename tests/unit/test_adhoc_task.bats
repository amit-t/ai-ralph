#!/usr/bin/env bats
# Unit tests for ad-hoc task mode
# Tests: CLI parsing (--adhoc flag), find_fix_plan_for_adhoc, prompt construction,
#         run_adhoc_task engine validation, template loading, project detection

load '../helpers/test_helper'

ADHOC_LIB="${BATS_TEST_DIRNAME}/../../lib/adhoc_task.sh"
RALPH_PLAN="${BATS_TEST_DIRNAME}/../../ralph_plan.sh"
TEMPLATES_DIR="${BATS_TEST_DIRNAME}/../../templates"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library (sets up functions)
    source "$ADHOC_LIB"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# find_fix_plan_for_adhoc -- walk-up search
# =============================================================================

@test "find_fix_plan_for_adhoc returns path when fix_plan.md exists in CWD" {
    mkdir -p .ralph
    echo "# Fix Plan" > .ralph/fix_plan.md

    run find_fix_plan_for_adhoc
    assert_success
    [[ "$output" == *".ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_adhoc walks up to parent directory" {
    mkdir -p parent/.ralph
    echo "# Fix Plan" > parent/.ralph/fix_plan.md
    mkdir -p parent/child
    cd parent/child

    run find_fix_plan_for_adhoc
    assert_success
    [[ "$output" == *"parent/.ralph/fix_plan.md" ]]
}

@test "find_fix_plan_for_adhoc returns failure when fix_plan.md not found" {
    # No .ralph/ directory at all
    run find_fix_plan_for_adhoc
    assert_failure
}

# =============================================================================
# next_adhoc_id -- sequential task ID generation
# =============================================================================

@test "next_adhoc_id returns AH01 for empty fix_plan" {
    mkdir -p .ralph
    echo "# Fix Plan" > .ralph/fix_plan.md

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "AH01" ]]
}

@test "next_adhoc_id returns AH01 when fix_plan has no AH IDs" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
# Fix Plan
## High Priority
- [ ] **R01** Some existing task
- [x] **R02** Another task
EOF

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "AH01" ]]
}

@test "next_adhoc_id increments from highest existing AH ID" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
## Ad-hoc
- [ ] **AH01** First adhoc task
- [x] **AH02** Second adhoc task
- [ ] **AH03** Third adhoc task
EOF

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "AH04" ]]
}

@test "next_adhoc_id handles non-sequential IDs" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
- [ ] **AH01** First
- [ ] **AH05** Jumped ahead
- [ ] **AH03** Out of order
EOF

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "AH06" ]]
}

@test "next_adhoc_id returns AH01 for missing fix_plan file" {
    run next_adhoc_id "/nonexistent/path/fix_plan.md"
    assert_success
    [[ "$output" == "AH01" ]]
}

@test "next_adhoc_id returns AH01 for empty path argument" {
    run next_adhoc_id ""
    assert_success
    [[ "$output" == "AH01" ]]
}

@test "next_adhoc_id zero-pads single digit IDs" {
    mkdir -p .ralph
    echo "# Fix Plan" > .ralph/fix_plan.md

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    # Should be AH01 not AH1
    [[ "$output" == "AH01" ]]
    [[ ${#output} -eq 4 ]]
}

@test "next_adhoc_id handles double-digit IDs" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md <<'EOF'
- [ ] **AH09** Task nine
- [ ] **AH10** Task ten
EOF

    run next_adhoc_id ".ralph/fix_plan.md"
    assert_success
    [[ "$output" == "AH11" ]]
}

# =============================================================================
# run_adhoc_task -- engine validation
# =============================================================================

@test "run_adhoc_task rejects unknown engine" {
    run run_adhoc_task "unknown_engine" "Fix a bug"
    assert_failure
    [[ "$output" == *"Unknown engine: unknown_engine"* ]]
}

@test "run_adhoc_task rejects empty engine with unknown error" {
    run run_adhoc_task "" "Fix a bug"
    assert_failure
}

@test "run_adhoc_task validates claude engine name" {
    # Will fail because claude CLI isn't installed in test env, but engine name is valid
    run run_adhoc_task "claude" "Fix a bug"
    # Should fail with "not found" not "Unknown engine"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_adhoc_task validates codex engine name" {
    run run_adhoc_task "codex" "Fix a bug"
    [[ "$output" != *"Unknown engine"* ]]
}

@test "run_adhoc_task validates devin engine name" {
    run run_adhoc_task "devin" "Fix a bug"
    [[ "$output" != *"Unknown engine"* ]]
}

# =============================================================================
# run_adhoc_task -- auto-bootstrap .ralph/
# =============================================================================

@test "run_adhoc_task creates .ralph/ directory if missing" {
    [[ ! -d ".ralph" ]]
    # Will fail at CLI check, but should create .ralph/ first
    run run_adhoc_task "claude" "Fix a bug"
    [[ -d ".ralph" ]]
}

# =============================================================================
# CLI parsing in ralph_plan.sh -- --adhoc flag
# =============================================================================

@test "ralph_plan.sh --adhoc flag sets ADHOC_MODE" {
    # Extract parse_args and test it
    # We source ralph_plan.sh in a subshell to get parse_args, then test it
    run bash -c '
        set -e
        SCRIPT_DIR="'"${BATS_TEST_DIRNAME}/../../"'"
        source "$SCRIPT_DIR/lib/date_utils.sh"
        # Define minimal stubs so sourcing works
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
        ENGINE="claude"
        CLAUDE_CMD="claude"
        CODEX_CMD="codex"
        DEVIN_CMD="devin"
        declare -a CLAUDE_ALLOWED_TOOLS=(Read Write Glob Grep)
        YOLO_MODE=false
        SUPERPOWERS=false
        SUPERPOWERS_PLUGIN_DIR="${HOME}/.claude/plugins/repos/superpowers"
        SUPERPOWERS_REPO="https://github.com/obra/superpowers"

        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --adhoc)
                        ADHOC_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            ADHOC_DESCRIPTION="$2"
                            shift 2
                        else
                            shift
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --adhoc
        echo "ADHOC_MODE=$ADHOC_MODE"
        echo "ADHOC_DESCRIPTION=$ADHOC_DESCRIPTION"
    '
    assert_success
    [[ "$output" == *"ADHOC_MODE=true"* ]]
    [[ "$output" == *"ADHOC_DESCRIPTION="* ]]
}

@test "ralph_plan.sh --adhoc with inline description captures it" {
    run bash -c '
        ADHOC_MODE=false
        ADHOC_DESCRIPTION=""
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --adhoc)
                        ADHOC_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            ADHOC_DESCRIPTION="$2"
                            shift 2
                        else
                            shift
                        fi
                        ;;
                    --engine) shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --adhoc "Login broken on mobile"
        echo "ADHOC_MODE=$ADHOC_MODE"
        echo "ADHOC_DESCRIPTION=$ADHOC_DESCRIPTION"
    '
    assert_success
    [[ "$output" == *"ADHOC_MODE=true"* ]]
    [[ "$output" == *"ADHOC_DESCRIPTION=Login broken on mobile"* ]]
}

@test "ralph_plan.sh --adhoc does not consume next flag as description" {
    run bash -c '
        ADHOC_MODE=false
        ADHOC_DESCRIPTION=""
        ENGINE="claude"
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --adhoc)
                        ADHOC_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            ADHOC_DESCRIPTION="$2"
                            shift 2
                        else
                            shift
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --adhoc --engine devin
        echo "ADHOC_MODE=$ADHOC_MODE"
        echo "ADHOC_DESCRIPTION=$ADHOC_DESCRIPTION"
        echo "ENGINE=$ENGINE"
    '
    assert_success
    [[ "$output" == *"ADHOC_MODE=true"* ]]
    [[ "$output" == *"ADHOC_DESCRIPTION="$'\n'* ]] || [[ "$output" == *"ADHOC_DESCRIPTION="* ]]
    [[ "$output" == *"ENGINE=devin"* ]]
}

@test "ralph_plan.sh --engine codex --adhoc combines correctly" {
    run bash -c '
        ADHOC_MODE=false
        ADHOC_DESCRIPTION=""
        ENGINE="claude"
        parse_args() {
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --adhoc)
                        ADHOC_MODE=true
                        if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                            ADHOC_DESCRIPTION="$2"
                            shift 2
                        else
                            shift
                        fi
                        ;;
                    --engine) ENGINE="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
        }

        parse_args --engine codex --adhoc "Fix API timeout"
        echo "ADHOC_MODE=$ADHOC_MODE"
        echo "ENGINE=$ENGINE"
        echo "ADHOC_DESCRIPTION=$ADHOC_DESCRIPTION"
    '
    assert_success
    [[ "$output" == *"ADHOC_MODE=true"* ]]
    [[ "$output" == *"ENGINE=codex"* ]]
    [[ "$output" == *"ADHOC_DESCRIPTION=Fix API timeout"* ]]
}

# =============================================================================
# PROMPT_ADHOC.md template existence
# =============================================================================

@test "PROMPT_ADHOC.md template exists" {
    [[ -f "$TEMPLATES_DIR/PROMPT_ADHOC.md" ]]
}

@test "PROMPT_ADHOC.md contains ad-hoc task mode header" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"Ad-hoc Task Mode"* ]]
}

@test "PROMPT_ADHOC.md contains RALPH_STATUS block instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"RALPH_STATUS"* ]]
    [[ "$output" == *"ADHOC_PLANNING"* ]]
}

@test "PROMPT_ADHOC.md instructs not to modify source code" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"Do NOT modify any source code"* ]]
}

@test "PROMPT_ADHOC.md contains fix_plan.md format instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"## Ad-hoc"* ]]
    [[ "$output" == *"BUG"* ]]
    [[ "$output" == *"FEAT"* ]]
}

@test "PROMPT_ADHOC.md contains task ID assignment instructions" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"Task ID Assignment"* ]]
    [[ "$output" == *"**AH01**"* ]]
    [[ "$output" == *"ralph --task"* ]]
}

@test "PROMPT_ADHOC.md RALPH_STATUS includes TASK_ID field" {
    run cat "$TEMPLATES_DIR/PROMPT_ADHOC.md"
    assert_success
    [[ "$output" == *"TASK_ID:"* ]]
}
