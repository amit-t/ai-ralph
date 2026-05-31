#!/usr/bin/env bats
# Regression tests for Row 6 — workspace continuous mode push + PR creation.
#
# Bug history: workspace continuous mode left orphan per-task branches on the
# local clone with no remote push and no PR. The chain
#   _continuous_workspace_executor
#     → _workspace_execute_task
#       → workspace_repo_commit_and_pr
#         → worktree_commit_and_pr
# would silently no-op in live runs (subshell state loss, missed preflight,
# engine commits landing outside the worktree). The fix-plan row was marked
# [x] anyway, so retry never picked the task up — N tasks → N orphans.
#
# Row 6 adds _workspace_push_and_pr in lib/workspace_continuous_pr.sh as the
# executor-level safety net: after the inner helper returns 0, the executor
# calls this function, which idempotently pushes the per-task branch and
# opens a PR via gh. These tests pin its semantics: honors PR_ENABLED /
# PR_DRAFT / PR_BASE_BRANCH, skips cleanly when the branch is missing or gh
# is absent, never invents a PR when one already exists, and works
# identically for claude / devin / codex engines.

load '../helpers/test_helper'

# Override the shared setup so we get a clean temp dir without .ralph/
setup() {
    TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wspr.XXXXXX")"
    export TEST_TEMP_DIR
    cd "$TEST_TEMP_DIR" || return 1

    # PATH stubs: per-test bin dir prepended to PATH for gh
    STUB_BIN="$TEST_TEMP_DIR/.stubs"
    mkdir -p "$STUB_BIN"
    GH_LOG="$STUB_BIN/gh.log"
    : > "$GH_LOG"
    ORIG_PATH="$PATH"
    export PATH="$STUB_BIN:$PATH"

    # Resolve required tool paths once so we can build an isolated PATH for the
    # "gh not installed" test (must exclude the system gh but keep git, etc.)
    _ISOLATED_BIN="$TEST_TEMP_DIR/.isolated_bin"
    mkdir -p "$_ISOLATED_BIN"
    for tool in git awk sed grep cat printf mkdir rm cd echo bash env tr cut head wc dirname basename; do
        local tool_path
        tool_path="$(PATH="$ORIG_PATH" command -v "$tool" 2>/dev/null)"
        [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$_ISOLATED_BIN/$tool"
    done

    # Set up a fake workspace with one repo + a bare remote so push actually works.
    REPO_NAME="alpha"
    REMOTE_DIR="$TEST_TEMP_DIR/.remotes/${REPO_NAME}.git"
    REPO_DIR="$TEST_TEMP_DIR/${REPO_NAME}"
    mkdir -p "$REMOTE_DIR" "$REPO_DIR"
    git init --bare --initial-branch=main "$REMOTE_DIR" >/dev/null 2>&1
    git init --initial-branch=main "$REPO_DIR" >/dev/null 2>&1
    (
        cd "$REPO_DIR"
        git -c user.email=t@t -c user.name=t commit --allow-empty -m base >/dev/null
        git remote add origin "$REMOTE_DIR"
        git push -u origin main >/dev/null 2>&1
    )

    # Source the helper under test.
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../lib/workspace_continuous_pr.sh"

    # Reset relevant env between tests
    unset PR_ENABLED PR_DRAFT PR_BASE_BRANCH RALPH_ENGINE
}

teardown() {
    cd /
    # Restore PATH so cleanup tools (rm) are reachable even after a test that
    # narrowed PATH (e.g., the gh-not-installed scenario).
    [[ -n "$ORIG_PATH" ]] && export PATH="$ORIG_PATH"
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
    return 0
}

# --- helpers ----------------------------------------------------------------

# Install a gh stub that records argv to $GH_LOG.
#   $1 - "no-pr" | "has-pr" — controls `gh pr view` exit behavior
#   $2 - optional URL to print on `gh pr create` (default https://example/pr/1)
install_gh_stub() {
    local mode="${1:-no-pr}"
    local pr_url="${2:-https://example.invalid/pr/1}"
    cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
# Record full argv on a single line per invocation, tab-separated.
printf 'gh' >> "$GH_LOG"
for a in "\$@"; do printf '\t%s' "\$a" >> "$GH_LOG"; done
printf '\n' >> "$GH_LOG"

cmd="\$1"; sub="\$2"
case "\$cmd \$sub" in
  "pr view")
    if [[ "$mode" == "has-pr" ]]; then
      echo 'https://example.invalid/pr/existing'
      exit 0
    else
      exit 1
    fi
    ;;
  "pr create")
    echo "$pr_url"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x "$STUB_BIN/gh"
}

# Make `gh` invisible on PATH (simulates gh-not-installed). The isolated bin
# dir intentionally omits gh, so `command -v gh` resolves to nothing.
uninstall_gh_stub() {
    rm -f "$STUB_BIN/gh"
    export PATH="$_ISOLATED_BIN"
}

# Create a per-task branch in $REPO_DIR with one commit so push has something
# to send. Args: $1=branch_name
make_task_branch() {
    local branch="$1"
    (
        cd "$REPO_DIR"
        git checkout -q -b "$branch" 2>/dev/null
        echo "work-$branch" > "work.txt"
        git add work.txt
        git -c user.email=t@t -c user.name=t commit -q -m "ralph: $branch"
        git checkout -q main
    )
}

# Count lines in the gh log matching a literal substring (anchored to argv).
gh_invocations_with() {
    local needle="$1"
    grep -c -F "$needle" "$GH_LOG" 2>/dev/null || echo 0
}

# Does the remote have this branch?
remote_has_branch() {
    git -C "$REMOTE_DIR" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1
}

# --- PR_ENABLED gating ------------------------------------------------------

@test "PR_ENABLED=false short-circuits without touching git or gh" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude PR_ENABLED=false
    make_task_branch "ralph-claude/task-a"

    run _workspace_push_and_pr "$REPO_NAME" "task-a" "Some task"
    assert_success
    # No push happened
    ! remote_has_branch "ralph-claude/task-a"
    # gh was never called
    [[ ! -s "$GH_LOG" ]]
}

# --- Happy path per engine --------------------------------------------------

@test "claude engine: branch pushed and gh pr create invoked with correct args" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-c"

    run _workspace_push_and_pr "$REPO_NAME" "task-c" "Add claude feature"
    assert_success

    remote_has_branch "ralph-claude/task-c"
    [[ "$(gh_invocations_with $'\tpr\tcreate')" -ge 1 ]]
    grep -q $'\t--head\tralph-claude/task-c' "$GH_LOG"
    grep -q $'\t--base\tmain' "$GH_LOG"
    grep -q $'\t--title\tAdd claude feature' "$GH_LOG"
}

@test "devin engine: branch pushed and gh pr create invoked with ralph-devin/ prefix" {
    install_gh_stub no-pr
    export RALPH_ENGINE=devin
    make_task_branch "ralph-devin/task-d"

    run _workspace_push_and_pr "$REPO_NAME" "task-d" "Add devin feature"
    assert_success

    remote_has_branch "ralph-devin/task-d"
    grep -q $'\t--head\tralph-devin/task-d' "$GH_LOG"
}

@test "codex engine: branch pushed and gh pr create invoked with ralph-codex/ prefix" {
    install_gh_stub no-pr
    export RALPH_ENGINE=codex
    make_task_branch "ralph-codex/task-x"

    run _workspace_push_and_pr "$REPO_NAME" "task-x" "Add codex feature"
    assert_success

    remote_has_branch "ralph-codex/task-x"
    grep -q $'\t--head\tralph-codex/task-x' "$GH_LOG"
}

# --- PR_DRAFT -----------------------------------------------------------------

@test "PR_DRAFT=true adds --draft to gh pr create" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude PR_DRAFT=true
    make_task_branch "ralph-claude/task-draft"

    run _workspace_push_and_pr "$REPO_NAME" "task-draft" "Draft task"
    assert_success
    grep -q $'\t--draft' "$GH_LOG"
}

@test "PR_DRAFT unset (default) does not add --draft" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-nodraft"

    run _workspace_push_and_pr "$REPO_NAME" "task-nodraft" "No draft"
    assert_success
    ! grep -q $'\t--draft' "$GH_LOG"
}

# --- PR_BASE_BRANCH ---------------------------------------------------------

@test "PR_BASE_BRANCH overrides default 'main' in gh pr create" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude PR_BASE_BRANCH=develop
    make_task_branch "ralph-claude/task-base"

    run _workspace_push_and_pr "$REPO_NAME" "task-base" "Base override"
    assert_success
    grep -q $'\t--base\tdevelop' "$GH_LOG"
}

# --- Missing branch ---------------------------------------------------------

@test "missing branch returns 1, does not push, does not call gh" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    # NO branch created.

    run _workspace_push_and_pr "$REPO_NAME" "ghost-task" "Ghost task"
    assert_failure
    [[ "$output" =~ "branch 'ralph-claude/ghost-task' not found" ]]
    ! remote_has_branch "ralph-claude/ghost-task"
    [[ ! -s "$GH_LOG" ]]
}

# --- Missing remote ---------------------------------------------------------

@test "missing origin remote returns 1 without push or gh" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-noremote"
    (cd "$REPO_DIR" && git remote remove origin)

    run _workspace_push_and_pr "$REPO_NAME" "task-noremote" "No remote"
    assert_failure
    [[ "$output" =~ "no origin remote" ]]
    [[ ! -s "$GH_LOG" ]]
}

# --- gh not on PATH ---------------------------------------------------------

@test "gh not installed: push happens, PR step skipped with warning, returns 0" {
    uninstall_gh_stub
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-nogh"

    run _workspace_push_and_pr "$REPO_NAME" "task-nogh" "No gh"
    assert_success
    remote_has_branch "ralph-claude/task-nogh"
    [[ "$output" =~ "gh CLI not found" ]]
}

# --- Idempotent: PR already exists -------------------------------------------

@test "existing PR is detected and gh pr create is NOT called again" {
    install_gh_stub has-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-exists"

    run _workspace_push_and_pr "$REPO_NAME" "task-exists" "Already PR'd"
    assert_success
    [[ "$output" =~ "PR already exists" ]]
    # gh pr view was called, but gh pr create was NOT
    grep -q $'\tpr\tview' "$GH_LOG"
    ! grep -q $'\tpr\tcreate' "$GH_LOG"
}

# --- Title truncation -------------------------------------------------------

@test "long task description is truncated to 72 chars in --title" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-long"
    local long_desc
    long_desc="$(printf 'x%.0s' {1..200})"

    run _workspace_push_and_pr "$REPO_NAME" "task-long" "$long_desc"
    assert_success
    # Extract --title value from gh log
    local title_field
    title_field=$(awk -F'\t' '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "--title") { print $(i+1); exit }
            }
        }' "$GH_LOG")
    [[ ${#title_field} -le 72 ]]
    [[ "$title_field" == *"..." ]]
}

# --- Empty task description fallback ----------------------------------------

@test "empty task_desc falls back to 'ralph-<engine>: <task_id>' title" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-notitle"

    run _workspace_push_and_pr "$REPO_NAME" "task-notitle" ""
    assert_success
    grep -q $'\t--title\tralph-claude: task-notitle' "$GH_LOG"
}

# --- Missing task_id --------------------------------------------------------

@test "missing task_id returns 1 with warning" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude

    run _workspace_push_and_pr "$REPO_NAME" "" "Some task"
    assert_failure
    [[ "$output" =~ "missing repo_name or task_id" ]]
}

# --- Not a git repo ---------------------------------------------------------

@test "repo_name pointing to non-git dir returns 1" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    mkdir -p "$TEST_TEMP_DIR/nongit"

    run _workspace_push_and_pr "nongit" "task-id" "Task"
    assert_failure
    [[ "$output" =~ "not a git repo" ]]
}

# --- Second invocation is idempotent (rerun after success) -------------------

@test "second invocation after successful first is a no-op idempotent skip" {
    install_gh_stub no-pr
    export RALPH_ENGINE=claude
    make_task_branch "ralph-claude/task-rerun"

    run _workspace_push_and_pr "$REPO_NAME" "task-rerun" "Rerun safe"
    assert_success
    local first_create_count
    first_create_count=$(grep -c $'\tpr\tcreate' "$GH_LOG" || echo 0)
    [[ "$first_create_count" -eq 1 ]]

    # Re-stub gh to report PR exists this time (since first call created it)
    install_gh_stub has-pr

    run _workspace_push_and_pr "$REPO_NAME" "task-rerun" "Rerun safe"
    assert_success
    local total_create_count
    total_create_count=$(grep -c $'\tpr\tcreate' "$GH_LOG" || echo 0)
    [[ "$total_create_count" -eq 1 ]]   # unchanged from before
}
