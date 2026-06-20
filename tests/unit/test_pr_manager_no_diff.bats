#!/usr/bin/env bats
# Regression coverage: PR creation must not push artifact-only / no-source-diff branches.

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR
    cd "$TEST_TEMP_DIR" || return 1

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    log_status() { :; }
    worktree_merge() { return 0; }
    export -f log_status worktree_merge

    source "$SCRIPT_DIR/pr_manager.sh"

    export RALPH_ENGINE="claude"
    export PR_ENABLED="true"
    export PR_BASE_BRANCH="main"
    export PR_DRAFT="false"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "source" > app.txt
        mkdir -p .ralph
        echo "base gate" > .ralph/.quality_gate_results
        git add .
        git commit -q -m "init"
        git branch -M main
    )
}

@test "worktree_commit_and_pr refuses to push branch with only .ralph artifact diff" {
    local repo="$TEST_TEMP_DIR/worktree"
    init_repo "$repo"

    (
        cd "$repo" || exit 1
        git checkout -q -b ralph-claude/T-empty
        echo "new gate only" > .ralph/.quality_gate_results
    )

    export _WT_CURRENT_PATH="$repo"
    export _WT_CURRENT_BRANCH="ralph-claude/T-empty"
    export _WT_MAIN_DIR="$repo"
    export RALPH_PR_PUSH_CAPABLE="true"
    export RALPH_PR_GH_CAPABLE="true"

    PUSH_CALLED=0
    PR_CREATE_CALLED=0
    git() {
        if [[ "$1" == "push" ]]; then
            PUSH_CALLED=1
            return 0
        fi
        command git "$@"
    }
    gh() {
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            PR_CREATE_CALLED=1
            return 0
        fi
        return 1
    }

    run worktree_commit_and_pr "T-empty" "artifact only" "true" "9"
    assert_failure
    [[ "$PUSH_CALLED" == "0" ]]
    [[ "$PR_CREATE_CALLED" == "0" ]]
    [[ "$output" == *"worker produced no committable source diff"* ]]

    unset -f git gh
}

@test "worktree_commit_and_pr allows push when branch has source diff" {
    local repo="$TEST_TEMP_DIR/source-worktree"
    init_repo "$repo"

    (
        cd "$repo" || exit 1
        git checkout -q -b ralph-claude/T-source
        echo "real source change" >> app.txt
    )

    export _WT_CURRENT_PATH="$repo"
    export _WT_CURRENT_BRANCH="ralph-claude/T-source"
    export _WT_MAIN_DIR="$repo"
    export RALPH_PR_PUSH_CAPABLE="true"
    export RALPH_PR_GH_CAPABLE="true"

    PUSH_CALLED=0
    PR_CREATE_CALLED=0
    git() {
        if [[ "$1" == "push" ]]; then
            PUSH_CALLED=1
            return 0
        fi
        command git "$@"
    }
    gh() {
        if [[ "$1" == "pr" && "$2" == "view" ]]; then return 1; fi
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            PR_CREATE_CALLED=1
            echo "https://example.test/pr/1"
            return 0
        fi
        return 0
    }

    run worktree_commit_and_pr "T-source" "source change" "true" "10"
    assert_success
    [[ "$PUSH_CALLED" == "1" ]]
    [[ "$PR_CREATE_CALLED" == "1" ]]

    unset -f git gh
}

@test "worktree_fallback_branch_pr refuses to push when only .ralph artifact changed" {
    local repo="$TEST_TEMP_DIR/fallback"
    init_repo "$repo"

    (
        cd "$repo" || exit 1
        echo "new gate only" > .ralph/.quality_gate_results
    )

    export RALPH_PR_PUSH_CAPABLE="true"
    export RALPH_PR_GH_CAPABLE="true"

    PUSH_CALLED=0
    PR_CREATE_CALLED=0
    git() {
        if [[ "$1" == "push" ]]; then
            PUSH_CALLED=1
            return 0
        fi
        command git "$@"
    }
    gh() {
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            PR_CREATE_CALLED=1
            return 0
        fi
        return 1
    }

    cd "$repo"
    run worktree_fallback_branch_pr "T-empty" "artifact only" "3" "true"
    cd "$TEST_TEMP_DIR"
    assert_failure
    [[ "$PUSH_CALLED" == "0" ]]
    [[ "$PR_CREATE_CALLED" == "0" ]]
    [[ "$output" == *"worker produced no committable source diff"* ]]

    unset -f git gh
}
