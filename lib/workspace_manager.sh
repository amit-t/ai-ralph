#!/bin/bash
# lib/workspace_manager.sh — Multi-repo workspace orchestration
#
# Provides functions for discovering git repositories in a workspace directory,
# parsing workspace-level fix_plan.md with per-repo task sections, and managing
# task lifecycle across multiple repositories.
#
# Workspace fix_plan.md format:
#   # Workspace Fix Plan
#
#   ## repo-alpha
#   - [ ] Task for repo-alpha
#   - [ ] Another task
#
#   ## repo-beta
#   - [ ] Task for repo-beta
#
#   ## cross-repo
#   - [ ] Task spanning multiple repos

# discover_workspace_repos — Find git repositories (directories containing .git/) in a workspace
# Outputs one repo name per line, sorted alphabetically.
# Skips hidden directories (starting with .) and the .ralph directory itself.
#
# Args:
#   $1 - workspace_dir: Path to the workspace directory
# Returns:
#   0 - Found at least one repo (names on stdout)
#   1 - No repos found or directory doesn't exist
discover_workspace_repos() {
    local workspace_dir="${1:-.}"

    if [[ ! -d "$workspace_dir" ]]; then
        echo "ERROR: Directory not found: $workspace_dir" >&2
        return 1
    fi

    local found=0
    local repos=()

    for entry in "$workspace_dir"/*/; do
        # Skip if glob didn't match anything
        [[ -d "$entry" ]] || continue

        local dirname
        dirname=$(basename "$entry")

        # Skip hidden directories
        [[ "$dirname" == .* ]] && continue

        # Check for .git directory (indicating a git repo)
        if [[ -d "$entry/.git" ]]; then
            repos+=("$dirname")
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        return 1
    fi

    # Sort and output
    printf '%s\n' "${repos[@]}" | sort
    return 0
}

# parse_workspace_fix_plan — Extract pending tasks grouped by repo from workspace fix_plan.md
# Parses ## or ### section headers as repo names, then collects unclaimed ([ ]) tasks
# under each section.
#
# Output format (one line per pending task):
#   repo_name|line_number|task_description
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
# Returns:
#   0 - Found at least one pending task
#   1 - No pending tasks found or file missing
parse_workspace_fix_plan() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"

    if [[ ! -f "$fix_plan_file" ]]; then
        echo "ERROR: File not found: $fix_plan_file" >&2
        return 1
    fi

    local current_repo=""
    local line_num=0
    local found=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Match section headers: ## repo-name or ### repo-name
        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            # Extract repo name (strip ## or ### prefix and trim whitespace)
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            continue
        fi

        # Skip lines without a current repo context
        [[ -z "$current_repo" ]] && continue

        # Match unclaimed, top-level tasks: "- [ ] ..." (not indented subtasks)
        if echo "$line" | grep -qE '^- \[ \] '; then
            local task_desc
            task_desc=$(echo "$line" | sed 's/^- \[ \] //')
            echo "${current_repo}|${line_num}|${task_desc}"
            found=1
        fi
    done < "$fix_plan_file"

    if [[ $found -eq 0 ]]; then
        return 1
    fi
    return 0
}

# pick_workspace_task — Pick the first unclaimed task from workspace fix_plan.md
# Atomically marks the task as in-progress [~] to prevent parallel conflicts.
#
# Output format:
#   repo_name|task_id|line_num|task_description
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
# Returns:
#   0 - Successfully picked and claimed a task
#   1 - No unclaimed tasks or file missing
pick_workspace_task() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"

    if [[ ! -f "$fix_plan_file" ]]; then
        return 1
    fi

    # Acquire lock to prevent parallel agents from picking the same task
    local lock_dir
    lock_dir="$(dirname "$fix_plan_file")/.workspace_task_lock"
    if command -v _acquire_task_lock &>/dev/null; then
        if ! _acquire_task_lock "$lock_dir"; then
            echo "WARN: Could not acquire workspace task lock after timeout" >&2
            return 1
        fi
    else
        mkdir "$lock_dir" 2>/dev/null || true
    fi

    local current_repo=""
    local line_num=0
    local found=1

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Match section headers: ## repo-name or ### repo-name
        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            continue
        fi

        [[ -z "$current_repo" ]] && continue

        # Match unclaimed, top-level tasks: "- [ ] ..."
        if echo "$line" | grep -qE '^- \[ \] '; then
            local task_desc
            task_desc=$(echo "$line" | sed 's/^- \[ \] //')

            # Extract bead ID if present: "- [ ] [some-id] Title"
            local bead_id=""
            bead_id=$(echo "$line" | sed -n 's/.*\[ \] \[\([a-zA-Z0-9_-]*\)\].*/\1/p' | head -1)

            # Build task_id from bead_id or sanitized description
            local task_id=""
            if [[ -n "$bead_id" ]]; then
                task_id="$bead_id"
            else
                task_id=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | head -c 50)
            fi

            # Atomically mark in-progress
            local tmp_file="${fix_plan_file}.tmp.$$"
            awk -v ln="$line_num" 'NR==ln { sub(/- \[ \]/, "- [~]") } 1' "$fix_plan_file" > "$tmp_file" \
                && mv "$tmp_file" "$fix_plan_file"

            echo "${current_repo}|${task_id}|${line_num}|${task_desc}"
            found=0
            break
        fi
    done < "$fix_plan_file"

    # Release lock
    if command -v _release_task_lock &>/dev/null; then
        _release_task_lock "$lock_dir"
    else
        rmdir "$lock_dir" 2>/dev/null || true
    fi

    return $found
}

# get_repo_default_branch — Detect the default branch of a git repository
# Uses git symbolic-ref to get current HEAD branch name.
#
# Args:
#   $1 - repo_path: Path to the git repository
# Returns:
#   0 - Branch name on stdout
#   1 - Not a git repo or detection failed
get_repo_default_branch() {
    local repo_path="${1:-.}"

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "ERROR: Not a git repository: $repo_path" >&2
        return 1
    fi

    local branch
    branch=$(cd "$repo_path" && git symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$branch" ]]; then
        branch=$(cd "$repo_path" && git config init.defaultBranch 2>/dev/null || echo "main")
    fi

    echo "$branch"
    return 0
}

# validate_workspace — Check that a workspace has valid structure
# Validates: .ralph/fix_plan.md exists, at least one git repo found,
# and warns about repos referenced in fix_plan but not on disk.
#
# Args:
#   $1 - workspace_dir: Path to the workspace directory
# Returns:
#   0 - Valid workspace
#   1 - Invalid workspace (missing components)
validate_workspace() {
    local workspace_dir="${1:-.}"

    # Check for .ralph/fix_plan.md
    if [[ ! -f "$workspace_dir/.ralph/fix_plan.md" ]]; then
        echo "ERROR: No .ralph/fix_plan.md found in workspace" >&2
        return 1
    fi

    # Check for at least one git repo
    local repos
    repos=$(discover_workspace_repos "$workspace_dir" 2>/dev/null)
    if [[ -z "$repos" ]]; then
        echo "ERROR: No git repositories found in workspace: $workspace_dir" >&2
        return 1
    fi

    # Warn about repos referenced in fix_plan.md but not on disk
    local plan_repos
    plan_repos=$(grep -E '^#{2,3} [A-Za-z0-9]' "$workspace_dir/.ralph/fix_plan.md" 2>/dev/null \
        | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')

    while IFS= read -r plan_repo; do
        [[ -z "$plan_repo" ]] && continue
        # Skip special sections like "cross-repo"
        [[ "$plan_repo" == "cross-repo" ]] && continue
        if [[ ! -d "$workspace_dir/$plan_repo" ]]; then
            echo "WARN: Repository '$plan_repo' referenced in fix_plan.md but not found on disk" >&2
        fi
    done <<< "$plan_repos"

    echo "Workspace valid: $(echo "$repos" | wc -l | tr -d ' ') repositories found"
    return 0
}

# build_workspace_repo_context — Build AI context for working in a specific repo
# Creates a context string that includes repo name, task description, and
# working directory constraint.
#
# Args:
#   $1 - repo_name: Name of the target repository
#   $2 - task_description: Description of the task to perform
#   $3 - workspace_dir: Path to the workspace root
# Returns:
#   0 - Context string on stdout
build_workspace_repo_context() {
    local repo_name="${1}"
    local task_description="${2}"
    local workspace_dir="${3:-.}"

    local repo_path
    if [[ "$workspace_dir" == "." ]]; then
        repo_path="$(pwd)/${repo_name}"
    else
        repo_path="${workspace_dir}/${repo_name}"
    fi

    cat << EOF
# Workspace Mode — Repository Task Assignment

You are working in **workspace mode** across multiple repositories.

## Current Assignment
- **Repository**: \`${repo_name}\`
- **Working Directory**: \`${repo_path}\`
- **Task**: ${task_description}

## Constraints
- All file edits, git operations, and shell commands **MUST** stay within \`${repo_path}\`
- Do NOT navigate to or modify files in sibling repositories or the workspace root
- Run \`pwd\` before any file operation to confirm you are in the correct directory
- Commit your changes to a new branch (not the default branch)
EOF

    return 0
}

# mark_workspace_task_complete — Mark a specific task as completed in workspace fix_plan.md
# Changes "- [~]" to "- [x]" on the specified line number.
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - line_num: 1-based line number to mark
# Returns:
#   0 on success, 1 on error
mark_workspace_task_complete() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local line_num="${2}"

    if [[ -z "$line_num" || ! -f "$fix_plan_file" ]]; then
        return 1
    fi

    local tmp_file="${fix_plan_file}.tmp.$$"
    awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [x]") } 1' "$fix_plan_file" > "$tmp_file" \
        && mv "$tmp_file" "$fix_plan_file"
    return $?
}

# revert_workspace_task — Revert an in-progress task back to unclaimed
# Changes "- [~]" to "- [ ]" on the specified line number.
# Used when a task fails or produces no changes.
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - line_num: 1-based line number to revert
# Returns:
#   0 on success, 1 on error
revert_workspace_task() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local line_num="${2}"

    if [[ -z "$line_num" || ! -f "$fix_plan_file" ]]; then
        return 1
    fi

    local tmp_file="${fix_plan_file}.tmp.$$"
    awk -v ln="$line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "$fix_plan_file" > "$tmp_file" \
        && mv "$tmp_file" "$fix_plan_file"
    return $?
}

# is_workspace_mode — Detect if a directory is a workspace (not a single git repo)
# A workspace has: .ralph/fix_plan.md AND child git repos AND is NOT itself a git repo.
#
# Args:
#   $1 - dir: Directory to check
# Returns:
#   0 - Is a workspace
#   1 - Is not a workspace
is_workspace_mode() {
    local dir="${1:-.}"

    # Must have .ralph/fix_plan.md
    [[ -f "$dir/.ralph/fix_plan.md" ]] || return 1

    # Must NOT be a git repo itself (workspace root is NOT a repo)
    [[ ! -d "$dir/.git" ]] || return 1

    # Must have at least one child git repo
    local has_repo=false
    for entry in "$dir"/*/; do
        [[ -d "$entry" ]] || continue
        local dirname
        dirname=$(basename "$entry")
        [[ "$dirname" == .* ]] && continue
        if [[ -d "$entry/.git" ]]; then
            has_repo=true
            break
        fi
    done

    $has_repo || return 1
    return 0
}

# Export all functions for use in subshells
export -f discover_workspace_repos
export -f parse_workspace_fix_plan
export -f pick_workspace_task
export -f get_repo_default_branch
export -f validate_workspace
export -f build_workspace_repo_context
export -f mark_workspace_task_complete
export -f revert_workspace_task
export -f is_workspace_mode
