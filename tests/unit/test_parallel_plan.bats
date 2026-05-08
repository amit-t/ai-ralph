#!/usr/bin/env bats
# Unit + integration tests for ralph-plan --workspace --parallel-plan N
# Covers:
#   - --parallel-plan flag parsing (positive int, 0 / non-int errors)
#   - Reject outside --workspace mode
#   - Env var RALPH_PLAN_PARALLEL pickup, CLI wins over env
#   - Per-engine default opt-in (RALPH_PLAN_PARALLEL_USE_DEFAULTS=1)
#   - Cap at len(REPOS)
#   - Sequential output identical when N=1 (default)
#   - Parallel output equal to sequential output (mocked engine, deterministic)
#   - .plan-tmp cleanup on success
#   - .plan-tmp preserved on failure
#   - Orphan cleanup of dead-PID temp dirs

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
WORKSPACE_PLAN_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_plan.sh"
RALPH_PLAN_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_plan.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$WORKSPACE_PLAN_LIB" ]]; then
        source "$WORKSPACE_PLAN_LIB"
    fi

    unset RALPH_PLAN_PARALLEL RALPH_PLAN_PARALLEL_USE_DEFAULTS
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
    unset RALPH_PLAN_PARALLEL RALPH_PLAN_PARALLEL_USE_DEFAULTS
}

# Build a 3-repo workspace with deterministic mock outputs.
_setup_three_repo_ws() {
    mkdir -p ws/.ralph ws/svc-a/.git ws/svc-b/.git ws/svc-c/.git
    mkdir -p ws/svc-a/ai ws/svc-b/ai ws/svc-c/ai
    echo "PRD A" > ws/svc-a/ai/prd.md
    echo "PRD B" > ws/svc-b/ai/prd.md
    echo "PRD C" > ws/svc-c/ai/prd.md
    cat > ws/.ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## svc-a

## svc-b

## svc-c

## cross-repo
EOF
    mkdir -p mocks
    cat > mocks/svc-a.out.md << 'EOF'
## tasks
- Task A1
EOF
    cat > mocks/svc-b.out.md << 'EOF'
## tasks
- Task B1
EOF
    cat > mocks/svc-c.out.md << 'EOF'
## tasks
- Task C1
EOF
}

# =============================================================================
# CLI parsing
# =============================================================================

@test "ralph-plan --parallel-plan 0 ⇒ error" {
    _setup_three_repo_ws
    cd ws
    run bash "$RALPH_PLAN_SCRIPT" --workspace --parallel-plan 0
    assert_failure
    [[ "$output" == *"--parallel-plan must be >= 1"* ]]
}

@test "ralph-plan --parallel-plan -1 ⇒ error (non-integer pattern)" {
    _setup_three_repo_ws
    cd ws
    run bash "$RALPH_PLAN_SCRIPT" --workspace --parallel-plan -1
    assert_failure
    [[ "$output" == *"--parallel-plan must be a positive integer"* ]]
}

@test "ralph-plan --parallel-plan abc ⇒ error" {
    _setup_three_repo_ws
    cd ws
    run bash "$RALPH_PLAN_SCRIPT" --workspace --parallel-plan abc
    assert_failure
    [[ "$output" == *"--parallel-plan must be a positive integer"* ]]
}

@test "ralph-plan --parallel-plan rejected outside --workspace" {
    run bash "$RALPH_PLAN_SCRIPT" --parallel-plan 4
    assert_failure
    [[ "$output" == *"--parallel-plan only applies to --workspace mode"* ]]
}

# =============================================================================
# Sequential N=1 byte-identical to V1
# =============================================================================

@test "ralph-plan --workspace --parallel-plan 1 ⇒ same merged fix_plan as no flag" {
    _setup_three_repo_ws

    # Run 1: no flag
    cp -R ws ws_seq
    cd ws_seq
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success
    local seq_plan
    seq_plan=$(cat .ralph/fix_plan.md)
    cd ..

    # Run 2: --parallel-plan 1
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 1
    assert_success
    local n1_plan
    n1_plan=$(cat .ralph/fix_plan.md)

    [[ "$seq_plan" == "$n1_plan" ]]
}

# =============================================================================
# Parallel N>1 produces same merged plan as sequential
# =============================================================================

@test "ralph-plan --workspace --parallel-plan 3 ⇒ same merged fix_plan as N=1" {
    _setup_three_repo_ws

    cp -R ws ws_seq
    cd ws_seq
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success
    local seq_plan
    seq_plan=$(cat .ralph/fix_plan.md)
    cd ..

    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 3
    assert_success
    local par_plan
    par_plan=$(cat .ralph/fix_plan.md)

    [[ "$seq_plan" == "$par_plan" ]]
    # Banner should mention parallel
    [[ "$output" == *"parallel-plan N=3"* ]]
    [[ "$output" == *"Parallel-plan:       3 workers"* ]]
}

# =============================================================================
# Parallel section ordering stable
# =============================================================================

@test "ralph-plan --workspace --parallel-plan 3 ⇒ sections in REPO list order" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 3
    assert_success
    local plan
    plan=$(cat .ralph/fix_plan.md)
    # Order: svc-a < svc-b < svc-c (filesystem-sorted from discover_workspace_repos)
    local pa pb pc
    pa=$(echo "$plan" | grep -n '^## svc-a' | head -1 | cut -d: -f1)
    pb=$(echo "$plan" | grep -n '^## svc-b' | head -1 | cut -d: -f1)
    pc=$(echo "$plan" | grep -n '^## svc-c' | head -1 | cut -d: -f1)
    [[ "$pa" -lt "$pb" ]]
    [[ "$pb" -lt "$pc" ]]
}

# =============================================================================
# .plan-tmp cleanup on success
# =============================================================================

@test "parallel run cleans up .plan-tmp/<token>/ on success" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 3
    assert_success
    if [[ -d .ralph/.plan-tmp ]]; then
        local count
        count=$(find .ralph/.plan-tmp -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        [[ "$count" -eq 0 ]]
    fi
}

# =============================================================================
# Orphan cleanup
# =============================================================================

@test "parallel run sweeps orphan .plan-tmp dirs from dead PIDs on startup" {
    _setup_three_repo_ws
    # Pre-seed an orphan for a clearly-dead PID (1 is init; tmp dir we never spawn)
    mkdir -p ws/.ralph/.plan-tmp/9999999_1700000000000
    touch ws/.ralph/.plan-tmp/9999999_1700000000000/orphan.marker
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 3
    assert_success
    [[ ! -d .ralph/.plan-tmp/9999999_1700000000000 ]]
}

# =============================================================================
# Cap at len(REPOS)
# =============================================================================

@test "ralph-plan --parallel-plan 99 caps at REPO count silently" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 99
    assert_success
    [[ "$output" == *"parallel-plan N=3"* ]]
    [[ "$output" == *"Parallel-plan:       3 workers"* ]]
}

# =============================================================================
# Env var RALPH_PLAN_PARALLEL pickup
# =============================================================================

@test "RALPH_PLAN_PARALLEL=2 with no flag ⇒ effective N=2" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" RALPH_PLAN_PARALLEL=2 \
        run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success
    [[ "$output" == *"parallel-plan N=2"* ]]
}

@test "CLI --parallel-plan 3 wins over RALPH_PLAN_PARALLEL=2" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" RALPH_PLAN_PARALLEL=2 \
        run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude --parallel-plan 3
    assert_success
    [[ "$output" == *"parallel-plan N=3"* ]]
}

@test "RALPH_PLAN_PARALLEL=0 ⇒ error (must be positive integer)" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" RALPH_PLAN_PARALLEL=0 \
        run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_failure
    [[ "$output" == *"RALPH_PLAN_PARALLEL must be a positive integer"* ]]
}

# =============================================================================
# Per-engine default opt-in
# =============================================================================

@test "engine default: claude ⇒ 4 (capped at 3 for 3-repo ws) when USE_DEFAULTS=1" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" RALPH_PLAN_PARALLEL_USE_DEFAULTS=1 \
        run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success
    [[ "$output" == *"parallel-plan N=3"* ]]
}

@test "engine default OFF without opt-in ⇒ N=1 (no banner)" {
    _setup_three_repo_ws
    cd ws
    RALPH_PLAN_WS_MOCK_DIR="$TEST_DIR/mocks" \
        run bash "$RALPH_PLAN_SCRIPT" --workspace --engine claude
    assert_success
    [[ "$output" != *"parallel-plan N="* ]]
}
