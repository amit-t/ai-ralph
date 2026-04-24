#!/usr/bin/env bats
# Unit tests for lib/worktree_manager.sh fix_plan.md merge logic.
# Verifies the parallel-agent race fix: worktree_cleanup must not clobber
# [~]/[x] marks written to main fix_plan.md by sibling parallel agents after
# this worktree's snapshot was taken.

load '../helpers/test_helper'

TASK_SOURCES="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"
WORKTREE_MANAGER="${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    # shellcheck disable=SC1090
    source "$TASK_SOURCES"
    # shellcheck disable=SC1090
    source "$WORKTREE_MANAGER"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Build a 3-way scenario and run _merge_fix_plan_back.
# After: main_fp holds merged content.
_setup_3way() {
    local main_fp="main_fix_plan.md"
    local wt_fp="wt_fix_plan.md"
    local baseline="baseline_fix_plan.md"

    printf '%s\n' "$1" > "$baseline"
    printf '%s\n' "$2" > "$wt_fp"
    printf '%s\n' "$3" > "$main_fp"

    mkdir -p .lock_parent
    _merge_fix_plan_back "$wt_fp" "$main_fp" "$baseline"
}

@test "merge preserves sibling [~] when worktree completes its own task" {
    local baseline='# Fix Plan
- [~] **R01** first
- [ ] **R02** second
- [ ] **R03** third'

    local wt_final='# Fix Plan
- [x] **R01** first
- [ ] **R02** second
- [ ] **R03** third'

    local main_current='# Fix Plan
- [~] **R01** first
- [~] **R02** second
- [ ] **R03** third'

    _setup_3way "$baseline" "$wt_final" "$main_current"

    run cat main_fix_plan.md
    assert_success
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 should be [x] (worktree's update): $output"
    [[ "$output" == *"[~] **R02**"* ]] || fail "R02 must keep sibling [~] (not clobbered): $output"
    [[ "$output" == *"[ ] **R03**"* ]] || fail "R03 should stay [ ]: $output"
}

@test "merge does not regress [x] back to [~] when worktree still has [~]" {
    # Sibling completed R01 ([x]) while this worktree still shows [~].
    # Merging back must keep [x].
    local baseline='- [~] **R01** first
- [ ] **R02** second'

    local wt_final='- [~] **R01** first
- [x] **R02** second'

    local main_current='- [x] **R01** first
- [~] **R02** second'

    _setup_3way "$baseline" "$wt_final" "$main_current"

    run cat main_fix_plan.md
    assert_success
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 must stay [x]: $output"
    [[ "$output" == *"[x] **R02**"* ]] || fail "R02 becomes [x] from worktree: $output"
}

@test "merge preserves sibling-added tasks not present in worktree" {
    local baseline='- [~] **R01** first'
    local wt_final='- [x] **R01** first'
    local main_current='- [~] **R01** first
- [~] **R02** added-by-sibling'

    _setup_3way "$baseline" "$wt_final" "$main_current"

    run cat main_fix_plan.md
    assert_success
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 should be [x]: $output"
    [[ "$output" == *"**R02** added-by-sibling"* ]] || fail "sibling-added R02 must survive: $output"
}

@test "merge fast path: main unchanged since snapshot → plain copy" {
    local baseline='- [~] **R01** first
- [ ] **R02** second'
    local wt_final='- [x] **R01** first
- [ ] **R02** second'

    _setup_3way "$baseline" "$wt_final" "$baseline"

    run cat main_fix_plan.md
    assert_success
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 should be [x]: $output"
    [[ "$output" == *"[ ] **R02**"* ]] || fail "R02 should remain [ ]: $output"
}

@test "merge no-op when no main fix_plan.md exists yet" {
    printf '%s\n' '- [x] **R01** first' > wt_fix_plan.md
    printf '%s\n' '- [~] **R01** first' > baseline_fix_plan.md

    _merge_fix_plan_back wt_fix_plan.md main_fix_plan.md baseline_fix_plan.md

    [[ -f main_fix_plan.md ]] || fail "main_fix_plan.md should be created"
    run cat main_fix_plan.md
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 copied from worktree: $output"
}

@test "merge missing-baseline fallback: copies worktree to main" {
    # Legacy worktree without baseline file — preserve old behavior.
    printf '%s\n' '- [x] **R01** first' > wt_fix_plan.md
    printf '%s\n' '- [~] **R01** first
- [~] **R02** sibling' > main_fix_plan.md

    _merge_fix_plan_back wt_fix_plan.md main_fix_plan.md nonexistent_baseline.md

    run cat main_fix_plan.md
    assert_success
    # Without baseline we fall back to cp → sibling R02 is lost. Test documents
    # that behavior; new worktrees always have a baseline so this path only
    # runs for pre-upgrade worktrees.
    [[ "$output" == *"[x] **R01**"* ]] || fail "R01 should be [x]: $output"
}
