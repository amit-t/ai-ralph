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

# get_workspace_parallel_limit — Determine max parallelism for workspace execution
# Returns the minimum of: repos with pending tasks, requested count, and actual repos on disk.
# When requested count is 0, auto-selects based on available repos with pending tasks.
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - workspace_dir: Path to the workspace directory
#   $3 - requested: Requested parallelism (0 = auto)
# Returns:
#   0 - Limit on stdout
get_workspace_parallel_limit() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local workspace_dir="${2:-.}"
    local requested="${3:-0}"

    # Collect unique repos that have at least one pending task and no in-progress task
    local repos_with_pending=()
    local current_repo=""
    local repo_has_pending=false
    local repo_has_inprogress=false
    local prev_repo=""

    while IFS= read -r line; do
        # Match section headers
        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            # Flush previous repo
            if [[ -n "$prev_repo" ]] && $repo_has_pending && ! $repo_has_inprogress; then
                # Skip cross-repo section
                if [[ "$prev_repo" != "cross-repo" ]]; then
                    repos_with_pending+=("$prev_repo")
                fi
            fi
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            prev_repo="$current_repo"
            repo_has_pending=false
            repo_has_inprogress=false
            continue
        fi

        [[ -z "$current_repo" ]] && continue

        # Check for in-progress tasks
        if echo "$line" | grep -qE '^- \[~\] '; then
            repo_has_inprogress=true
        fi

        # Check for pending tasks (top-level only)
        if echo "$line" | grep -qE '^- \[ \] '; then
            repo_has_pending=true
        fi
    done < "$fix_plan_file"

    # Flush last repo
    if [[ -n "$prev_repo" ]] && $repo_has_pending && ! $repo_has_inprogress; then
        if [[ "$prev_repo" != "cross-repo" ]]; then
            repos_with_pending+=("$prev_repo")
        fi
    fi

    local available=${#repos_with_pending[@]}

    if [[ "$requested" -eq 0 ]]; then
        echo "$available"
    elif [[ "$requested" -lt "$available" ]]; then
        echo "$requested"
    else
        echo "$available"
    fi
    return 0
}

# pick_workspace_tasks_parallel — Pick up to N tasks, one per repo, for parallel execution
# Skips repos that already have in-progress tasks and the cross-repo section.
# Atomically marks each picked task as in-progress [~].
#
# Output format (one line per picked task):
#   repo_name|task_id|line_num|task_description
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - max_count: Maximum number of tasks to pick
# Returns:
#   0 - Picked at least one task
#   1 - No tasks available
pick_workspace_tasks_parallel() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local max_count="${2:-1}"

    if [[ ! -f "$fix_plan_file" ]]; then
        return 1
    fi

    # First pass: identify repos that already have in-progress tasks
    # Store as newline-separated list for bash 3.x compatibility (no associative arrays)
    local repos_in_progress=""
    local current_repo=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            continue
        fi
        [[ -z "$current_repo" ]] && continue
        if echo "$line" | grep -qE '^- \[~\] '; then
            repos_in_progress="${repos_in_progress}${current_repo}"$'\n'
        fi
    done < "$fix_plan_file"

    # Second pass: collect eligible tasks (one per repo, skip cross-repo and in-progress repos)
    local repos_picked=""
    local picked_count=0
    local tasks=()
    local task_lines=()
    current_repo=""
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            continue
        fi

        [[ -z "$current_repo" ]] && continue
        # Skip cross-repo section
        [[ "$current_repo" == "cross-repo" ]] && continue
        # Skip repos with in-progress tasks
        if echo "$repos_in_progress" | grep -qxF "$current_repo"; then
            continue
        fi
        # Skip repos already picked
        if echo "$repos_picked" | grep -qxF "$current_repo"; then
            continue
        fi

        # Match unclaimed top-level task
        if echo "$line" | grep -qE '^- \[ \] '; then
            local task_desc
            task_desc=$(echo "$line" | sed 's/^- \[ \] //')

            local bead_id=""
            bead_id=$(echo "$line" | sed -n 's/.*\[ \] \[\([a-zA-Z0-9_-]*\)\].*/\1/p' | head -1)

            local task_id=""
            if [[ -n "$bead_id" ]]; then
                task_id="$bead_id"
            else
                task_id=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | head -c 50)
            fi

            tasks+=("${current_repo}|${task_id}|${line_num}|${task_desc}")
            task_lines+=("$line_num")
            repos_picked="${repos_picked}${current_repo}"$'\n'
            picked_count=$((picked_count + 1))

            if [[ "$picked_count" -ge "$max_count" ]]; then
                break
            fi
        fi
    done < "$fix_plan_file"

    if [[ "$picked_count" -eq 0 ]]; then
        return 1
    fi

    # Atomically mark all picked tasks as in-progress
    local awk_cond=""
    for ln in "${task_lines[@]}"; do
        if [[ -n "$awk_cond" ]]; then
            awk_cond="${awk_cond} || "
        fi
        awk_cond="${awk_cond}NR==${ln}"
    done

    local tmp_file="${fix_plan_file}.tmp.$$"
    awk "($awk_cond) { sub(/- \\[ \\]/, \"- [~]\") } 1" "$fix_plan_file" > "$tmp_file" \
        && mv "$tmp_file" "$fix_plan_file"

    # Output all picked tasks
    for task in "${tasks[@]}"; do
        echo "$task"
    done

    return 0
}

# run_workspace_tasks_parallel — Execute workspace tasks in parallel via background subshells
# Picks up to N tasks (one per repo), spawns a background worker for each, waits for
# completion, then marks succeeded tasks as [x] and reverts failed tasks to [ ].
#
# The executor function receives: repo_name, task_description, workspace_dir
# and should return 0 on success, non-zero on failure.
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - workspace_dir: Path to the workspace root
#   $3 - max_count: Maximum number of parallel tasks
#   $4 - executor_fn: Name of the function to call for each task
# Returns:
#   0 - All tasks completed successfully
#   1 - Some tasks failed (partial success)
run_workspace_tasks_parallel() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local workspace_dir="${2:-.}"
    local max_count="${3:-1}"
    local executor_fn="${4}"

    if [[ -z "$executor_fn" ]]; then
        echo "ERROR: No executor function specified" >&2
        return 1
    fi

    # Pick tasks
    local task_output
    task_output=$(pick_workspace_tasks_parallel "$fix_plan_file" "$max_count")
    local pick_rc=$?
    if [[ $pick_rc -ne 0 || -z "$task_output" ]]; then
        echo "No tasks available for parallel execution" >&2
        return 1
    fi

    # Create log directory
    local log_dir
    if [[ "$workspace_dir" == "." ]]; then
        log_dir="$(pwd)/.ralph/logs/parallel"
    else
        log_dir="${workspace_dir}/.ralph/logs/parallel"
    fi
    mkdir -p "$log_dir"

    # Spawn a background worker for each task
    local -a pids=()
    local -a task_repos=()
    local -a task_line_nums=()
    local -a task_descs=()

    while IFS= read -r task_line; do
        local repo_name task_id line_num task_desc
        repo_name=$(echo "$task_line" | cut -d'|' -f1)
        task_id=$(echo "$task_line" | cut -d'|' -f2)
        line_num=$(echo "$task_line" | cut -d'|' -f3)
        task_desc=$(echo "$task_line" | cut -d'|' -f4)

        local log_file="${log_dir}/ws_worker_${repo_name}_$$.log"

        # Spawn background worker
        (
            "$executor_fn" "$repo_name" "$task_desc" "$workspace_dir"
        ) > "$log_file" 2>&1 &

        pids+=($!)
        task_repos+=("$repo_name")
        task_line_nums+=("$line_num")
        task_descs+=("$task_desc")
    done <<< "$task_output"

    # Wait for all workers and collect exit codes
    local -a exit_codes=()
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
        exit_codes+=($?)
    done

    # Mark tasks complete or revert based on exit codes
    local failed=0
    local succeeded=0
    for i in "${!exit_codes[@]}"; do
        if [[ "${exit_codes[$i]}" -eq 0 ]]; then
            mark_workspace_task_complete "$fix_plan_file" "${task_line_nums[$i]}"
            succeeded=$((succeeded + 1))
        else
            revert_workspace_task "$fix_plan_file" "${task_line_nums[$i]}"
            failed=$((failed + 1))
            echo "WARN: Task failed in ${task_repos[$i]}: ${task_descs[$i]} (reverted)" >&2
        fi
    done

    local total=$((succeeded + failed))
    echo "Parallel workspace: ${succeeded}/${total} tasks completed, ${failed} failed"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
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
export -f get_workspace_parallel_limit
export -f pick_workspace_tasks_parallel
export -f run_workspace_tasks_parallel
