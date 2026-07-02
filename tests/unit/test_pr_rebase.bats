#!/usr/bin/env bats
# _pr_rebase_onto_base: dirty-vs-conflict detection, .ralph snapshot/restore,
# stderr surfacing, worktree_resolve_rebase_conflicts hook.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"
    export LOG_DIR="${RALPH_DIR}/logs"
    export RALPH_ENGINE="claude"

    log_status() { echo "[$1] $2" >&2; }
    export -f log_status
    source "${BATS_TEST_DIRNAME}/../../lib/pr_manager.sh"

    ORIGIN="${TEST_DIR}/origin.git"
    git init -q --bare "$ORIGIN"
    WORK="${TEST_DIR}/work"
    git clone -q "$ORIGIN" "$WORK" 2>/dev/null
    cd "$WORK"
    git config user.email "t@t"
    git config user.name "T"
    echo base > src.txt
    mkdir -p .ralph
    echo "initial gate state" > .ralph/.quality_gate_results
    git add -A && git commit -qm base
    git branch -M main
    git push -q origin main
    git checkout -qb feature
    echo feature-work > feature.txt
    git add feature.txt && git commit -qm feature
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Advance origin/main from a second clone. $1=file $2=content
advance_main() {
    local other="${TEST_DIR}/other"
    rm -rf "$other"
    git clone -q "$ORIGIN" "$other" 2>/dev/null
    (cd "$other" && git checkout -q main && git config user.email "t@t" && git config user.name "T" \
        && echo "$2" > "$1" && git add "$1" && git commit -qm advance \
        && git push -q origin main)
}

@test "dirty tracked .ralph file no longer blocks rebase; content restored" {
    advance_main upstream.txt one
    echo "live gate output" > .ralph/.quality_gate_results
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHANGED"* ]]
    grep -q "live gate output" .ralph/.quality_gate_results
    git merge-base --is-ancestor origin/main HEAD
}

@test "dirty tracked file outside .ralph → DIRTY rc 2, named in log, no rebase" {
    advance_main upstream.txt one
    echo "local uncommitted edit" >> src.txt
    tip_before=$(git rev-parse HEAD)
    run _pr_rebase_onto_base main
    [ "$status" -eq 2 ]
    [[ "$output" == *"DIRTY"* ]]
    [[ "$output" == *"src.txt"* ]]
    [ "$(git rev-parse HEAD)" = "$tip_before" ]
}

@test "real conflict → CONFLICT rc 1, files + git stderr logged, rebase aborted" {
    advance_main feature.txt "conflicting upstream content"
    tip_before=$(git rev-parse HEAD)
    run _pr_rebase_onto_base main
    [ "$status" -eq 1 ]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"feature.txt"* ]]
    [ "$(git rev-parse HEAD)" = "$tip_before" ]
    [ -z "$(git status --porcelain)" ]   # abort left the tree clean
}

@test "worktree_resolve_rebase_conflicts hook resolves → rc 0 CHANGED" {
    advance_main feature.txt "conflicting upstream content"
    worktree_resolve_rebase_conflicts() {
        echo "resolved content" > feature.txt
        git add feature.txt
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
    }
    export -f worktree_resolve_rebase_conflicts
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHANGED"* ]]
    git merge-base --is-ancestor origin/main HEAD
}

@test "no remote base ref → SKIPPED unchanged" {
    git remote remove origin
    run _pr_rebase_onto_base main
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
}
