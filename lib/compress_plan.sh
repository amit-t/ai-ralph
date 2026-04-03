#!/bin/bash
# lib/compress_plan.sh -- Compress fix_plan.md to reduce token consumption
#
# Exported functions:
#   run_compress_plan  -- archive current plan, invoke AI to compress, verify
#
# IMPORTANT: All output uses echo/printf -- never log() -- because log() calls
# mkdir -p "$LOG_DIR" unconditionally, which would create .ralph/ in the wrong
# place when invoked from a parent directory during walk-up search.

# Colors (safe to re-declare; parent may not have exported them)
_COMPRESS_RED='\033[0;31m'
_COMPRESS_GREEN='\033[0;32m'
_COMPRESS_YELLOW='\033[1;33m'
_COMPRESS_BLUE='\033[0;34m'
_COMPRESS_PURPLE='\033[0;35m'
_COMPRESS_CYAN='\033[0;36m'
_COMPRESS_NC='\033[0m'

# find_fix_plan_for_compress
# Walks upward from CWD looking for .ralph/fix_plan.md.
# Prints the absolute path on success (exit 0).
# Returns 1 if not found.
find_fix_plan_for_compress() {
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

# count_plan_items <fix_plan_path>
# Counts total, completed, in-progress, and pending items in fix_plan.md.
# Outputs: "total completed in_progress pending" (space-separated)
count_plan_items() {
    local fix_plan="${1:-}"
    local total=0 completed=0 in_progress=0 pending=0

    if [[ -n "$fix_plan" ]] && [[ -f "$fix_plan" ]]; then
        total=$(grep -cE '^\s*- \[([ x~])\]' "$fix_plan" 2>/dev/null) || total=0
        completed=$(grep -cE '^\s*- \[x\]' "$fix_plan" 2>/dev/null) || completed=0
        in_progress=$(grep -cE '^\s*- \[~\]' "$fix_plan" 2>/dev/null) || in_progress=0
        pending=$(grep -cE '^\s*- \[ \]' "$fix_plan" 2>/dev/null) || pending=0
    fi

    echo "$total $completed $in_progress $pending"
}

# archive_fix_plan <fix_plan_path>
# Creates a timestamped backup of fix_plan.md in .ralph/logs/
# Outputs the archive path on success.
archive_fix_plan() {
    local fix_plan="${1:-}"
    if [[ -z "$fix_plan" ]] || [[ ! -f "$fix_plan" ]]; then
        return 1
    fi

    local ralph_dir
    ralph_dir="$(dirname "$fix_plan")"
    local logs_dir="$ralph_dir/logs"
    mkdir -p "$logs_dir"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local archive_path="$logs_dir/fix_plan_pre_compress_${timestamp}.md"

    cp "$fix_plan" "$archive_path"
    echo "$archive_path"
}

# run_compress_plan <engine> [yolo_mode] [superpowers] [superpowers_plugin_dir]
# Main entry point for compress mode.
#   engine               - claude | codex | devin
#   yolo_mode            - "true" to use --dangerously-skip-permissions (Claude only)
#   superpowers          - "true" to load superpowers plugin (Claude only)
#   superpowers_plugin_dir - path to superpowers plugin directory
run_compress_plan() {
    local engine="${1:-claude}"
    local yolo_mode="${2:-false}"
    local superpowers="${3:-false}"
    local superpowers_plugin_dir="${4:-${HOME}/.claude/plugins/repos/superpowers}"

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

    # 3. Find fix_plan.md
    local fix_plan_path=""
    local fix_plan_contents=""
    local ralph_dir=""

    if fix_plan_path=$(find_fix_plan_for_compress); then
        fix_plan_contents=$(cat "$fix_plan_path")
        ralph_dir="$(dirname "$fix_plan_path")"
    else
        echo "Error: No .ralph/fix_plan.md found. Nothing to compress." >&2
        return 1
    fi

    # 4. Check if plan has content worth compressing
    if [[ -z "$fix_plan_contents" ]]; then
        echo "Error: fix_plan.md is empty. Nothing to compress." >&2
        return 1
    fi

    # 5. Count items before compression
    local counts
    counts=$(count_plan_items "$fix_plan_path")
    local total completed in_progress pending
    read -r total completed in_progress pending <<< "$counts"

    echo "" >&2
    echo -e "${_COMPRESS_PURPLE}=== Ralph Fix Plan Compression ===${_COMPRESS_NC}" >&2
    echo "" >&2
    echo -e "${_COMPRESS_CYAN}Current plan stats:${_COMPRESS_NC}" >&2
    echo -e "  Total items:       ${_COMPRESS_YELLOW}$total${_COMPRESS_NC}" >&2
    echo -e "  Completed:         ${_COMPRESS_GREEN}$completed${_COMPRESS_NC}" >&2
    echo -e "  In-progress:       ${_COMPRESS_BLUE}$in_progress${_COMPRESS_NC}" >&2
    echo -e "  Pending:           ${_COMPRESS_YELLOW}$pending${_COMPRESS_NC}" >&2
    echo -e "  File size:         ${_COMPRESS_YELLOW}$(wc -c < "$fix_plan_path" | tr -d ' ') bytes${_COMPRESS_NC}" >&2
    echo "" >&2

    # 6. Archive the current plan
    local archive_path
    archive_path=$(archive_fix_plan "$fix_plan_path")
    if [[ -n "$archive_path" ]]; then
        echo -e "${_COMPRESS_GREEN}Archived to: $archive_path${_COMPRESS_NC}" >&2
    fi

    # 7. Find the PROMPT_COMPRESS.md template
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local prompt_template=""

    if [[ -f "$ralph_dir/PROMPT_COMPRESS.md" ]]; then
        prompt_template=$(cat "$ralph_dir/PROMPT_COMPRESS.md")
    elif [[ -f "$ralph_home/templates/PROMPT_COMPRESS.md" ]]; then
        prompt_template=$(cat "$ralph_home/templates/PROMPT_COMPRESS.md")
    elif [[ -f "$script_dir/templates/PROMPT_COMPRESS.md" ]]; then
        prompt_template=$(cat "$script_dir/templates/PROMPT_COMPRESS.md")
    fi

    # 8. Build the prompt
    local prompt=""
    if [[ -n "$prompt_template" ]]; then
        prompt="$prompt_template"
    else
        # Inline fallback if template not found
        prompt="You are Ralph in **Compress Mode**. Your job is to compress .ralph/fix_plan.md to reduce token consumption.
Collapse completed items into summary lines. Shorten verbose descriptions. Preserve all task IDs and checkbox states.
Write the compressed plan back to .ralph/fix_plan.md."
    fi

    prompt+="

---

## Compression Context

**Project Root:** $(pwd)
**Fix Plan Path:** $fix_plan_path
**Pre-compression stats:** $total items ($completed completed, $in_progress in-progress, $pending pending)
**File size:** $(wc -c < "$fix_plan_path" | tr -d ' ') bytes

## Current Fix Plan Contents

\`\`\`markdown
$fix_plan_contents
\`\`\`

## Your Task
1. Read and analyze the fix plan above
2. Apply the compression rules from the instructions
3. Write the compressed version to \`$fix_plan_path\`
4. Ensure NO task IDs are lost, NO checkbox states are changed, and ALL pending/in-progress items remain actionable"

    # 9. Invoke engine in interactive (TUI) mode
    echo -e "${_COMPRESS_BLUE}Engine: $engine${_COMPRESS_NC}" >&2
    echo -e "${_COMPRESS_BLUE}Launching $engine to compress fix plan...${_COMPRESS_NC}" >&2
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
        # Show post-compression stats
        if [[ -f "$fix_plan_path" ]]; then
            local new_counts
            new_counts=$(count_plan_items "$fix_plan_path")
            local new_total new_completed new_in_progress new_pending
            read -r new_total new_completed new_in_progress new_pending <<< "$new_counts"
            local new_size
            new_size=$(wc -c < "$fix_plan_path" | tr -d ' ')
            local old_size
            old_size=$(wc -c < "$archive_path" | tr -d ' ')

            echo "" >&2
            echo -e "${_COMPRESS_GREEN}Fix plan compressed successfully!${_COMPRESS_NC}" >&2
            echo "" >&2
            echo -e "${_COMPRESS_CYAN}Post-compression stats:${_COMPRESS_NC}" >&2
            echo -e "  Items: ${_COMPRESS_YELLOW}$total -> $new_total${_COMPRESS_NC}" >&2
            echo -e "  Size:  ${_COMPRESS_YELLOW}$old_size -> $new_size bytes${_COMPRESS_NC}" >&2
            echo "" >&2
            echo -e "  Archive: $archive_path" >&2
            echo -e "  Plan:    $fix_plan_path" >&2
        fi
    else
        echo "" >&2
        echo -e "${_COMPRESS_RED}Fix plan compression failed (exit code: $cli_exit_code).${_COMPRESS_NC}" >&2
        echo -e "${_COMPRESS_RED}Check $engine CLI output above.${_COMPRESS_NC}" >&2
        if [[ -n "$archive_path" ]] && [[ -f "$archive_path" ]]; then
            echo -e "${_COMPRESS_YELLOW}Original plan preserved at: $archive_path${_COMPRESS_NC}" >&2
        fi
    fi

    return $cli_exit_code
}
