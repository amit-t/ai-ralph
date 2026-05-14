#!/usr/bin/env bats
# Unit tests for the skip-list-aware picker wrappers used by the worker pool:
#   pick_workspace_task_for_pool  (lib/workspace_manager.sh)
#   pick_next_task_for_pool       (lib/task_sources.sh)
# See docs/proposals/continuous-parallel-execution.md §5.3

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
TASK_SOURCES_LIB="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"
WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$TASK_SOURCES_LIB" ]]; then
        source "$TASK_SOURCES_LIB"
    fi
    # Source worker_pool.sh so tests can use _continuous_skip_key — the
    # canonical skip-list key generator (P1 #8). Tests that build a
    # skip-list entry MUST go through this helper so they stay in sync
    # with the production orchestrators.
    if [[ -f "$WORKER_POOL_LIB" ]]; then
        source "$WORKER_POOL_LIB"
    fi
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# pick_workspace_task_for_pool
# =============================================================================

@test "pick_workspace_task_for_pool exists" {
    declare -F pick_workspace_task_for_pool > /dev/null
}

@test "pick_workspace_task_for_pool picks a task with empty skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task

## repo-beta
- [ ] Second task
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    [[ "$output" == *"repo-alpha"* ]]
    [[ "$output" == *"First task"* ]]
}

@test "pick_workspace_task_for_pool skips lines listed in skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] First task

## repo-beta
- [ ] Second task
EOF

    # P1 #8: skip-list entries are the canonical key produced by
    # _continuous_skip_key — `repo|task_id|line` for workspace, dropping
    # the description. Build the matching key from the first descriptor.
    local first
    first=$(pick_workspace_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f3)
    revert_workspace_task "${TEST_DIR}/.ralph/fix_plan.md" "$first_line"

    local skip_token
    skip_token=$(_continuous_skip_key "$first")   # e.g. "repo-alpha|first-task|4"
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "$skip_token"
    assert_success
    [[ "$output" != "$first" ]]
    [[ "$output" == *"Second task"* ]]
}

@test "pick_workspace_task_for_pool returns failure when all eligible are skipped" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Only task
EOF
    # P1 #8: build the canonical `repo|task_id|line` key the orchestrator
    # would insert; skip it and assert the picker drains.
    local first
    first=$(pick_workspace_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f3)
    revert_workspace_task "${TEST_DIR}/.ralph/fix_plan.md" "$first_line"

    local skip_token
    skip_token=$(_continuous_skip_key "$first")
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "$skip_token"
    assert_failure
}

@test "pick_workspace_task_for_pool atomically marks picked task in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Task to mark
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    grep -q '\[~\]' "${TEST_DIR}/.ralph/fix_plan.md"
}

@test "pick_workspace_task_for_pool output format matches pick_workspace_task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## repo-alpha
- [ ] Format check task
EOF

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output: repo|task_id|line_num|description
    echo "$output" | grep -qE '^repo-alpha\|[a-z0-9-]+\|[0-9]+\|Format check task$'
}

# =============================================================================
# pick_next_task_for_pool
# =============================================================================

@test "pick_next_task_for_pool exists" {
    declare -F pick_next_task_for_pool > /dev/null
}

@test "pick_next_task_for_pool picks a task with empty skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output format from pick_next_task: task_id|line_num|bead_id
    echo "$output" | grep -qE '\|[0-9]+\|'
}

@test "pick_next_task_for_pool skips lines in skip-list" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
- [ ] Task three
EOF

    # P1 #8: skip-list entries are the canonical key produced by
    # _continuous_skip_key — for single-repo descriptors this is just the
    # task_id slug (no line, no bead_id), so the key is stable across
    # fix_plan.md edits.
    local first
    first=$(pick_next_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f2)
    awk -v ln="$first_line" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' \
        "${TEST_DIR}/.ralph/fix_plan.md" > "${TEST_DIR}/.ralph/fix_plan.md.tmp" \
        && mv "${TEST_DIR}/.ralph/fix_plan.md.tmp" "${TEST_DIR}/.ralph/fix_plan.md"

    local skip_token
    skip_token=$(_continuous_skip_key "$first")
    run pick_next_task_for_pool ".ralph/fix_plan.md" "$skip_token"
    assert_success
    [[ "$output" != "$first" ]]
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" != "$first_line" ]]
}

@test "pick_next_task_for_pool returns failure when all unclaimed are skipped" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Lone task
EOF
    # P1 #8: build the canonical task_id-slug key; skip it and assert
    # the picker drains.
    local first
    first=$(pick_next_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f2)
    awk -v ln="$first_line" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' \
        "${TEST_DIR}/.ralph/fix_plan.md" > "${TEST_DIR}/.ralph/fix_plan.md.tmp" \
        && mv "${TEST_DIR}/.ralph/fix_plan.md.tmp" "${TEST_DIR}/.ralph/fix_plan.md"

    local skip_token
    skip_token=$(_continuous_skip_key "$first")
    run pick_next_task_for_pool ".ralph/fix_plan.md" "$skip_token"
    assert_failure
}

@test "pick_next_task_for_pool atomically marks picked task in-progress" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task to mark
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    grep -q '\[~\]' "${TEST_DIR}/.ralph/fix_plan.md"
}

@test "pick_next_task_for_pool output format matches pick_next_task" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Format check task
EOF

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_success
    # Output: task_id|line_num|bead_id  (bead_id may be empty)
    echo "$output" | grep -qE '^[a-zA-Z0-9_-]+\|[0-9]+\|'
}

# =============================================================================
# Concurrent picker race: N parallel callers must each get a distinct line
# under the .task_pick_lock / .workspace_task_lock atomic.
# =============================================================================

@test "pick_next_task_for_pool: 5 concurrent callers each get a distinct line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
- [ ] Task three
- [ ] Task four
- [ ] Task five
EOF

    : > "${TEST_DIR}/.picks"
    local pids=()
    for _ in 1 2 3 4 5; do
        (
            out=$(pick_next_task_for_pool ".ralph/fix_plan.md" "" 2>/dev/null) || out="MISS"
            echo "$out" >> "${TEST_DIR}/.picks"
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Each pick is "task_id|line_num|bead_id". Extract the line numbers and
    # assert they are unique. With 5 tasks and 5 racing pickers, all 5 should
    # have hit a distinct line.
    local picked_lines
    picked_lines=$(awk -F'|' '$2 ~ /^[0-9]+$/ {print $2}' "${TEST_DIR}/.picks" | sort -n)
    local unique
    unique=$(echo "$picked_lines" | sort -u)
    [[ "$picked_lines" == "$unique" ]]
    # All 5 must be claimed (no MISS).
    ! grep -q '^MISS$' "${TEST_DIR}/.picks"
    [[ "$(echo "$unique" | wc -l | tr -d ' ')" == "5" ]]
}

@test "pick_next_task_for_pool: under contention, total [~] count equals total picks" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] T1
- [ ] T2
- [ ] T3
- [ ] T4
- [ ] T5
- [ ] T6
EOF

    local pids=()
    for _ in 1 2 3 4; do
        ( pick_next_task_for_pool ".ralph/fix_plan.md" "" >/dev/null 2>&1 ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Exactly 4 lines should now be [~] (no double-claims, no missed claims).
    local in_progress
    in_progress=$(grep -c '^- \[~\]' .ralph/fix_plan.md)
    [[ "$in_progress" == "4" ]]
}

@test "pick_workspace_task_for_pool: 3 concurrent callers each get a distinct repo+line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] alpha-task
- [ ] alpha-task-2

## repo-b
- [ ] beta-task

## repo-c
- [ ] gamma-task
EOF

    : > "${TEST_DIR}/.ws_picks"
    local pids=()
    for _ in 1 2 3; do
        (
            out=$(pick_workspace_task_for_pool ".ralph/fix_plan.md" "" 2>/dev/null) || out="MISS"
            echo "$out" >> "${TEST_DIR}/.ws_picks"
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Output format: repo|task_id|line|description
    # Distinct line numbers => no double-claim.
    local picked_lines
    picked_lines=$(awk -F'|' '$3 ~ /^[0-9]+$/ {print $3}' "${TEST_DIR}/.ws_picks" | sort -n)
    local unique
    unique=$(echo "$picked_lines" | sort -u)
    [[ "$picked_lines" == "$unique" ]]
    [[ "$(echo "$unique" | wc -l | tr -d ' ')" == "3" ]]
}

# =============================================================================
# Lock-acquisition failure path: when _acquire_task_lock fails, the picker
# returns 1 (not 0 with empty stdout). The orchestrator interprets a 1 from
# the picker as "queue empty / no eligible task," which is what we want
# (better than crashing or silently picking duplicates).
# =============================================================================

@test "pick_next_task_for_pool returns failure if _acquire_task_lock fails" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
EOF

    # Override _acquire_task_lock to always fail (simulates lock contention
    # exceeding the timeout).
    _acquire_task_lock() { return 1; }
    export -f _acquire_task_lock

    run pick_next_task_for_pool ".ralph/fix_plan.md" ""
    assert_failure
    # The picker should not have claimed anything.
    ! grep -q '\[~\]' .ralph/fix_plan.md
}

@test "pick_workspace_task_for_pool returns failure if _acquire_task_lock fails" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] alpha-task
EOF

    _acquire_task_lock() { return 1; }
    export -f _acquire_task_lock

    run pick_workspace_task_for_pool ".ralph/fix_plan.md" ""
    assert_failure
    ! grep -q '\[~\]' .ralph/fix_plan.md
}

# =============================================================================
# Skip-list edge cases
# =============================================================================

@test "pick_next_task_for_pool skip-list does NOT match descriptor-prefix substrings" {
    # P1 #8 + grep -F regression guard: skip-list now contains just the
    # task_id slug (e.g. `task-5`); substring matching would mis-skip a
    # task whose slug was a superset (e.g. `task-55`). The `-xF` (exact
    # fixed-string match) check in the picker must reject the substring.
    mkdir -p .ralph
    {
        echo "# Fix Plan"
        echo "- [ ] task 5"
        echo "- [ ] task 55"
    } > .ralph/fix_plan.md

    # Skip-list contains the slug for the line-2 task. Substring match would
    # also catch `task-55` (line 3); -xF must not.
    run pick_next_task_for_pool ".ralph/fix_plan.md" "task-5"
    assert_success
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    # Line 2 is skipped via slug match; line 3 (`task-55`) wins.
    [[ "$picked_line" == "3" ]]
}

@test "pick_next_task_for_pool skip-list ignores trailing blank line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
EOF
    # P1 #8: skip-list with trailing newline; entry is the slug for
    # line 2 (`task-one`).
    run pick_next_task_for_pool ".ralph/fix_plan.md" $'task-one\n'
    assert_success
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    [[ "$picked_line" == "3" ]]
}

# =============================================================================
# End-to-end production-shape contract: the worker pool's skip-list keys
# (built via `${descriptor%% *}`) must round-trip with the production
# picker so K=max-task-attempts actually limits attempts on a real failing
# task. Earlier, the picker checked bare line numbers while the
# orchestrator inserted descriptor-prefix tokens — they never matched, so
# a single bad task ate the entire M budget. Repro:
#
#   # 1 task, K=2, M=10. Expected: 2 attempts then drain (queue empty).
#   # Buggy: 10 attempts, all on the same task.
#
# These tests fail loudly if either side of the contract drifts.
# =============================================================================

@test "REGRESSION: workspace skip-list round-trips through worker_pool + production picker" {
    source "${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"

    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## api-repo

- [ ] Fix login bug on mobile
EOF

    # Production-shape executor: always fail, revert [~] → [ ] like
    # _continuous_workspace_executor does in ralph_loop.sh.
    _prod_ws_exec() {
        local descriptor="$1"
        local line_num
        line_num=$(echo "$descriptor" | cut -d'|' -f3)
        local tmp="${PWD}/.ralph/fix_plan.md.tmp.$$"
        awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "${PWD}/.ralph/fix_plan.md" > "$tmp" \
            && mv "$tmp" "${PWD}/.ralph/fix_plan.md"
        return 1
    }
    export -f _prod_ws_exec
    _prod_ws_pick() { pick_workspace_task_for_pool "${PWD}/.ralph/fix_plan.md" "$1"; }
    export -f _prod_ws_pick
    _prod_ws_oc() { :; }
    export -f _prod_ws_oc

    export RALPH_DIR="${PWD}/.ralph"
    run run_continuous_worker_pool 1 10 2 0 _prod_ws_pick _prod_ws_exec _prod_ws_oc

    # With K=2 and 1 bad task, the orchestrator should add the descriptor
    # prefix to the skip-list on the 2nd failure, then the picker drains
    # on the 3rd call. Total completions = 2, NOT 10.
    [[ "$output" == *"skip-list +="* ]]
    local last_completed
    last_completed=$(echo "$output" | grep -oE 'completed=[0-9]+/10' | tail -1 | grep -oE '[0-9]+' | head -1)
    [[ "$last_completed" == "2" ]] || {
        echo "FAIL: expected 2 attempts but got $last_completed (skip-list bug regressed)" >&2
        echo "$output" >&2
        return 1
    }
    [[ "$output" == *"queue empty"* ]]
}

@test "REGRESSION: single-repo skip-list round-trips through worker_pool + production picker" {
    source "${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"

    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Fix login bug
EOF

    _prod_sr_exec() {
        local descriptor="$1"
        local line_num
        line_num=$(echo "$descriptor" | cut -d'|' -f2)
        local tmp="${PWD}/.ralph/fix_plan.md.tmp.$$"
        awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "${PWD}/.ralph/fix_plan.md" > "$tmp" \
            && mv "$tmp" "${PWD}/.ralph/fix_plan.md"
        return 1
    }
    export -f _prod_sr_exec
    _prod_sr_pick() { pick_next_task_for_pool "${PWD}/.ralph/fix_plan.md" "$1"; }
    export -f _prod_sr_pick
    _prod_sr_oc() { :; }
    export -f _prod_sr_oc

    export RALPH_DIR="${PWD}/.ralph"
    run run_continuous_worker_pool 1 8 2 0 _prod_sr_pick _prod_sr_exec _prod_sr_oc

    [[ "$output" == *"skip-list +="* ]]
    local last_completed
    last_completed=$(echo "$output" | grep -oE 'completed=[0-9]+/8' | tail -1 | grep -oE '[0-9]+' | head -1)
    [[ "$last_completed" == "2" ]] || {
        echo "FAIL: expected 2 attempts but got $last_completed (skip-list bug regressed)" >&2
        echo "$output" >&2
        return 1
    }
    [[ "$output" == *"queue empty"* ]]
}

# =============================================================================
# Workspace filter (--repos / --exclude) must work in continuous mode.
# Earlier, pick_workspace_task_for_pool didn't accept allowed_repos at all,
# so --repos was silently ignored.
# =============================================================================

@test "pick_workspace_task_for_pool honors allowed_repos (allowlist)" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-skip
- [ ] Skip me
- [ ] Skip me too

## repo-keep
- [ ] Keep this
EOF
    # allowed_repos restricts to repo-keep; cross-repo and repo-skip are
    # filtered out exactly like pick_workspace_task does in V1.
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "" "repo-keep"
    assert_success
    [[ "$output" == repo-keep* ]]
    [[ "$output" == *"Keep this"* ]]
}

@test "pick_workspace_task_for_pool: empty allowed_repos ⇒ V1 behavior (any repo)" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] First task

## repo-b
- [ ] Second task
EOF
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "" ""
    assert_success
    [[ "$output" == repo-a* ]]
}

@test "pick_workspace_task_for_pool: allowlist filters out cross-repo section too" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## cross-repo
- [ ] Cross-cutting work

## repo-keep
- [ ] Real work
EOF
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "" "repo-keep"
    assert_success
    [[ "$output" == repo-keep* ]]
    [[ "$output" != *"Cross-cutting"* ]]
}

@test "pick_workspace_task_for_pool: allowlist excluding all repos drains" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace

## repo-a
- [ ] T1

## repo-b
- [ ] T2
EOF
    # No matching repo in allowlist ⇒ picker drains.
    run pick_workspace_task_for_pool ".ralph/fix_plan.md" "" "no-such-repo"
    assert_failure
}

# =============================================================================
# Wiring: ralph_loop.sh's _continuous_workspace_picker MUST forward
# RALPH_WORKSPACE_ALLOWED_REPOS as the 3rd arg to
# pick_workspace_task_for_pool. Otherwise --repos / --exclude in
# continuous mode would silently fail.
# =============================================================================

@test "_continuous_workspace_picker forwards RALPH_WORKSPACE_ALLOWED_REPOS to picker" {
    # Spy on the picker — capture its 3rd arg.
    pick_workspace_task_for_pool() {
        echo "ARGS:fix_plan=$1|skip=$2|allowed=$3" > "${TEST_DIR}/.spy"
        return 0
    }
    export -f pick_workspace_task_for_pool

    # Source the closure definition. It's defined inline in ralph_loop.sh
    # so we shell-source the file's relevant section by extracting it.
    eval "$(sed -n '/^_continuous_workspace_picker()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}"
    : > "${RALPH_DIR}/fix_plan.md"

    export RALPH_WORKSPACE_ALLOWED_REPOS=$'apirepo\nworkerrepo'
    _continuous_workspace_picker "skipped-token"

    local spy
    spy=$(cat "${TEST_DIR}/.spy")
    [[ "$spy" == *"skip=skipped-token"* ]]
    [[ "$spy" == *$'allowed=apirepo\nworkerrepo' ]]
}

# =============================================================================
# P0 #2 — engine-parity for the filter-spec forwarding.
# devin and codex previously omitted the 3rd arg, so --repos / --exclude were
# silently ignored in continuous workspace mode for those engines.
# These tests lock down the fix.
# =============================================================================

@test "devin _continuous_workspace_picker forwards RALPH_WORKSPACE_ALLOWED_REPOS (P0 #2)" {
    pick_workspace_task_for_pool() {
        echo "ARGS:fix_plan=$1|skip=$2|allowed=$3" > "${TEST_DIR}/.spy"
        return 0
    }
    export -f pick_workspace_task_for_pool

    eval "$(sed -n '/^_continuous_workspace_picker()/,/^}/p' "${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh")"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}"
    : > "${RALPH_DIR}/fix_plan.md"

    export RALPH_WORKSPACE_ALLOWED_REPOS=$'apirepo\nworkerrepo'
    _continuous_workspace_picker "skipped-token"

    local spy
    spy=$(cat "${TEST_DIR}/.spy")
    [[ "$spy" == *"skip=skipped-token"* ]]
    [[ "$spy" == *$'allowed=apirepo\nworkerrepo' ]]
}

@test "codex _continuous_workspace_picker forwards RALPH_WORKSPACE_ALLOWED_REPOS (P0 #2)" {
    pick_workspace_task_for_pool() {
        echo "ARGS:fix_plan=$1|skip=$2|allowed=$3" > "${TEST_DIR}/.spy"
        return 0
    }
    export -f pick_workspace_task_for_pool

    eval "$(sed -n '/^_continuous_workspace_picker()/,/^}/p' "${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh")"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}"
    : > "${RALPH_DIR}/fix_plan.md"

    export RALPH_WORKSPACE_ALLOWED_REPOS=$'apirepo\nworkerrepo'
    _continuous_workspace_picker "skipped-token"

    local spy
    spy=$(cat "${TEST_DIR}/.spy")
    [[ "$spy" == *"skip=skipped-token"* ]]
    [[ "$spy" == *$'allowed=apirepo\nworkerrepo' ]]
}

# =============================================================================
# P1 #8 — Canonical skip-key (lib/worker_pool.sh::_continuous_skip_key).
#
# These tests pin down the new key shape:
#   - Workspace descriptor (≥4 pipe fields): `repo|task_id|line`
#   - Single-repo descriptor (2–3 pipe fields): `task_id` (slug only)
#   - Pipe-less / test-mock descriptor: first-space-prefix
#
# AND they prove that changes to the task description between picks no
# longer break the skip-list match (the regression that P1 #8 fixes).
# =============================================================================

@test "P1 #8: _continuous_skip_key — workspace descriptor → repo|task_id|line" {
    local key
    key=$(_continuous_skip_key "api|fix-login|42|Fix login bug on mobile")
    [[ "$key" == "api|fix-login|42" ]]
}

@test "P1 #8: _continuous_skip_key — single-repo descriptor → task_id slug only" {
    local key
    key=$(_continuous_skip_key "fix-login|42|bead-1")
    [[ "$key" == "fix-login" ]]
    # Trailing empty bead_id is also fine.
    key=$(_continuous_skip_key "fix-login|42|")
    [[ "$key" == "fix-login" ]]
    # Two-field variant (bead_id absent entirely).
    key=$(_continuous_skip_key "fix-login|42")
    [[ "$key" == "fix-login" ]]
}

@test "P1 #8: _continuous_skip_key — pipe-less mock descriptor → first-space-prefix" {
    local key
    key=$(_continuous_skip_key "T1 rc=0")
    [[ "$key" == "T1" ]]
    # Descriptor with only a leading token (no rc).
    key=$(_continuous_skip_key "MYTASK")
    [[ "$key" == "MYTASK" ]]
}

@test "P1 #8: _continuous_skip_key — workspace key strips description (key stable across edits)" {
    # Same task, two different descriptions (user edited fix_plan.md between
    # picks). The canonical key must NOT change.
    local k1 k2
    k1=$(_continuous_skip_key "api|fix-login|42|Fix login bug on mobile")
    k2=$(_continuous_skip_key "api|fix-login|42|Login flow broken in iOS app")
    [[ "$k1" == "$k2" ]]
    [[ "$k1" == "api|fix-login|42" ]]
}

@test "P1 #8: _continuous_skip_key — different repos same slug do NOT collide" {
    # Two repos can legitimately have a task with the same slug
    # (e.g. "update-deps"). The canonical key must DIFFER.
    local k1 k2
    k1=$(_continuous_skip_key "api|update-deps|10|Bump axios")
    k2=$(_continuous_skip_key "web|update-deps|22|Bump react")
    [[ "$k1" != "$k2" ]]
    [[ "$k1" == "api|update-deps|10" ]]
    [[ "$k2" == "web|update-deps|22" ]]
}

@test "P1 #8: workspace skip-list survives description edits between picks (round-trip)" {
    source "${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"

    mkdir -p .ralph
    # Use a [bead-id] prefix so the picker's task_id is anchored to the
    # bead, not auto-slugged from the (mutable) description text. This is
    # the realistic scenario where the user can edit the description in
    # fix_plan.md mid-run and the orchestrator still recognizes "same task".
    cat > .ralph/fix_plan.md << 'EOF'
# Workspace Fix Plan

## api-repo

- [ ] [bug-101] Initial description of the bug
EOF

    # Production-shape executor: revert [~] → [ ] AND edit the description
    # text on the same line. The bead_id `bug-101` stays, so the next pick
    # gets the same task_id slug and the skip-list match holds.
    _editing_exec() {
        local descriptor="$1"
        local line_num
        line_num=$(echo "$descriptor" | cut -d'|' -f3)
        local tmp="${PWD}/.ralph/fix_plan.md.tmp.$$"
        awk -v ln="$line_num" 'NR==ln {
            sub(/- \[~\]/, "- [ ]");
            sub(/Initial description of the bug/, "Edited mid-run by a user")
        } 1' "${PWD}/.ralph/fix_plan.md" > "$tmp" \
            && mv "$tmp" "${PWD}/.ralph/fix_plan.md"
        return 1
    }
    export -f _editing_exec
    _editing_pick() { pick_workspace_task_for_pool "${PWD}/.ralph/fix_plan.md" "$1"; }
    export -f _editing_pick
    _editing_oc() { :; }
    export -f _editing_oc

    export RALPH_DIR="${PWD}/.ralph"
    # K=1, M=10: should fail once, add `api-repo|bug-101|5` to skip-list,
    # then drain because the picker recognises the same `repo|task_id|line`
    # on the next pick even though the description text changed.
    run run_continuous_worker_pool 1 10 1 0 _editing_pick _editing_exec _editing_oc

    [[ "$output" == *"skip-list +="* ]]
    local last_completed
    last_completed=$(echo "$output" | grep -oE 'completed=[0-9]+/10' | tail -1 | grep -oE '[0-9]+' | head -1)
    # K=1 → exactly 1 attempt. If the description-edit regressed the
    # skip-list match, the orchestrator would re-pick and burn M=10.
    [[ "$last_completed" == "1" ]] || {
        echo "FAIL: expected 1 attempt but got $last_completed (P1 #8 regressed)" >&2
        echo "$output" >&2
        return 1
    }
    [[ "$output" == *"queue empty"* ]]
    # The key recorded in the skip-list line MUST be `repo|task_id|line` —
    # no description fragment. The old (buggy) key was
    # `api-repo|bug-101|5|[bug-101]` (first-word of `[bug-101] Initial …`).
    [[ "$output" == *"skip-list += api-repo|bug-101|5 "* ]]
}

@test "P1 #8: single-repo skip-list survives line shifts (slug-only key)" {
    source "${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"

    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] First broken task
EOF

    # The "broken" exec reverts [~] → [ ] AND inserts a comment line at the
    # top of the file, shifting the bug task's line number from 2 → 3.
    # With the old `task_id|line|bead_id` key the second pick's line=3
    # would never match the recorded line=2 key, and the K-limit would be
    # silently bypassed. The new slug-only key (`first-broken-task`) is
    # stable across the shift.
    _shifty_exec() {
        local descriptor="$1"
        local line_num
        line_num=$(echo "$descriptor" | cut -d'|' -f2)
        # Revert [~] and prepend a new line.
        local tmp="${PWD}/.ralph/fix_plan.md.tmp.$$"
        awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "${PWD}/.ralph/fix_plan.md" > "$tmp" \
            && mv "$tmp" "${PWD}/.ralph/fix_plan.md"
        local tmp2="${PWD}/.ralph/fix_plan.md.tmp2.$$"
        printf '<!-- a new line that shifts task numbers down -->\n%s' "$(cat "${PWD}/.ralph/fix_plan.md")" > "$tmp2" \
            && mv "$tmp2" "${PWD}/.ralph/fix_plan.md"
        return 1
    }
    export -f _shifty_exec
    _shifty_pick() { pick_next_task_for_pool "${PWD}/.ralph/fix_plan.md" "$1"; }
    export -f _shifty_pick
    _shifty_oc() { :; }
    export -f _shifty_oc

    export RALPH_DIR="${PWD}/.ralph"
    run run_continuous_worker_pool 1 10 1 0 _shifty_pick _shifty_exec _shifty_oc

    [[ "$output" == *"skip-list +="* ]]
    local last_completed
    last_completed=$(echo "$output" | grep -oE 'completed=[0-9]+/10' | tail -1 | grep -oE '[0-9]+' | head -1)
    # K=1: exactly 1 attempt. Old behavior would have burned all M=10.
    [[ "$last_completed" == "1" ]] || {
        echo "FAIL: expected 1 attempt but got $last_completed (P1 #8 regressed)" >&2
        echo "$output" >&2
        return 1
    }
}

@test "P1 #8: tabs orchestrator emits skip-key via _continuous_skip_key (source contract)" {
    # Tabs orchestrator must NOT recompute the skip-key inline. The fix
    # routes through _continuous_skip_key so single-pane and tabs modes
    # use identical key shapes.
    local tabs_lib="${BATS_TEST_DIRNAME}/../../lib/worker_pool_tabs.sh"
    # The legacy form `task_key="${task_id:-${descriptor%% *}}"` must
    # have been replaced.
    ! grep -q 'task_key="${task_id:-${descriptor%% \*}}"' "$tabs_lib"
    # The new call to _continuous_skip_key must be present.
    grep -q '_continuous_skip_key' "$tabs_lib"
}

@test "P1 #8: single-pane orchestrator emits skip-key via _continuous_skip_key (source contract)" {
    local pool_lib="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
    # The function must be defined.
    grep -q '^_continuous_skip_key()' "$pool_lib"
    # The failure path must call it (not the legacy `${finished_descriptor%% *}`).
    awk '/^run_continuous_worker_pool\(\)/,/^}/' "$pool_lib" | grep -q '_continuous_skip_key'
}
