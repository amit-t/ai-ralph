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

# _split_csv_trimmed — Split a comma-separated string into newline-separated trimmed tokens
# Empty tokens (between consecutive commas) are dropped.
#
# Args:
#   $1 - csv string
# Returns:
#   0 always; one trimmed non-empty token per line on stdout
_split_csv_trimmed() {
    local csv="$1"
    [[ -z "$csv" ]] && return 0
    local IFS_saved="$IFS"
    IFS=',' read -r -a parts <<< "$csv"
    IFS="$IFS_saved"
    local p trimmed
    for p in "${parts[@]}"; do
        trimmed=$(echo "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [[ -z "$trimmed" ]] && continue
        echo "$trimmed"
    done
    return 0
}

# resolve_workspace_filter_spec — Resolve --repos / --exclude / env vars into the
# canonical RALPH_WORKSPACE_REPOS_RESOLVED / RALPH_WORKSPACE_EXCLUDE_RESOLVED env.
#
# Inputs (positional, may be empty):
#   $1 - cli_repos    (comma-separated, from --repos)
#   $2 - cli_exclude  (comma-separated, from --exclude)
# Inputs (env, may be empty):
#   RALPH_WORKSPACE_REPOS    (allowlist)
#   RALPH_WORKSPACE_EXCLUDE  (denylist)
# Outputs (env on success, also exported):
#   RALPH_WORKSPACE_REPOS_RESOLVED    (newline-separated, possibly empty)
#   RALPH_WORKSPACE_EXCLUDE_RESOLVED  (newline-separated, possibly empty)
# Returns:
#   0 - resolution OK (one or none of the two lists non-empty)
#   1 - mutually exclusive sources mixed; error printed to stderr
#
# Resolution rules (per docs/proposals/repos-subset-filter.md §6):
#   1. CLI flag overrides corresponding env var.
#   2. Allowlist and denylist may not both be active across any source.
#      The error message names both sources so the user can correct fast.
resolve_workspace_filter_spec() {
    local cli_repos="${1:-}"
    local cli_exclude="${2:-}"
    local env_repos="${RALPH_WORKSPACE_REPOS:-}"
    local env_exclude="${RALPH_WORKSPACE_EXCLUDE:-}"

    # Mutual exclusion across all sources
    if [[ -n "$cli_repos" && -n "$cli_exclude" ]]; then
        echo "ERROR: --repos and --exclude cannot be combined" >&2
        return 1
    fi
    if [[ -n "$cli_repos" && -n "$env_exclude" ]]; then
        echo "ERROR: --repos conflicts with RALPH_WORKSPACE_EXCLUDE; unset the env var or use --exclude on the CLI" >&2
        return 1
    fi
    if [[ -n "$cli_exclude" && -n "$env_repos" ]]; then
        echo "ERROR: --exclude conflicts with RALPH_WORKSPACE_REPOS; unset the env var or use --repos on the CLI" >&2
        return 1
    fi
    if [[ -z "$cli_repos" && -z "$cli_exclude" && -n "$env_repos" && -n "$env_exclude" ]]; then
        echo "ERROR: RALPH_WORKSPACE_REPOS and RALPH_WORKSPACE_EXCLUDE cannot both be set" >&2
        return 1
    fi

    # CLI wins over env
    local resolved_repos="$cli_repos"
    local resolved_exclude="$cli_exclude"
    [[ -z "$resolved_repos"   && -z "$resolved_exclude" ]] && resolved_repos="$env_repos"
    [[ -z "$resolved_repos"   && -z "$resolved_exclude" ]] && resolved_exclude="$env_exclude"

    RALPH_WORKSPACE_REPOS_RESOLVED=$(_split_csv_trimmed "$resolved_repos")
    RALPH_WORKSPACE_EXCLUDE_RESOLVED=$(_split_csv_trimmed "$resolved_exclude")
    export RALPH_WORKSPACE_REPOS_RESOLVED RALPH_WORKSPACE_EXCLUDE_RESOLVED
    return 0
}

# is_workspace_filter_active — 0 if any filter is active, 1 otherwise.
is_workspace_filter_active() {
    [[ -n "${RALPH_WORKSPACE_REPOS_RESOLVED:-}" ]] && return 0
    [[ -n "${RALPH_WORKSPACE_EXCLUDE_RESOLVED:-}" ]] && return 0
    return 1
}

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

# discover_workspace_repos_filtered — Like discover_workspace_repos but applies the
# allowlist / denylist filter resolved by resolve_workspace_filter_spec().
#
# Reads RALPH_WORKSPACE_REPOS_RESOLVED (allowlist, newline-separated) and
# RALPH_WORKSPACE_EXCLUDE_RESOLVED (denylist, newline-separated) from env.
#
# Validation:
#   - Each name in the allowlist must match a discovered repo. Unknown name ⇒
#     error with the available set listed.
#   - Each name in the denylist must match a discovered repo. Unknown name ⇒
#     error with the available set listed.
#   - After filtering, the resulting set must be non-empty. Empty ⇒ error.
#
# Args:
#   $1 - workspace_dir
# Returns:
#   0 - filtered repo list on stdout
#   1 - validation failure (error on stderr) or no repos discovered
discover_workspace_repos_filtered() {
    local workspace_dir="${1:-.}"
    local all
    all=$(discover_workspace_repos "$workspace_dir") || return 1

    # Fast path: no filter ⇒ return raw discovery (V1 behavior, byte-identical).
    if ! is_workspace_filter_active; then
        echo "$all"
        return 0
    fi

    local available_csv
    available_csv=$(echo "$all" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

    local allow="${RALPH_WORKSPACE_REPOS_RESOLVED:-}"
    local deny="${RALPH_WORKSPACE_EXCLUDE_RESOLVED:-}"

    # Validate every requested name resolves to a discovered repo.
    local name
    if [[ -n "$allow" ]]; then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! echo "$all" | grep -qxF "$name"; then
                echo "ERROR: unknown repo: $name. Available: $available_csv" >&2
                return 1
            fi
        done <<< "$allow"
    fi
    if [[ -n "$deny" ]]; then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! echo "$all" | grep -qxF "$name"; then
                echo "ERROR: unknown repo: $name. Available: $available_csv" >&2
                return 1
            fi
        done <<< "$deny"
    fi

    # Apply filter (allowlist OR denylist; both never set together).
    local filtered=""
    if [[ -n "$allow" ]]; then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if echo "$allow" | grep -qxF "$name"; then
                filtered="${filtered}${name}"$'\n'
            fi
        done <<< "$all"
    elif [[ -n "$deny" ]]; then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! echo "$deny" | grep -qxF "$name"; then
                filtered="${filtered}${name}"$'\n'
            fi
        done <<< "$all"
    else
        filtered="$all"$'\n'
    fi

    # Trim trailing newline
    filtered="${filtered%$'\n'}"

    if [[ -z "$filtered" ]]; then
        echo "ERROR: --repos / --exclude filtered out every repository" >&2
        return 1
    fi

    echo "$filtered"
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
#   $2 - allowed_repos (optional): newline-separated allowlist of repo section
#        names. When non-empty, sections not in the list are skipped and the
#        cross-repo section is also skipped. When empty, V1 behavior (any
#        section eligible).
# Returns:
#   0 - Successfully picked and claimed a task
#   1 - No unclaimed tasks or file missing
pick_workspace_task() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local allowed_repos="${2:-}"

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

        # Filter: when allowed_repos is non-empty, skip cross-repo and any
        # section not in the list. V1 fast path retained when empty.
        if [[ -n "$allowed_repos" ]]; then
            [[ "$current_repo" == "cross-repo" ]] && continue
            if ! echo "$allowed_repos" | grep -qxF "$current_repo"; then
                continue
            fi
        fi

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

    # Check for at least one git repo. When a filter is active we use the
    # filtered wrapper so the validation message reflects the actual scope.
    # Stderr is preserved for the filtered path so unknown-name / empty-set
    # errors reach the caller.
    local repos
    if is_workspace_filter_active; then
        repos=$(discover_workspace_repos_filtered "$workspace_dir") || return 1
    else
        repos=$(discover_workspace_repos "$workspace_dir" 2>/dev/null)
    fi
    if [[ -z "$repos" ]]; then
        echo "ERROR: No git repositories found in workspace: $workspace_dir" >&2
        return 1
    fi

    # Warn about repos referenced in fix_plan.md but not on disk. When a filter
    # is active, only warn for in-scope repos so excluded ones do not generate
    # noise.
    local plan_repos
    plan_repos=$(grep -E '^#{2,3} [A-Za-z0-9]' "$workspace_dir/.ralph/fix_plan.md" 2>/dev/null \
        | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')

    while IFS= read -r plan_repo; do
        [[ -z "$plan_repo" ]] && continue
        [[ "$plan_repo" == "cross-repo" ]] && continue
        if is_workspace_filter_active; then
            if ! echo "$repos" | grep -qxF "$plan_repo"; then
                continue
            fi
        fi
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
#   $4 - allowed_repos (optional): newline-separated allowlist; sections not in
#        the list are excluded from the count.
# Returns:
#   0 - Limit on stdout
get_workspace_parallel_limit() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local workspace_dir="${2:-.}"
    local requested="${3:-0}"
    local allowed_repos="${4:-}"

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
                    # Skip repos not in filter (when filter active)
                    if [[ -z "$allowed_repos" ]] || echo "$allowed_repos" | grep -qxF "$prev_repo"; then
                        repos_with_pending+=("$prev_repo")
                    fi
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
            if [[ -z "$allowed_repos" ]] || echo "$allowed_repos" | grep -qxF "$prev_repo"; then
                repos_with_pending+=("$prev_repo")
            fi
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
#   $3 - allowed_repos (optional): newline-separated allowlist of repo section
#        names. When non-empty, sections not in the list are skipped (cross-repo
#        is already skipped unconditionally below). Empty ⇒ V1 behavior.
# Returns:
#   0 - Picked at least one task
#   1 - No tasks available
pick_workspace_tasks_parallel() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local max_count="${2:-1}"
    local allowed_repos="${3:-}"

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
        # Skip repos not in filter (when filter active)
        if [[ -n "$allowed_repos" ]]; then
            if ! echo "$allowed_repos" | grep -qxF "$current_repo"; then
                continue
            fi
        fi
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
    local allowed_repos="${5:-}"

    if [[ -z "$executor_fn" ]]; then
        echo "ERROR: No executor function specified" >&2
        return 1
    fi

    # Pick tasks
    local task_output
    task_output=$(pick_workspace_tasks_parallel "$fix_plan_file" "$max_count" "$allowed_repos")
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

# =============================================================================
# WORKSPACE WORKTREE / QUALITY GATES / PR — Per-repo orchestration
# =============================================================================
#
# These functions integrate worktree isolation, quality gates, and PR creation
# into workspace mode. Each repo task gets its own worktree branch; after the
# AI finishes, quality gates run inside the worktree and a PR is created.
#
# The existing worktree_manager.sh and pr_manager.sh functions are reused —
# they operate on module-level _WT_* state variables, which is safe because:
#   - Sequential mode: one repo at a time, state is reset between repos
#   - Parallel mode: each worker runs in a forked subshell with its own state

# workspace_repo_worktree_init — Initialize worktree system for a single repo
# Must be called from within the repo directory (or with repo_path).
# Sets up _WT_* state variables for the repo.
#
# Args:
#   $1 - repo_path: Absolute path to the repository
# Returns: 0 on success, 1 on failure
workspace_repo_worktree_init() {
    local repo_path="$1"

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "ERROR: Not a git repository: $repo_path" >&2
        return 1
    fi

    # worktree_init() sets _WT_* state variables that must survive in the caller,
    # so we cd into the repo in the current shell and restore afterward.
    local _saved_pwd="$PWD"
    cd "$repo_path" || return 1
    worktree_init
    local _result=$?
    cd "$_saved_pwd" || true
    return $_result
}

# workspace_repo_worktree_create — Create a worktree for a workspace repo task
# Args:
#   $1 - repo_path: Absolute path to the repository
#   $2 - task_id: Task identifier for branch naming
# Returns: 0 on success (worktree path available via worktree_get_path), 1 on failure
workspace_repo_worktree_create() {
    local repo_path="$1"
    local task_id="$2"

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "ERROR: Not a git repository: $repo_path" >&2
        return 1
    fi

    # worktree_init and worktree_create must run in the repo context.
    # IMPORTANT: Do NOT wrap in $() — that loses _WT_* state variables.
    cd "$repo_path" || return 1
    worktree_init || return 1
    worktree_create 1 "$task_id" > /dev/null || return 1
    cd - > /dev/null 2>&1 || true
    return 0
}

# workspace_repo_run_quality_gates — Run quality gates for a workspace repo
# Delegates to worktree_run_quality_gates() which uses _WT_CURRENT_PATH.
# If no worktree is active, runs gates directly in the repo directory.
#
# Args:
#   $1 - repo_path: Absolute path to the repository (used as fallback)
# Returns: 0 if all gates pass, 1 if any fail
workspace_repo_run_quality_gates() {
    local repo_path="$1"

    if worktree_is_active; then
        worktree_run_quality_gates
    else
        # No worktree — run gates directly in repo dir.
        # Temporarily set _WT_CURRENT_PATH so worktree_run_quality_gates can find the dir.
        local _saved_wt_path="$_WT_CURRENT_PATH"
        _WT_CURRENT_PATH="$repo_path"
        worktree_run_quality_gates
        local result=$?
        _WT_CURRENT_PATH="$_saved_wt_path"
        return $result
    fi
}

# workspace_repo_commit_and_pr — Commit, push, and create PR for a workspace repo task
# Uses either worktree_commit_and_pr (if worktree active) or worktree_fallback_branch_pr.
#
# Args:
#   $1 - repo_path: Absolute path to the repository
#   $2 - task_id: Task identifier
#   $3 - task_name: Human-readable task description
#   $4 - gate_passed: "true" or "false"
# Returns: 0 on success, 1 on failure
workspace_repo_commit_and_pr() {
    local repo_path="$1"
    local task_id="$2"
    local task_name="$3"
    local gate_passed="$4"

    # Run PR preflight from inside the repo.
    # pr_preflight_check sets RALPH_PR_PUSH_CAPABLE and RALPH_PR_GH_CAPABLE
    # which must survive in the current shell.
    local _saved_pwd="$PWD"
    cd "$repo_path" || return 1
    pr_preflight_check
    cd "$_saved_pwd" || true

    if worktree_is_active; then
        worktree_commit_and_pr "$task_id" "$task_name" "$gate_passed" "1"
    else
        # No worktree — use fallback branch PR from inside the repo
        cd "$repo_path" || return 1
        worktree_fallback_branch_pr "$task_id" "$task_name" "1" "$gate_passed"
        local _result=$?
        cd "$_saved_pwd" || true
        return $_result
    fi
}

# workspace_repo_cleanup — Clean up worktree for a workspace repo
# Syncs state back and removes the worktree, preserving the branch for PR.
#
# Args:
#   $1 - repo_path: Absolute path to the repository
# Returns: 0
workspace_repo_cleanup() {
    local repo_path="$1"

    if worktree_is_active; then
        # Preserve branch (false = don't delete) — PR needs the branch.
        # worktree_cleanup uses git commands that need the repo context.
        local _saved_pwd="$PWD"
        cd "$repo_path" || return 0
        worktree_cleanup "false"
        cd "$_saved_pwd" || true
    fi
    return 0
}

# pick_workspace_task_for_pool — Skip-list-aware variant of pick_workspace_task
# for use by the continuous worker pool (see lib/worker_pool.sh).
#
# Skip-list semantics (must match _continuous_skip_key in lib/worker_pool.sh):
#   The worker pool skip-lists a workspace task by inserting
#   `repo|task_id|line` — the three identifying fields of the descriptor
#   (the description is dropped). So the picker must compute the same
#   `repo|task_id|line` key from its candidate BEFORE marking `[~]`, and
#   skip if it matches.
#
#   Earlier (buggy) versions of this function:
#     1. Checked `skip_list` against the bare line number — silent no-op
#        (orchestrator inserted descriptor prefixes).
#     2. Then briefly checked `${candidate_desc%% *}` (first-space-prefix
#        of `repo|task_id|line|description`) — silently mis-matched when
#        the description's first word changed between picks (P1 #8).
#   Do not revert to either form without realigning worker_pool.sh's
#   insertion logic too — _continuous_skip_key is the canonical source.
#
# Args:
#   $1 - fix_plan_file: Path to workspace fix_plan.md
#   $2 - skip_list:     Newline-separated list of `repo|task_id|line` keys.
#   $3 - allowed_repos (optional): newline-separated allowlist of repo
#        section names (same semantics as pick_workspace_task's $2). When
#        non-empty, cross-repo and any section not in the list are skipped.
# Output (stdout): repo_name|task_id|line_num|task_description (same as pick_workspace_task)
# Returns: 0 on success, 1 if no eligible tasks remain.
pick_workspace_task_for_pool() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    local skip_list="${2:-}"
    local allowed_repos="${3:-}"

    if [[ ! -f "$fix_plan_file" ]]; then
        return 1
    fi

    # Acquire the same lock used by pick_workspace_task so concurrent picks
    # remain atomic.
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

        if echo "$line" | grep -qE '^#{2,3} [A-Za-z0-9]'; then
            current_repo=$(echo "$line" | sed 's/^#\{2,3\} *//' | sed 's/[[:space:]]*$//')
            continue
        fi

        [[ -z "$current_repo" ]] && continue
        [[ "$current_repo" == "cross-repo" ]] && continue

        # Filter: when allowed_repos is non-empty, skip any section not in
        # the list. Matches pick_workspace_task's V1 behavior so --repos /
        # --exclude are honored in continuous mode too.
        if [[ -n "$allowed_repos" ]]; then
            if ! echo "$allowed_repos" | grep -qxF "$current_repo"; then
                continue
            fi
        fi

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

            # Skip-list check (P1 #8): compute the same `repo|task_id|line`
            # key the worker pool's _continuous_skip_key emits, so skip_list
            # entries match 1:1 regardless of how the task description looks.
            local candidate_desc="${current_repo}|${task_id}|${line_num}|${task_desc}"
            local candidate_token="${current_repo}|${task_id}|${line_num}"
            if [[ -n "$skip_list" ]] && echo "$skip_list" | grep -qxF "$candidate_token"; then
                continue
            fi

            local tmp_file="${fix_plan_file}.tmp.$$"
            awk -v ln="$line_num" 'NR==ln { sub(/- \[ \]/, "- [~]") } 1' "$fix_plan_file" > "$tmp_file" \
                && mv "$tmp_file" "$fix_plan_file"

            echo "$candidate_desc"
            found=0
            break
        fi
    done < "$fix_plan_file"

    if command -v _release_task_lock &>/dev/null; then
        _release_task_lock "$lock_dir"
    else
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    return $found
}

# Export all functions for use in subshells
export -f _split_csv_trimmed
export -f resolve_workspace_filter_spec
export -f is_workspace_filter_active
export -f discover_workspace_repos
export -f discover_workspace_repos_filtered
export -f parse_workspace_fix_plan
export -f pick_workspace_task
export -f pick_workspace_task_for_pool
export -f get_repo_default_branch
export -f validate_workspace
export -f build_workspace_repo_context
export -f mark_workspace_task_complete
export -f revert_workspace_task
export -f is_workspace_mode
export -f get_workspace_parallel_limit
export -f pick_workspace_tasks_parallel
export -f run_workspace_tasks_parallel
export -f workspace_repo_worktree_init
export -f workspace_repo_worktree_create
export -f workspace_repo_run_quality_gates
export -f workspace_repo_commit_and_pr
export -f workspace_repo_cleanup
