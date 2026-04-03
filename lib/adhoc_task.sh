#!/bin/bash
# lib/adhoc_task.sh -- Ad-hoc task mode: interactive one-liner to fix_plan entry
#
# Exported functions:
#   run_adhoc_task  -- prompt for task, invoke AI, append to fix_plan.md
#
# IMPORTANT: All output uses echo/printf -- never log() -- because log() calls
# mkdir -p "$LOG_DIR" unconditionally, which would create .ralph/ in the wrong
# place when invoked from a parent directory during walk-up search.

# Colors (safe to re-declare; parent may not have exported them)
_ADHOC_RED='\033[0;31m'
_ADHOC_GREEN='\033[0;32m'
_ADHOC_YELLOW='\033[1;33m'
_ADHOC_BLUE='\033[0;34m'
_ADHOC_PURPLE='\033[0;35m'
_ADHOC_CYAN='\033[0;36m'
_ADHOC_NC='\033[0m'

# next_adhoc_id [fix_plan_path]
# Scans fix_plan.md for existing **AHxx** task IDs and returns the next
# sequential one.  First ad-hoc entry gets AH01.
# Outputs the new ID to stdout (e.g. "AH03").
next_adhoc_id() {
    local fix_plan="${1:-}"
    local max_num=0

    if [[ -n "$fix_plan" ]] && [[ -f "$fix_plan" ]]; then
        # Extract all AH<number> IDs from bold markdown **AHxx** patterns
        local nums
        nums=$(grep -oE '\*\*AH([0-9]+)\*\*' "$fix_plan" 2>/dev/null \
               | sed 's/\*\*AH//;s/\*\*//' \
               | sort -n | tail -1)
        if [[ -n "$nums" ]]; then
            # Strip leading zeros for arithmetic
            max_num=$((10#$nums))
        fi
    fi

    local next=$((max_num + 1))
    printf "AH%02d" "$next"
}

# find_fix_plan_for_adhoc
# Walks upward from CWD looking for .ralph/fix_plan.md.
# Prints the absolute path on success (exit 0).
# Returns 1 if not found (caller decides how to handle).
find_fix_plan_for_adhoc() {
    local dir
    dir="$(pwd)"
    while true; do
        if [[ -f "$dir/.ralph/fix_plan.md" ]]; then
            echo "$dir/.ralph/fix_plan.md"
            return 0
        fi
        local parent
        parent="$(dirname "$dir")"
        [[ "$parent" == "$dir" ]] && break   # filesystem root
        dir="$parent"
    done
    return 1
}

# prompt_task_description
# Interactively asks the user for a one-liner task description.
# Prints the description to stdout.
prompt_task_description() {
    echo "" >&2
    echo -e "${_ADHOC_PURPLE}=== Ralph Ad-hoc Task Mode ===${_ADHOC_NC}" >&2
    echo "" >&2
    echo -e "${_ADHOC_CYAN}Describe the bug or task in one line.${_ADHOC_NC}" >&2
    echo -e "${_ADHOC_CYAN}Examples:${_ADHOC_NC}" >&2
    echo -e "  ${_ADHOC_YELLOW}Login button unresponsive on mobile Safari${_ADHOC_NC}" >&2
    echo -e "  ${_ADHOC_YELLOW}API returns 500 when user profile has null email${_ADHOC_NC}" >&2
    echo -e "  ${_ADHOC_YELLOW}Dark mode toggle doesn't persist after page refresh${_ADHOC_NC}" >&2
    echo "" >&2
    echo -n -e "${_ADHOC_GREEN}Task> ${_ADHOC_NC}" >&2
    local description=""
    read -r description
    if [[ -z "$description" ]]; then
        echo "Error: No task description provided." >&2
        return 1
    fi
    echo "$description"
}

# run_adhoc_task <engine> <task_description> [yolo_mode] [superpowers] [superpowers_plugin_dir]
# Main entry point for adhoc task mode.
#   engine               - claude | codex | devin
#   task_description     - the one-liner from the user (can be empty; will prompt)
#   yolo_mode            - "true" to use --dangerously-skip-permissions (Claude only)
#   superpowers          - "true" to load superpowers plugin (Claude only)
#   superpowers_plugin_dir - path to superpowers plugin directory
run_adhoc_task() {
    local engine="${1:-claude}"
    local task_description="${2:-}"
    local yolo_mode="${3:-false}"
    local superpowers="${4:-false}"
    local superpowers_plugin_dir="${5:-${HOME}/.claude/plugins/repos/superpowers}"

    # 1. Validate engine
    local cli_cmd=""
    case "$engine" in
        claude) cli_cmd="claude" ;;
        codex)  cli_cmd="codex" ;;
        devin)  cli_cmd="devin" ;;
        *)
            echo "Error: Unknown engine: $engine (expected: claude, codex, devin)" >&2
            return 1
            ;;
    esac

    # 2. Verify engine CLI is installed
    if ! command -v "$cli_cmd" &>/dev/null; then
        echo "Error: $engine CLI ('$cli_cmd') not found. Install it first." >&2
        return 1
    fi

    # 3. Prompt for task description if not provided
    if [[ -z "$task_description" ]]; then
        task_description=$(prompt_task_description) || return 1
    fi

    # 4. Find existing fix_plan.md (optional -- we can create one if missing)
    local fix_plan_path=""
    local fix_plan_contents=""
    local ralph_dir=""

    if fix_plan_path=$(find_fix_plan_for_adhoc); then
        fix_plan_contents=$(cat "$fix_plan_path")
        ralph_dir="$(dirname "$fix_plan_path")"
    else
        # No fix_plan found -- check if .ralph/ exists in CWD
        if [[ -d ".ralph" ]]; then
            fix_plan_path=".ralph/fix_plan.md"
            ralph_dir=".ralph"
            fix_plan_contents=""
        else
            echo "" >&2
            echo -e "${_ADHOC_YELLOW}No .ralph/ directory found. Creating one...${_ADHOC_NC}" >&2
            mkdir -p ".ralph/logs"
            fix_plan_path=".ralph/fix_plan.md"
            ralph_dir=".ralph"
            fix_plan_contents=""
        fi
    fi

    # 5. Gather codebase context for smarter task breakdown
    local project_context=""
    project_context="Project Root: $(pwd)"

    # Detect project type from common config files
    if [[ -f "package.json" ]]; then
        project_context+="\nProject Type: Node.js/JavaScript"
        local pkg_name
        pkg_name=$(jq -r '.name // "unknown"' package.json 2>/dev/null || echo "unknown")
        project_context+="\nPackage Name: $pkg_name"
    elif [[ -f "Cargo.toml" ]]; then
        project_context+="\nProject Type: Rust"
    elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
        project_context+="\nProject Type: Python"
    elif [[ -f "go.mod" ]]; then
        project_context+="\nProject Type: Go"
    fi

    # Include AGENT.md if available (build/test instructions)
    local agent_file=""
    if [[ -f "$ralph_dir/AGENT.md" ]]; then
        agent_file=$(cat "$ralph_dir/AGENT.md")
    fi

    # 6. Find the PROMPT_ADHOC.md template
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local prompt_template=""

    if [[ -f "$ralph_dir/PROMPT_ADHOC.md" ]]; then
        prompt_template=$(cat "$ralph_dir/PROMPT_ADHOC.md")
    elif [[ -f "$ralph_home/templates/PROMPT_ADHOC.md" ]]; then
        prompt_template=$(cat "$ralph_home/templates/PROMPT_ADHOC.md")
    elif [[ -f "$script_dir/templates/PROMPT_ADHOC.md" ]]; then
        prompt_template=$(cat "$script_dir/templates/PROMPT_ADHOC.md")
    fi

    # 7. Generate a unique task ID for this entry
    local task_id=""
    task_id=$(next_adhoc_id "$fix_plan_path")

    # 8. Build the prompt
    local prompt=""
    if [[ -n "$prompt_template" ]]; then
        prompt="$prompt_template"
    else
        # Inline fallback if template not found
        prompt="You are Ralph in **Ad-hoc Task Mode**. The user has described a bug or task in a single line.
Your job is to analyze the codebase, understand the issue, and create a structured entry in .ralph/fix_plan.md."
    fi

    prompt+="

---

## Assigned Task ID: $task_id

**You MUST use \`**${task_id}**\` as a bold markdown prefix on the first subtask line of the entry you create.**
This is how the user will run this task later: \`ralph --task $task_id\`

## Ad-hoc Task Input

**User Description:** $task_description

## Project Context
$project_context"

    if [[ -n "$agent_file" ]]; then
        prompt+="

## Build & Test Instructions (from AGENT.md)
$agent_file"
    fi

    prompt+="

## Current Fix Plan
File: $fix_plan_path"

    if [[ -n "$fix_plan_contents" ]]; then
        prompt+="

\`\`\`markdown
$fix_plan_contents
\`\`\`"
    else
        prompt+="

(No existing fix plan -- you will create one from scratch)"
    fi

    prompt+="

## Your Task
1. Read the codebase to understand the project structure and the area related to the described issue
2. Analyze what the root cause might be and what changes are needed
3. Create a detailed, actionable task entry (or section) in \`$fix_plan_path\`
4. The entry should include subtasks that break down the fix into concrete steps
5. **Prefix the FIRST subtask line with \`**${task_id}**\`** (bold markdown)
6. Place it under an appropriate priority section (High Priority for bugs, or create a new ad-hoc section)
7. Preserve ALL existing content in fix_plan.md -- only append or insert your new entry"

    # 9. Invoke engine in interactive (TUI) mode
    echo "" >&2
    echo -e "${_ADHOC_BLUE}Engine: $engine | Task: $task_description | ID: $task_id${_ADHOC_NC}" >&2
    echo -e "${_ADHOC_BLUE}Launching $engine to analyze and create fix_plan entry...${_ADHOC_NC}" >&2
    echo "" >&2

    local cli_exit_code=0
    local prompt_file=""

    case "$engine" in
        claude)
            local -a claude_flags=()

            if [[ "$yolo_mode" == true ]]; then
                claude_flags+=("--dangerously-skip-permissions")
            else
                claude_flags+=("--permission-mode" "bypassPermissions")
                claude_flags+=("--allowedTools" "Read" "Write" "Glob" "Grep")
            fi

            if [[ "$superpowers" == true ]] && [[ -d "$superpowers_plugin_dir" ]]; then
                claude_flags+=("--plugin-dir" "$superpowers_plugin_dir")
            fi

            if "$cli_cmd" "${claude_flags[@]}" "$prompt"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        codex)
            if "$cli_cmd" --dangerously-bypass-approvals-and-sandbox -- "$prompt"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        devin)
            prompt_file=$(mktemp)
            echo "$prompt" > "$prompt_file"
            if "$cli_cmd" --permission-mode dangerous --prompt-file "$prompt_file"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
    esac

    # Cleanup temp file (only devin creates one)
    rm -f "$prompt_file"

    # Report result
    if [[ $cli_exit_code -eq 0 ]]; then
        # Verify the task ID landed in fix_plan.md
        local confirmed_id="$task_id"
        if [[ -f "$fix_plan_path" ]] && grep -qF "**${task_id}**" "$fix_plan_path" 2>/dev/null; then
            confirmed_id="$task_id"
        fi

        echo "" >&2
        echo -e "${_ADHOC_GREEN}Ad-hoc task entry created successfully!${_ADHOC_NC}" >&2
        echo -e "${_ADHOC_GREEN}Task ID: ${confirmed_id}${_ADHOC_NC}" >&2
        echo -e "${_ADHOC_GREEN}Review: $fix_plan_path${_ADHOC_NC}" >&2
        echo "" >&2
        echo "Next steps:" >&2
        echo "  1. Review the new entry in $fix_plan_path" >&2
        echo "  2. Run the task: ralph --task $confirmed_id" >&2
        echo "  3. Or start the full loop: ralph --monitor" >&2

        # Output task ID to stdout (machine-readable, pipe-friendly)
        echo "$confirmed_id"
    else
        echo "" >&2
        echo -e "${_ADHOC_RED}Ad-hoc task creation failed (exit code: $cli_exit_code).${_ADHOC_NC}" >&2
        echo -e "${_ADHOC_RED}Check $engine CLI output above.${_ADHOC_NC}" >&2
    fi

    return $cli_exit_code
}
