#!/usr/bin/env bats
# Unit tests for the skip-list-aware picker wrappers used by the worker pool:
#   pick_workspace_task_for_pool  (lib/workspace_manager.sh)
#   pick_next_task_for_pool       (lib/task_sources.sh)
# See docs/proposals/continuous-parallel-execution.md §5.3

load '../helpers/test_helper'

WORKSPACE_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_manager.sh"
TASK_SOURCES_LIB="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    if [[ -f "$WORKSPACE_LIB" ]]; then
        source "$WORKSPACE_LIB"
    fi
    if [[ -f "$TASK_SOURCES_LIB" ]]; then
        source "$TASK_SOURCES_LIB"
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

    # Skip-list entries are the descriptor's first-space-prefix —
    # the same key the worker pool inserts via `${descriptor%% *}`
    # (see lib/worker_pool.sh). Capture the first descriptor to
    # build the matching skip key.
    local first
    first=$(pick_workspace_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f3)
    revert_workspace_task "${TEST_DIR}/.ralph/fix_plan.md" "$first_line"

    local skip_token="${first%% *}"   # e.g. "repo-alpha|first-task|4|First"
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
    # Build the descriptor-prefix that the picker would produce for the
    # only task, then skip it and assert the picker drains.
    local first
    first=$(pick_workspace_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f3)
    revert_workspace_task "${TEST_DIR}/.ralph/fix_plan.md" "$first_line"

    local skip_token="${first%% *}"
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

    # Skip-list entries are the descriptor's first-space-prefix — same key
    # the worker pool stores. For the single-repo descriptor `task_id|line|bead_id`
    # there are no spaces, so the prefix equals the whole descriptor.
    local first
    first=$(pick_next_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f2)
    awk -v ln="$first_line" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' \
        "${TEST_DIR}/.ralph/fix_plan.md" > "${TEST_DIR}/.ralph/fix_plan.md.tmp" \
        && mv "${TEST_DIR}/.ralph/fix_plan.md.tmp" "${TEST_DIR}/.ralph/fix_plan.md"

    local skip_token="${first%% *}"
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
    # Build the descriptor-prefix the picker would produce for the only
    # task, then skip it and assert the picker drains.
    local first
    first=$(pick_next_task "${TEST_DIR}/.ralph/fix_plan.md")
    local first_line
    first_line=$(echo "$first" | cut -d'|' -f2)
    awk -v ln="$first_line" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' \
        "${TEST_DIR}/.ralph/fix_plan.md" > "${TEST_DIR}/.ralph/fix_plan.md.tmp" \
        && mv "${TEST_DIR}/.ralph/fix_plan.md.tmp" "${TEST_DIR}/.ralph/fix_plan.md"

    local skip_token="${first%% *}"
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
    # Regression guard for `grep -F` (substring) vs `grep -xF` (exact-match)
    # in skip-list filtering. The skip-list now contains descriptor-prefix
    # tokens (e.g. `task-5|2|`); substring matching would mis-skip a task
    # whose descriptor token was a superset (e.g. `task-55|2|`).
    mkdir -p .ralph
    {
        echo "# Fix Plan"
        echo "- [ ] task 5"
        echo "- [ ] task 55"
    } > .ralph/fix_plan.md

    # Skip-list contains the FULL descriptor prefix for the line-2 task —
    # `task-5|2|`. Substring check would also match `task-55|3|`; -xF must
    # not.
    run pick_next_task_for_pool ".ralph/fix_plan.md" "task-5|2|"
    assert_success
    local picked_line
    picked_line=$(echo "$output" | cut -d'|' -f2)
    # Line 2 is skipped via descriptor match; line 3 (`task-55|3|`) wins.
    [[ "$picked_line" == "3" ]]
}

@test "pick_next_task_for_pool skip-list ignores trailing blank line" {
    mkdir -p .ralph
    cat > .ralph/fix_plan.md << 'EOF'
# Fix Plan
- [ ] Task one
- [ ] Task two
EOF
    # Skip-list with trailing newline; entry is the descriptor-prefix for
    # line 2 (`task-one|2|`), not the bare line number.
    run pick_next_task_for_pool ".ralph/fix_plan.md" $'task-one|2|\n'
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
