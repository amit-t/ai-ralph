#!/bin/bash
# lib/file_plan.sh -- File-based planning mode: pass a specific file to generate fix_plan
#
# Exported functions:
#   run_file_plan  -- read file, invoke AI, generate/update fix_plan.md
#
# Accepts MD, JSON, or plain text files. The AI reads the file content and
# the codebase context to produce a structured fix_plan.md.
#
# IMPORTANT: All output uses echo/printf -- never log() -- because log() calls
# mkdir -p "$LOG_DIR" unconditionally, which would create .ralph/ in the wrong
# place when invoked from a parent directory during walk-up search.

# Colors (safe to re-declare; parent may not have exported them)
_FPLAN_RED='\033[0;31m'
_FPLAN_GREEN='\033[0;32m'
_FPLAN_YELLOW='\033[1;33m'
_FPLAN_BLUE='\033[0;34m'
_FPLAN_PURPLE='\033[0;35m'
_FPLAN_CYAN='\033[0;36m'
_FPLAN_NC='\033[0m'

# detect_file_type <file_path>
# Determines the file type from extension. Returns: markdown, json, text
detect_file_type() {
    local file_path="${1:-}"
    local ext="${file_path##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        md|markdown)  echo "markdown" ;;
        json)         echo "json" ;;
        txt|text)     echo "text" ;;
        yaml|yml)     echo "yaml" ;;
        *)            echo "text" ;;
    esac
}

# find_fix_plan_for_file_plan
# Walks upward from CWD looking for .ralph/fix_plan.md.
# Prints the absolute path on success (exit 0).
# Returns 1 if not found (caller decides how to handle).
find_fix_plan_for_file_plan() {
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

# run_file_plan <engine> <file_path> [yolo_mode] [superpowers] [superpowers_plugin_dir]
# Main entry point for file-based planning mode.
#   engine                 - claude | codex | devin
#   file_path              - path to the input file (MD, JSON, or text)
#   yolo_mode              - "true" to use --dangerously-skip-permissions (Claude only)
#   superpowers            - "true" to load superpowers plugin (Claude only)
#   superpowers_plugin_dir - path to superpowers plugin directory
run_file_plan() {
    local engine="${1:-claude}"
    local file_path="${2:-}"
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

    # 3. Validate file path
    if [[ -z "$file_path" ]]; then
        echo "Error: No file path provided. Usage: ralph-plan --file <path>" >&2
        return 1
    fi

    if [[ ! -f "$file_path" ]]; then
        echo "Error: File not found: $file_path" >&2
        return 1
    fi

    if [[ ! -r "$file_path" ]]; then
        echo "Error: File not readable: $file_path" >&2
        return 1
    fi

    # 4. Read the input file
    local file_content=""
    file_content=$(cat "$file_path")
    if [[ -z "$file_content" ]]; then
        echo "Error: File is empty: $file_path" >&2
        return 1
    fi

    local file_type=""
    file_type=$(detect_file_type "$file_path")
    local file_size=""
    file_size=$(wc -c < "$file_path" | tr -d ' ')
    local file_basename=""
    file_basename=$(basename "$file_path")
    # Resolve to absolute path for display
    local file_abs=""
    file_abs=$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")

    # 5. Find existing fix_plan.md (optional -- we can create one if missing)
    local fix_plan_path=""
    local fix_plan_contents=""
    local ralph_dir=""

    if fix_plan_path=$(find_fix_plan_for_file_plan); then
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
            echo -e "${_FPLAN_YELLOW}No .ralph/ directory found. Creating one...${_FPLAN_NC}" >&2
            mkdir -p ".ralph/logs"
            fix_plan_path=".ralph/fix_plan.md"
            ralph_dir=".ralph"
            fix_plan_contents=""
        fi
    fi

    # 6. Gather codebase context
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

    # 7. Find the PROMPT_FILE_PLAN.md template
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local prompt_template=""

    if [[ -f "$ralph_dir/PROMPT_FILE_PLAN.md" ]]; then
        prompt_template=$(cat "$ralph_dir/PROMPT_FILE_PLAN.md")
    elif [[ -f "$ralph_home/templates/PROMPT_FILE_PLAN.md" ]]; then
        prompt_template=$(cat "$ralph_home/templates/PROMPT_FILE_PLAN.md")
    elif [[ -f "$script_dir/templates/PROMPT_FILE_PLAN.md" ]]; then
        prompt_template=$(cat "$script_dir/templates/PROMPT_FILE_PLAN.md")
    fi

    # 8. Build the prompt
    local prompt=""
    if [[ -n "$prompt_template" ]]; then
        prompt="$prompt_template"
    else
        # Inline fallback if template not found
        prompt="You are Ralph in **File-based Planning Mode**. The user has provided a specific document (specification, PRD, requirements, or task list).
Your job is to read the document, analyze the codebase, and create or update .ralph/fix_plan.md with actionable engineering tasks extracted from the document."
    fi

    prompt+="

---

## Input Document

**File**: $file_basename
**Path**: $file_abs
**Type**: $file_type
**Size**: $file_size bytes

### Document Content

\`\`\`${file_type}
${file_content}
\`\`\`

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
1. Read the input document above thoroughly
2. Read the codebase to understand the project structure and what already exists
3. Extract all requirements, tasks, features, bugs, or action items from the document
4. Create or update \`$fix_plan_path\` with a prioritized, actionable task list
5. Group tasks by priority (High, Medium, Low) based on the document's emphasis
6. Each task should be specific -- reference actual files, modules, or functions where possible
7. Preserve ALL existing content in fix_plan.md -- only append, insert, or reorganize
8. If the document contains acceptance criteria, include them as subtask checkboxes"

    # 9. Invoke engine in interactive (TUI) mode
    echo "" >&2
    echo -e "${_FPLAN_PURPLE}=== Ralph File-based Planning Mode ===${_FPLAN_NC}" >&2
    echo "" >&2
    echo -e "${_FPLAN_BLUE}Engine: $engine${_FPLAN_NC}" >&2
    echo -e "${_FPLAN_BLUE}Input:  $file_abs ($file_type, $file_size bytes)${_FPLAN_NC}" >&2
    echo -e "${_FPLAN_BLUE}Output: $fix_plan_path${_FPLAN_NC}" >&2
    echo "" >&2
    echo -e "${_FPLAN_BLUE}Launching $engine to analyze document and build fix_plan...${_FPLAN_NC}" >&2
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
        echo "" >&2
        echo -e "${_FPLAN_GREEN}File-based planning completed successfully!${_FPLAN_NC}" >&2
        echo -e "${_FPLAN_GREEN}Source:    $file_abs${_FPLAN_NC}" >&2
        echo -e "${_FPLAN_GREEN}Fix Plan:  $fix_plan_path${_FPLAN_NC}" >&2
        echo "" >&2
        echo "Next steps:" >&2
        echo "  1. Review the plan: $fix_plan_path" >&2
        echo "  2. Start execution: ralph --monitor" >&2
        echo "  3. Or run a specific task: ralph --task <ID>" >&2
    else
        echo "" >&2
        echo -e "${_FPLAN_RED}File-based planning failed (exit code: $cli_exit_code).${_FPLAN_NC}" >&2
        echo -e "${_FPLAN_RED}Check $engine CLI output above.${_FPLAN_NC}" >&2
    fi

    return $cli_exit_code
}
