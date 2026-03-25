#!/bin/bash
# Tests for lib/fix_plan_status.sh

TESTS_PASSED=0
TESTS_FAILED=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local name="$1"; local expected="$2"; local actual="$3"
    echo -e "\n${YELLOW}Test: $name${NC}"
    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL — expected: '$expected', got: '$actual'${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/fix_plan_status.sh"

# ── find_fix_plan: found in CWD ───────────────────────────────────────────────
test_find_in_cwd() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.ralph"
    echo "# Fix Plan" > "$tmp_dir/.ralph/fix_plan.md"

    local result exit_code
    result=$(cd "$tmp_dir" && find_fix_plan); exit_code=$?

    run_test "find_fix_plan: found in CWD returns correct path" \
        "$tmp_dir/.ralph/fix_plan.md" "$result"
    run_test "find_fix_plan: found in CWD exits 0" \
        "0" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── find_fix_plan: found one level up ────────────────────────────────────────
test_find_one_level_up() {
    local tmp_dir child_dir
    tmp_dir=$(mktemp -d)
    child_dir="$tmp_dir/subproject"
    mkdir -p "$child_dir"
    mkdir -p "$tmp_dir/.ralph"
    echo "# Fix Plan" > "$tmp_dir/.ralph/fix_plan.md"

    local result exit_code
    result=$(cd "$child_dir" && find_fix_plan); exit_code=$?

    run_test "find_fix_plan: found one level up returns correct path" \
        "$tmp_dir/.ralph/fix_plan.md" "$result"
    run_test "find_fix_plan: found one level up exits 0" \
        "0" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── find_fix_plan: not found anywhere ────────────────────────────────────────
test_find_not_found() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local exit_code
    (cd "$tmp_dir" && find_fix_plan > /dev/null 2>&1); exit_code=$?

    run_test "find_fix_plan: not found exits 1" \
        "1" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── show_fix_plan_status: unknown engine ──────────────────────────────────────
test_unknown_engine() {
    local exit_code
    (show_fix_plan_status "badengine" 2>/dev/null); exit_code=$?
    run_test "show_fix_plan_status: unknown engine exits 1" \
        "1" "$exit_code"
}

# ── show_fix_plan_status: engine CLI missing ──────────────────────────────────
test_engine_cli_missing() {
    # Override command to simulate missing CLI
    local exit_code
    (
        command() { return 1; }
        show_fix_plan_status "claude" 2>/dev/null
    ); exit_code=$?
    run_test "show_fix_plan_status: missing CLI exits 1" \
        "1" "$exit_code"
}

test_find_in_cwd
test_find_one_level_up
test_find_not_found
test_unknown_engine
test_engine_cli_missing

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]]
