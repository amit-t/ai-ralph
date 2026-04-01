#!/bin/bash
# lib/fix_plan_status.sh — Fix plan walk-up search and AI status display
#
# Exported functions:
#   find_fix_plan            — walk up from CWD to find .ralph/fix_plan.md
#   show_fix_plan_status     — validate engine, find plan, invoke AI
#
# IMPORTANT: All output uses echo/printf — never log() — because log() calls
# mkdir -p "$LOG_DIR" unconditionally, which would create .ralph/ in the wrong
# place when invoked from a parent directory during walk-up search.

# find_fix_plan
# Walks upward from CWD checking for .ralph/fix_plan.md at each level.
# Prints the absolute path on success (exit 0).
# Prints an error and exits 1 if not found.
find_fix_plan() {
    local dir searched=()
    dir="$(pwd)"
    while true; do
        if [[ -f "$dir/.ralph/fix_plan.md" ]]; then
            echo "$dir/.ralph/fix_plan.md"
            return 0
        fi
        searched+=("$dir/.ralph/fix_plan.md")
        local parent
        parent="$(dirname "$dir")"
        [[ "$parent" == "$dir" ]] && break   # filesystem root
        dir="$parent"
    done

    echo "Error: .ralph/fix_plan.md not found. Searched:" >&2
    for p in "${searched[@]}"; do
        echo "  $p" >&2
    done
    echo "Run 'ralph-enable' to set up Ralph in this project." >&2
    return 1
}

# show_fix_plan_status <engine>
# Validates the engine, finds fix_plan.md, builds an analysis prompt,
# and invokes the AI engine in TUI/interactive mode.
show_fix_plan_status() {
    local engine="${1:-claude}"

    # 1. Validate engine
    case "$engine" in
        claude|codex|devin) ;;
        *)
            echo "Error: Unknown engine: $engine (expected: claude, codex, devin)" >&2
            return 1
            ;;
    esac

    # 2. Verify engine CLI is installed
    local cli_cmd
    case "$engine" in
        claude) cli_cmd="claude" ;;
        codex)  cli_cmd="codex" ;;
        devin)  cli_cmd="devin" ;;
    esac
    if ! command -v "$cli_cmd" &>/dev/null; then
        echo "Error: $engine CLI ('$cli_cmd') not found. Install it first." >&2
        return 1
    fi

    # 3. Find the fix plan
    local fix_plan_path
    fix_plan_path=$(find_fix_plan) || return 1

    # 4. Read plan contents
    local fix_plan_contents
    fix_plan_contents=$(cat "$fix_plan_path")

    # 5. Build prompt
    local prompt
    prompt="You are analyzing a Ralph fix plan for a software project.

Here is the fix plan (from $fix_plan_path):

$fix_plan_contents

Please provide:

1. **Task Summary**
   - Total tasks, completed ([x]), pending ([ ])
   - Overall completion percentage

2. **Section Breakdown**
   For each section in the plan:
   - Section name
   - Tasks: X done / Y total (Z%)

3. **Insights**
   - What's next (highest-priority pending tasks)
   - Any risks or blockers you notice
   - Patterns (e.g. a section that hasn't been started, or one that's nearly done)
   - Any observations about the shape or quality of the plan itself"

    # 6. Invoke engine (TUI/interactive mode, same as run_ai_planning in ralph_plan.sh)
    # Claude and codex receive the prompt as a string argument directly.
    # Devin requires a prompt file — create via mktemp (no .ralph/ dependency needed).
    local cli_exit_code=0
    local prompt_file=""
    case "$engine" in
        claude)
            if "$cli_cmd" --permission-mode bypassPermissions --allowedTools Read "$prompt"; then
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

    # 7. Unconditional temp file cleanup (only devin creates one)
    rm -f "$prompt_file"

    # 8. Return engine's exit code
    return $cli_exit_code
}
