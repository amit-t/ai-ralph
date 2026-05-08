#!/usr/bin/env bats
# Unit tests for workspace --repos / --exclude filter
# Covers:
#   - resolve_workspace_filter_spec (CLI vs env, mutual exclusion, trimming)
#   - is_workspace_filter_active
#   - discover_workspace_repos_filtered (allowlist, denylist, unknown-name error,
#     empty-result error, no-filter pass-through)
#   - pick_workspace_task / pick_workspace_tasks_parallel honor allowed_repos
#   - get_workspace_parallel_limit honors allowed_repos
#   - ralph_loop.sh CLI: --repos / --exclude parse, mutual exclusion,
#     workspace-only enforcement
#   - validate_workspace honors filter (no warn for excluded plan repos)

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi

    # Reset filter env so tests do not bleed into one another.
    unset RALPH_WORKSPACE_REPOS RALPH_WORKSPACE_EXCLUDE
    unset RALPH_WORKSPACE_REPOS_RESOLVED RALPH_WORKSPACE_EXCLUDE_RESOLVED
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
    unset RALPH_WORKSPACE_REPOS RALPH_WORKSPACE_EXCLUDE
    unset RALPH_WORKSPACE_REPOS_RESOLVED RALPH_WORKSPACE_EXCLUDE_RESOLVED
}

# Helper: scaffold a 3-repo workspace (alpha, beta, gamma) with one pending
# task each and a cross-repo task. Avoids real git init — only .git/ marker
# directories are required by discover_workspace_repos.
_setup_three_repo_workspace() {
    mkdir -p alpha/.git beta/.git gamma/.git
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## alpha
- [ ] Task A1 for alpha

## beta
- [ ] Task B1 for beta

## gamma
- [ ] Task G1 for gamma

## cross-repo
- [ ] Cross-repo task touching alpha and beta
EOF
}

# =============================================================================
# resolve_workspace_filter_spec
# =============================================================================

@test "resolve_workspace_filter_spec: empty inputs ⇒ empty resolved" {
    run resolve_workspace_filter_spec "" ""
    assert_success
    [[ -z "${RALPH_WORKSPACE_REPOS_RESOLVED:-}" ]]
    [[ -z "${RALPH_WORKSPACE_EXCLUDE_RESOLVED:-}" ]]
}

@test "resolve_workspace_filter_spec: CLI --repos populates resolved allowlist" {
    resolve_workspace_filter_spec "alpha,beta" ""
    [[ "$RALPH_WORKSPACE_REPOS_RESOLVED" == $'alpha\nbeta' ]]
    [[ -z "$RALPH_WORKSPACE_EXCLUDE_RESOLVED" ]]
}

@test "resolve_workspace_filter_spec: trims whitespace around commas" {
    resolve_workspace_filter_spec " alpha , beta " ""
    [[ "$RALPH_WORKSPACE_REPOS_RESOLVED" == $'alpha\nbeta' ]]
}

@test "resolve_workspace_filter_spec: drops empty tokens" {
    resolve_workspace_filter_spec "alpha,,beta" ""
    [[ "$RALPH_WORKSPACE_REPOS_RESOLVED" == $'alpha\nbeta' ]]
}

@test "resolve_workspace_filter_spec: --repos and --exclude are mutually exclusive" {
    run resolve_workspace_filter_spec "alpha" "beta"
    assert_failure
    [[ "$output" == *"--repos and --exclude cannot be combined"* ]]
}

@test "resolve_workspace_filter_spec: env allowlist picked up when CLI empty" {
    export RALPH_WORKSPACE_REPOS="alpha,gamma"
    resolve_workspace_filter_spec "" ""
    [[ "$RALPH_WORKSPACE_REPOS_RESOLVED" == $'alpha\ngamma' ]]
}

@test "resolve_workspace_filter_spec: CLI --repos overrides env RALPH_WORKSPACE_REPOS" {
    export RALPH_WORKSPACE_REPOS="zzz"
    resolve_workspace_filter_spec "alpha" ""
    [[ "$RALPH_WORKSPACE_REPOS_RESOLVED" == "alpha" ]]
}

@test "resolve_workspace_filter_spec: CLI --repos conflicts with env RALPH_WORKSPACE_EXCLUDE" {
    export RALPH_WORKSPACE_EXCLUDE="beta"
    run resolve_workspace_filter_spec "alpha" ""
    assert_failure
    [[ "$output" == *"--repos conflicts with RALPH_WORKSPACE_EXCLUDE"* ]]
}

@test "resolve_workspace_filter_spec: CLI --exclude conflicts with env RALPH_WORKSPACE_REPOS" {
    export RALPH_WORKSPACE_REPOS="alpha"
    run resolve_workspace_filter_spec "" "beta"
    assert_failure
    [[ "$output" == *"--exclude conflicts with RALPH_WORKSPACE_REPOS"* ]]
}

@test "resolve_workspace_filter_spec: both env vars set is an error" {
    export RALPH_WORKSPACE_REPOS="alpha"
    export RALPH_WORKSPACE_EXCLUDE="beta"
    run resolve_workspace_filter_spec "" ""
    assert_failure
    [[ "$output" == *"cannot both be set"* ]]
}

# =============================================================================
# is_workspace_filter_active
# =============================================================================

@test "is_workspace_filter_active: false when nothing resolved" {
    run is_workspace_filter_active
    assert_failure
}

@test "is_workspace_filter_active: true when allowlist resolved" {
    export RALPH_WORKSPACE_REPOS_RESOLVED="alpha"
    run is_workspace_filter_active
    assert_success
}

@test "is_workspace_filter_active: true when denylist resolved" {
    export RALPH_WORKSPACE_EXCLUDE_RESOLVED="alpha"
    run is_workspace_filter_active
    assert_success
}

# =============================================================================
# discover_workspace_repos_filtered
# =============================================================================

@test "discover_workspace_repos_filtered: no filter ⇒ same output as raw discovery" {
    _setup_three_repo_workspace
    local raw filtered
    raw=$(discover_workspace_repos ".")
    filtered=$(discover_workspace_repos_filtered ".")
    [[ "$raw" == "$filtered" ]]
}

@test "discover_workspace_repos_filtered: allowlist returns only named repos" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "alpha,beta" ""
    run discover_workspace_repos_filtered "."
    assert_success
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"gamma"* ]]
}

@test "discover_workspace_repos_filtered: denylist drops named repos" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "" "beta"
    run discover_workspace_repos_filtered "."
    assert_success
    [[ "$output" == *"alpha"* ]]
    [[ "$output" != *"beta"* ]]
    [[ "$output" == *"gamma"* ]]
}

@test "discover_workspace_repos_filtered: unknown repo name in --repos ⇒ error lists available" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "delta" ""
    run discover_workspace_repos_filtered "."
    assert_failure
    [[ "$output" == *"unknown repo: delta"* ]]
    [[ "$output" == *"alpha"* && "$output" == *"beta"* && "$output" == *"gamma"* ]]
}

@test "discover_workspace_repos_filtered: unknown repo name in --exclude ⇒ error" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "" "delta"
    run discover_workspace_repos_filtered "."
    assert_failure
    [[ "$output" == *"unknown repo: delta"* ]]
}

@test "discover_workspace_repos_filtered: filter that drops everything ⇒ empty-set error" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "" "alpha,beta,gamma"
    run discover_workspace_repos_filtered "."
    assert_failure
    [[ "$output" == *"filtered out every repository"* ]]
}

@test "discover_workspace_repos_filtered: one-repo allowlist still works" {
    _setup_three_repo_workspace
    resolve_workspace_filter_spec "alpha" ""
    run discover_workspace_repos_filtered "."
    assert_success
    [[ "$output" == "alpha" ]]
}

# =============================================================================
# pick_workspace_task honors allowed_repos
# =============================================================================

@test "pick_workspace_task: allowed_repos empty ⇒ V1 behavior (first task)" {
    _setup_three_repo_workspace
    run pick_workspace_task ".ralph/fix_plan.md" ""
    assert_success
    [[ "$output" == "alpha|"* ]]
}

@test "pick_workspace_task: allowed_repos restricts to named set" {
    _setup_three_repo_workspace
    run pick_workspace_task ".ralph/fix_plan.md" "beta"
    assert_success
    [[ "$output" == "beta|"* ]]
}

@test "pick_workspace_task: allowed_repos filters out cross-repo too" {
    # Workspace where only cross-repo has a pending task, but filter is active.
    mkdir -p alpha/.git .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## alpha

## cross-repo
- [ ] Cross task
EOF
    run pick_workspace_task ".ralph/fix_plan.md" "alpha"
    assert_failure  # cross-repo skipped under filter
}

@test "pick_workspace_tasks_parallel: allowed_repos restricts picked set" {
    _setup_three_repo_workspace
    run pick_workspace_tasks_parallel ".ralph/fix_plan.md" 5 $'alpha\nbeta'
    assert_success
    [[ "$output" == *"alpha|"* ]]
    [[ "$output" == *"beta|"* ]]
    [[ "$output" != *"gamma|"* ]]
}

# =============================================================================
# get_workspace_parallel_limit honors allowed_repos
# =============================================================================

@test "get_workspace_parallel_limit: filtered set caps requested parallelism" {
    _setup_three_repo_workspace
    # Three repos with pending tasks; filter to two; request 4 ⇒ effective 2.
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 4 $'alpha\nbeta'
    assert_success
    [[ "$output" == "2" ]]
}

@test "get_workspace_parallel_limit: empty allowed_repos ⇒ V1 count (3)" {
    _setup_three_repo_workspace
    run get_workspace_parallel_limit ".ralph/fix_plan.md" "." 0 ""
    assert_success
    [[ "$output" == "3" ]]
}

# =============================================================================
# ralph_loop.sh CLI parsing
# =============================================================================

@test "ralph --repos rejected without --workspace" {
    run bash "$RALPH_SCRIPT" --repos alpha
    assert_failure
    [[ "$output" == *"--repos / --exclude only apply to --workspace mode"* ]]
}

@test "ralph --exclude rejected without --workspace" {
    run bash "$RALPH_SCRIPT" --exclude alpha
    assert_failure
    [[ "$output" == *"--repos / --exclude only apply to --workspace mode"* ]]
}

@test "ralph --repos requires a value" {
    run bash "$RALPH_SCRIPT" --repos
    assert_failure
    [[ "$output" == *"--repos requires"* ]]
}

@test "ralph --exclude requires a value" {
    run bash "$RALPH_SCRIPT" --exclude
    assert_failure
    [[ "$output" == *"--exclude requires"* ]]
}

@test "ralph --workspace --repos --exclude rejected as mutually exclusive" {
    # Need a valid workspace so we get past validate_workspace; otherwise the
    # earlier validation may swallow the resolution error. Set up minimum.
    _setup_three_repo_workspace
    run bash "$RALPH_SCRIPT" --workspace --repos alpha --exclude beta
    assert_failure
    [[ "$output" == *"cannot be combined"* ]]
}

# =============================================================================
# validate_workspace honors filter
# =============================================================================

@test "validate_workspace: under filter, missing in-scope repo still warns" {
    _setup_three_repo_workspace
    # Add a section for delta in fix_plan; delta has no on-disk repo.
    cat >> .ralph/fix_plan.md << 'EOF'

## delta
- [ ] Task D1
EOF
    resolve_workspace_filter_spec "alpha,delta" ""
    # delta is in scope but missing on disk ⇒ warn fires.
    # But discover_workspace_repos_filtered will also error on unknown name
    # (delta is not on disk). Validate the unknown-name path here.
    run validate_workspace "."
    assert_failure
    [[ "$output" == *"unknown repo: delta"* ]]
}

@test "validate_workspace: under filter, out-of-scope missing repo does not warn" {
    _setup_three_repo_workspace
    # Reference a repo "delta" only in fix_plan, never on disk.
    cat >> .ralph/fix_plan.md << 'EOF'

## delta
- [ ] Task D1
EOF
    # Filter to alpha; delta is excluded ⇒ no warn for delta missing.
    resolve_workspace_filter_spec "alpha" ""
    run validate_workspace "."
    assert_success
    [[ "$output" != *"delta"* ]]
}
