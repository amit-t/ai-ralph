#!/usr/bin/env bash
# workspace_continuous_pr.sh
# -----------------------------------------------------------------------------
# Shared helper for the per-engine workspace continuous executors
# (_continuous_workspace_executor in ralph_loop.sh, devin/ralph_loop_devin.sh,
# codex/ralph_loop_codex.sh).
#
# Why this exists:
#   The per-engine _workspace_execute_task already runs a push + PR step via
#   workspace_repo_commit_and_pr -> worktree_commit_and_pr after the engine
#   commits. In live runs that chain can silently no-op (worktree state lost
#   to a subshell, preflight failing without a surfaced warning, an engine
#   that committed outside the worktree). When that happens, the workspace
#   continuous executor marks the task complete and returns 0, leaving the
#   per-task branch only on the local clone — no remote branch, no PR — and
#   the fix_plan row [x]'d so retry won't pick it up.
#
#   _workspace_push_and_pr is the executor-level safety net: after the inner
#   task helper returns 0, the executor calls this function, which:
#     - confirms the expected per-task branch exists locally,
#     - pushes it to origin (idempotent if already pushed),
#     - opens a PR via gh (idempotent if one already exists).
#
#   It is **never** allowed to block fix-plan completion. The caller treats
#   a non-zero return as "log + continue"; the engine's commit on the local
#   branch is recoverable by hand even if push/PR fails.

# _workspace_push_and_pr — post-success hook for workspace continuous executors.
#
# Required globals (set by the engine loop before the executor runs):
#   RALPH_ENGINE   "claude" | "devin" | "codex"  — used for branch prefix
#   PWD            workspace root (per-repo clones live at $(pwd)/$repo_name)
#
# Honors (read from the engine loop's loaded .ralphrc):
#   PR_ENABLED=false  → returns 0 without push/PR
#   PR_DRAFT=true     → `gh pr create --draft`
#   PR_BASE_BRANCH    → `--base`, default "main"
#
# Args:
#   $1 - repo_name    Name of the workspace repo (subdir of $PWD)
#   $2 - task_id      Task identifier (used as branch suffix)
#   $3 - task_desc    Human-readable task description (used as PR title)
#
# Returns:
#   0 on success or graceful skip (PR_ENABLED=false, gh missing, PR exists).
#   1 on push or PR-creation failure. Caller MUST log and continue; the
#     local commit is preserved so the user can salvage manually.
_workspace_push_and_pr() {
    local repo_name="$1"
    local task_id="$2"
    local task_desc="$3"
    local engine="${RALPH_ENGINE:-ralph}"

    # Resolve log_status to a fallback if the engine loop hasn't sourced it.
    if ! declare -F log_status >/dev/null 2>&1; then
        log_status() { echo "[$1] $2" >&2; }
    fi

    if [[ -z "$repo_name" || -z "$task_id" ]]; then
        log_status "WARN" "[ws-pr] missing repo_name or task_id; skipping"
        return 1
    fi

    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        return 0
    fi

    local repo_dir="$PWD/${repo_name}"
    local branch_name="ralph-${engine}/${task_id}"

    if [[ ! -d "$repo_dir/.git" ]] && ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        log_status "WARN" "[ws-pr] not a git repo: $repo_dir; skipping PR for $task_id"
        return 1
    fi

    if ! git -C "$repo_dir" rev-parse --verify --quiet "refs/heads/$branch_name" >/dev/null 2>&1; then
        log_status "WARN" "[ws-pr] branch '$branch_name' not found in $repo_dir; skipping PR"
        return 1
    fi

    if ! git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
        log_status "WARN" "[ws-pr] no origin remote in $repo_dir; cannot push $branch_name"
        return 1
    fi

    local push_out
    if ! push_out=$(git -C "$repo_dir" push -u origin "$branch_name" 2>&1); then
        log_status "ERROR" "[ws-pr] git push failed for $branch_name: $push_out"
        return 1
    fi
    log_status "INFO" "[ws-pr] pushed $branch_name (${repo_name})"

    if ! command -v gh >/dev/null 2>&1; then
        log_status "WARN" "[ws-pr] gh CLI not found; branch pushed but PR not created"
        return 0
    fi

    # Idempotent: if a PR already exists for this branch, don't try to recreate it.
    local existing_url
    existing_url=$(cd "$repo_dir" && gh pr view "$branch_name" --json url --jq .url 2>/dev/null || true)
    if [[ -n "$existing_url" ]]; then
        log_status "INFO" "[ws-pr] PR already exists for $branch_name: $existing_url"
        return 0
    fi

    local base="${PR_BASE_BRANCH:-main}"
    local title="$task_desc"
    if [[ -z "$title" ]]; then
        title="ralph-${engine}: ${task_id}"
    fi
    if [[ ${#title} -gt 72 ]]; then
        title="${title:0:69}..."
    fi

    local body
    body=$(printf 'Authored by ralph-%s (workspace continuous mode).\n\nTask: %s\nRepo: %s\nBranch: %s\n' \
        "$engine" "$task_id" "$repo_name" "$branch_name")

    local pr_args=(--base "$base" --head "$branch_name" --title "$title" --body "$body")
    if [[ "${PR_DRAFT:-false}" == "true" ]]; then
        pr_args+=(--draft)
    fi

    local pr_url
    if pr_url=$(cd "$repo_dir" && gh pr create "${pr_args[@]}" 2>&1); then
        log_status "SUCCESS" "[ws-pr] PR opened for $branch_name: $pr_url"
        return 0
    else
        log_status "ERROR" "[ws-pr] gh pr create failed for $branch_name: $pr_url"
        return 1
    fi
}
export -f _workspace_push_and_pr
