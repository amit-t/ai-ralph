#!/bin/bash

# Ralph Loop for Devin CLI
# Autonomous AI development loop using the official Cognition Devin CLI.
# This is a parallel implementation to ralph_loop.sh (Claude Code) — no shared state.
#
# The official Devin CLI is a local agent (like Claude Code):
#   devin -p --prompt-file FILE     # Non-interactive execution
#   devin -r SESSION_ID             # Resume specific session
#   devin --model opus|sonnet       # Model selection
#   devin --permission-mode auto    # Permission control
#
# Config: Uses .ralphrc.devin (separate from Claude's .ralphrc)
#
# Version: 0.2.0

# Note: set -e intentionally NOT used — see Issue #208.
# set -e causes silent script death in pipelines, command substitutions,
# and piped subshells (e.g., cleanup prompt injection, quality gate checks).
# Errors are handled explicitly throughout the script.

# Source library components (shared with Claude version)
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$RALPH_ROOT/lib/date_utils.sh"
source "$RALPH_ROOT/lib/timeout_utils.sh"
source "$RALPH_ROOT/lib/response_analyzer.sh"
source "$RALPH_ROOT/lib/circuit_breaker.sh"
source "$RALPH_ROOT/lib/task_sources.sh"
source "$SCRIPT_DIR/lib/devin_adapter.sh"
source "$SCRIPT_DIR/lib/worktree_manager.sh"
source "$RALPH_ROOT/lib/parallel_spawn.sh"
source "$RALPH_ROOT/lib/pr_manager.sh"
source "$RALPH_ROOT/lib/workspace_manager.sh"

# Configuration
RALPH_DIR=".ralph"
RALPH_ENGINE="devin"           # identifier used by pr_manager.sh
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
LIVE_LOG_FILE="$RALPH_DIR/live.log"
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false
LIVE_OUTPUT=true
PARALLEL_COUNT=0
PARALLEL_BG=false
WORKSPACE_MODE=false
SLEEP_DURATION=3600
SPECIFIC_TASK_NUM=""

# Save environment variable state BEFORE setting defaults
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_DEVIN_TIMEOUT_MINUTES="${DEVIN_TIMEOUT_MINUTES:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_DEVIN_MODEL="${DEVIN_MODEL:-}"
_env_DEVIN_PERMISSION_MODE="${DEVIN_PERMISSION_MODE:-}"
_env_DEVIN_AUTO_EXIT="${DEVIN_AUTO_EXIT:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_WORKTREE_ENABLED="${WORKTREE_ENABLED:-}"
_env_WORKTREE_MERGE_STRATEGY="${WORKTREE_MERGE_STRATEGY:-}"
_env_WORKTREE_QUALITY_GATES="${WORKTREE_QUALITY_GATES:-}"

# Defaults
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
DEVIN_TIMEOUT_MINUTES="${DEVIN_TIMEOUT_MINUTES:-30}"
DEVIN_USE_CONTINUE="${DEVIN_USE_CONTINUE:-true}"
DEVIN_AUTO_EXIT="${DEVIN_AUTO_EXIT:-true}"  # true = use -p flag (auto-exit), false = interactive TUI

# Session management
DEVIN_SESSION_EXPIRY_HOURS="${DEVIN_SESSION_EXPIRY_HOURS:-24}"

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30

# Quality gate mode configuration (used with --qg flag)
MAX_QG_RETRIES="${MAX_QG_RETRIES:-3}"

# .ralphrc.devin configuration file (separate from Claude's .ralphrc)
RALPHRC_FILE=".ralphrc.devin"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${DEVIN_TIMEOUT:-}" ]]; then
        DEVIN_TIMEOUT_MINUTES="$DEVIN_TIMEOUT"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore explicitly set environment variables (CLI flags > env vars > .ralphrc.devin)
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_DEVIN_TIMEOUT_MINUTES" ]] && DEVIN_TIMEOUT_MINUTES="$_env_DEVIN_TIMEOUT_MINUTES"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_DEVIN_MODEL" ]] && DEVIN_MODEL="$_env_DEVIN_MODEL"
    [[ -n "$_env_DEVIN_PERMISSION_MODE" ]] && DEVIN_PERMISSION_MODE="$_env_DEVIN_PERMISSION_MODE"
    [[ -n "$_env_DEVIN_AUTO_EXIT" ]] && DEVIN_AUTO_EXIT="$_env_DEVIN_AUTO_EXIT"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_WORKTREE_ENABLED" ]] && WORKTREE_ENABLED="$_env_WORKTREE_ENABLED"
    [[ -n "$_env_WORKTREE_MERGE_STRATEGY" ]] && WORKTREE_MERGE_STRATEGY="$_env_WORKTREE_MERGE_STRATEGY"
    [[ -n "$_env_WORKTREE_QUALITY_GATES" ]] && WORKTREE_QUALITY_GATES="$_env_WORKTREE_QUALITY_GATES"

    RALPHRC_LOADED=true
    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# =============================================================================
# TMUX INTEGRATION
# =============================================================================

check_tmux_available() {
    if ! command -v tmux &>/dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        exit 1
    fi
}

get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    echo "${base_index:-0}"
}

setup_tmux_session() {
    local session_name="ralph-devin-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir
    project_dir=$(pwd)

    local base_win
    base_win=$(get_tmux_base_index)

    log_status "INFO" "Setting up tmux session: $session_name"

    echo "=== Ralph Devin Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    tmux new-session -d -s "$session_name" -c "$project_dir"
    tmux split-window -h -t "$session_name" -c "$project_dir"
    tmux split-window -v -t "$session_name:${base_win}.1" -c "$project_dir"

    # Right-top pane: Live Devin output
    tmux send-keys -t "$session_name:${base_win}.1" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane: Ralph status monitor
    if command -v ralph-devin-monitor &>/dev/null; then
        tmux send-keys -t "$session_name:${base_win}.2" "ralph-devin-monitor" Enter
    elif [[ -f "$ralph_home/devin/ralph_monitor_devin.sh" ]]; then
        tmux send-keys -t "$session_name:${base_win}.2" "'$ralph_home/devin/ralph_monitor_devin.sh'" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.2" "watch -n 5 cat '$project_dir/$STATUS_FILE'" Enter
    fi

    # Build ralph-devin command for left pane
    local ralph_cmd
    if command -v ralph-devin &>/dev/null; then
        ralph_cmd="ralph-devin"
    else
        ralph_cmd="'$ralph_home/devin/ralph_loop_devin.sh'"
    fi

    ralph_cmd="$ralph_cmd --live"

    [[ "$MAX_CALLS_PER_HOUR" != "100" ]] && ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]] && ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    [[ "$VERBOSE_PROGRESS" == "true" ]] && ralph_cmd="$ralph_cmd --verbose"
    [[ "$DEVIN_TIMEOUT_MINUTES" != "30" ]] && ralph_cmd="$ralph_cmd --timeout $DEVIN_TIMEOUT_MINUTES"
    [[ "$DEVIN_USE_CONTINUE" == "false" ]] && ralph_cmd="$ralph_cmd --no-continue"
    [[ "$CB_AUTO_RESET" == "true" ]] && ralph_cmd="$ralph_cmd --auto-reset-circuit"
    [[ "$WORKTREE_ENABLED" == "false" ]] && ralph_cmd="$ralph_cmd --no-worktree"
    [[ "$WORKTREE_MERGE_STRATEGY" != "squash" ]] && ralph_cmd="$ralph_cmd --merge-strategy $WORKTREE_MERGE_STRATEGY"

    # Forward workspace mode flag
    if [[ "$WORKSPACE_MODE" == "true" ]]; then
        ralph_cmd="$ralph_cmd --workspace"
    fi
    # Forward parallel count for workspace parallel mode
    if [[ "$PARALLEL_COUNT" -gt 0 ]]; then
        ralph_cmd="$ralph_cmd --parallel $PARALLEL_COUNT"
    fi

    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd" Enter
    tmux select-pane -t "$session_name:${base_win}.0"

    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Devin Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Devin Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    tmux rename-window -t "$session_name:${base_win}" "Ralph Devin: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph Devin loop"
    log_status "INFO" "  Right-top:    Devin live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    tmux attach-session -t "$session_name"
    exit 0
}

# =============================================================================
# CALL TRACKING & RATE LIMITING
# =============================================================================

init_call_tracking() {
    local current_hour
    current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    init_circuit_breaker
}

# =============================================================================
# LOGGING
# =============================================================================

log_status() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac

    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# =============================================================================
# STATUS TRACKING
# =============================================================================

update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}

    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "engine": "devin",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "devin_session_id": "${DEVIN_SESSION_ID:-}",
    "worktree_enabled": $([[ "$WORKTREE_ENABLED" == "true" ]] && echo "true" || echo "false"),
    "worktree_branch": "$(worktree_get_branch 2>/dev/null)",
    "worktree_path": "$(worktree_get_path 2>/dev/null)",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# =============================================================================
# RATE LIMITING
# =============================================================================

can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1
    else
        return 0
    fi
}

increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

wait_for_reset() {
    local calls_made
    calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."

    local current_minute
    current_minute=$(date +%M)
    local current_second
    current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))

    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."

    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))

        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"

    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# =============================================================================
# EXIT DETECTION
# =============================================================================

should_exit_gracefully() {
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1
    fi

    local signals
    signals=$(cat "$EXIT_SIGNALS_FILE")

    local recent_test_loops
    local recent_done_signals
    local recent_completion_indicators

    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi

    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi

    # 3. Safety circuit breaker
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators with EXIT_SIGNAL gate
    local devin_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        devin_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$devin_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi

    # 5. Check fix_plan.md for completion
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items
        uncompleted_items=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$uncompleted_items" ]] && uncompleted_items=0
        local completed_items
        completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$completed_items" ]] && completed_items=0
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""
}

# =============================================================================
# LOOP CONTEXT
# =============================================================================

build_loop_context() {
    local loop_count=$1
    local context=""

    context="Loop #${loop_count}. "

    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks
        incomplete_tasks=$(grep -cE "^[[:space:]]*- \[[ ~]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)
        [[ -z "$incomplete_tasks" ]] && incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state
        cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary
        prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary}"
        fi
    fi

    echo "${context:0:500}"
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

reset_session() {
    local reason=${1:-"manual_reset"}

    devin_clear_session
    devin_log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    # Clear exit signals
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    log_status "INFO" "Session reset: $reason"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

execute_devin_session() {
    local loop_count=$1
    local work_dir="${2:-$(pwd)}"
    local task_id="${3:-}"
    local task_line="${4:-}"
    local task_name="${5:-}"
    local main_dir
    main_dir="$(pwd)"
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="${main_dir}/${LOG_DIR}/devin_output_${timestamp}.log"
    local calls_made
    calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    calls_made=$((calls_made + 1))

    # Capture git HEAD SHA at loop start for progress detection
    local loop_start_sha=""
    if command -v git &>/dev/null; then
        if [[ "$work_dir" != "$main_dir" ]]; then
            loop_start_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        elif git rev-parse --git-dir &>/dev/null 2>&1; then
            loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Devin CLI (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((DEVIN_TIMEOUT_MINUTES * 60))
    log_status "INFO" "Starting Devin execution... (timeout: ${DEVIN_TIMEOUT_MINUTES}m)"

    # Build loop context for session continuity
    local loop_context=""
    if [[ "$DEVIN_USE_CONTINUE" == "true" ]]; then
        loop_context=$(build_loop_context "$loop_count")
        if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "INFO" "Loop context: $loop_context"
        fi
    fi

    # When in worktree mode, build a standalone directive that will be
    # prepended at the TOP of the prompt so the agent sees it first.
    local worktree_directive=""
    if [[ "$work_dir" != "$main_dir" ]]; then
        worktree_directive="# ⚠️  CRITICAL: WORKING DIRECTORY CONSTRAINT

You are operating inside an **isolated git worktree**.

- **Your working directory**: \`${work_dir}\`
- **DO NOT** navigate to, read from, or modify files in \`${main_dir}\` or any other directory.
- All file edits, git operations, and shell commands **MUST** stay within \`${work_dir}\`.
- Run \`pwd\` before any file operation to confirm you are in the correct directory.
- If a tool or command attempts to change to a different directory, refuse and stay in \`${work_dir}\`."
    fi

    # ── Non-interactive execution directive ─────────────────────────
    # When running with -p (auto-exit / non-interactive), inject a directive
    # telling the AI to always execute immediately and never ask for confirmation.
    # This prevents "Shall I proceed?" stalls in headless loop mode.
    if [[ "$DEVIN_AUTO_EXIT" != "false" ]]; then
        local non_interactive_directive="# ⚠️  NON-INTERACTIVE MODE — ALWAYS EXECUTE

You are running in **non-interactive, autonomous mode**. There is no human to respond.

- **DO NOT** ask for confirmation or approval. Proceed with implementation immediately.
- **DO NOT** output \"Shall I proceed?\", \"Should I continue?\", or any similar prompts.
- If there are multiple reasonable approaches, pick the best one and execute it.
- If you encounter an ambiguity, make a pragmatic decision and document it.
- Your only job is to **implement the task completely** and output a RALPH_STATUS block when done."

        if [[ -n "$worktree_directive" ]]; then
            worktree_directive="${worktree_directive}

${non_interactive_directive}"
        else
            worktree_directive="$non_interactive_directive"
        fi
    fi

    # ── Task assignment directive ────────────────────────────────
    # Inject the specific task that was picked by pick_next_task() so the AI
    # works on the correct task instead of choosing its own from fix_plan.md.
    # This is critical for parallel mode where multiple agents run simultaneously.
    if [[ -n "$task_id" && -n "$task_name" ]]; then
        local task_directive="# 🎯 ASSIGNED TASK — WORK ON THIS AND ONLY THIS

You have been assigned a **specific task** from fix_plan.md. Do NOT pick a different task.

- **Task ID**: \`${task_id}\`
- **Line in fix_plan.md**: ${task_line}
- **Description**: ${task_name}

Work **exclusively** on this task. Do not start, modify, or plan any other task from fix_plan.md.
This task has already been marked as in-progress (\`[~]\`) in fix_plan.md — do not change its checkbox state."

        if [[ -n "$worktree_directive" ]]; then
            worktree_directive="${worktree_directive}

${task_directive}"
        else
            worktree_directive="$task_directive"
        fi
    fi

    # Build the Devin CLI command
    # DEVIN_AUTO_EXIT controls -p flag: true = auto-exit, false = interactive TUI
    local session_id=""
    local print_mode="true"
    if [[ "$DEVIN_AUTO_EXIT" == "false" ]]; then
        print_mode="false"
    fi

    # Use worktree's prompt file (absolute path) when in worktree mode
    local effective_prompt="$PROMPT_FILE"
    if [[ "$work_dir" != "$main_dir" && -f "$work_dir/$PROMPT_FILE" ]]; then
        effective_prompt="$work_dir/$PROMPT_FILE"
    elif [[ "$work_dir" != "$main_dir" && -f "${main_dir}/$PROMPT_FILE" ]]; then
        effective_prompt="${main_dir}/$PROMPT_FILE"
    fi

    if ! build_devin_command "$effective_prompt" "$loop_context" "$session_id" "$print_mode" "$worktree_directive"; then
        log_status "ERROR" "Failed to build Devin command"
        return 1
    fi

    log_status "INFO" "Using Devin CLI (model: ${DEVIN_MODEL:-default}, permissions: ${DEVIN_PERMISSION_MODE:-auto})"
    log_status "INFO" "Command: ${DEVIN_CMD_ARGS[*]}"
    if [[ "$work_dir" != "$main_dir" ]]; then
        log_status "INFO" "Working directory: $work_dir"
    fi

    # Initialize live.log for this execution
    echo -e "\n\n=== Devin Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"
    echo "Command: ${DEVIN_CMD_ARGS[*]}" >> "$LIVE_LOG_FILE"

    # Execute Devin CLI
    local exit_code=0

    if [[ "$print_mode" == "false" ]]; then
        # Interactive mode: Devin runs in the terminal TUI (no -p flag)
        log_status "INFO" "Interactive mode - Devin running in TUI..."

        if [[ "$WORKTREE_ENABLED" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}  Ralph will auto-detect when Devin finishes (RALPH_STATUS)${NC}"
            echo -e "${BLUE}  and then auto-commit, push, and create a PR.${NC}"
            echo -e "${BLUE}  You can also press Ctrl+C to end the session manually.${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
        fi

        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Devin Session ━━━━━━━━━━━━━━━━${NC}"

        # Run Devin directly on the terminal (interactive TUI needs real TTY)
        # Use script to capture a copy of the output while keeping TTY intact
        # Note: portable_timeout is a bash function, not an executable.
        # script spawns a subprocess that can't see functions, so resolve to actual binary.
        local resolved_timeout_cmd
        resolved_timeout_cmd=$(detect_timeout_command 2>/dev/null)

        # ── SIGINT handling for interactive sessions ──────────────────────
        # Replace the global cleanup trap with a non-fatal handler so that
        # Ctrl+C terminates the Devin TUI but does NOT kill the Ralph loop.
        # After Devin exits (by any means: normal exit, Ctrl+C, timeout),
        # Ralph must continue to auto-commit → push → PR → worktree cleanup.
        local _devin_sigint_received="false"
        trap '_devin_sigint_received=true' SIGINT

        # ── Auto-exit detection ──────────────────────────────────────────
        # When running in worktree mode with `script`, start a background
        # monitor that polls the output file for END_RALPH_STATUS. When
        # detected, it kills the `script` process (which sends SIGHUP to
        # Devin), ending the session automatically. Ctrl+C remains as a
        # manual fallback.
        local _auto_exit_monitor_pid=""
        local _devin_pid_file="${RALPH_DIR}/.devin_session_pid"
        rm -f "$_devin_pid_file"

        if [[ "$WORKTREE_ENABLED" == "true" ]] && command -v script &>/dev/null; then
            # Background monitor: poll output file for END_RALPH_STATUS
            (
                # Wait for PID file (max 30s)
                local _wait=0
                while [[ ! -f "$_devin_pid_file" ]] && [[ $_wait -lt 60 ]]; do
                    sleep 0.5
                    ((_wait++))
                done
                local _target_pid
                _target_pid=$(cat "$_devin_pid_file" 2>/dev/null)
                [[ -z "$_target_pid" ]] && exit 0

                # Poll output file every 2s for the RALPH_STATUS end marker
                while kill -0 "$_target_pid" 2>/dev/null; do
                    if [[ -f "$output_file" ]] && grep -qa "END_RALPH_STATUS" "$output_file" 2>/dev/null; then
                        sleep 3  # Grace period for output flush
                        if kill -0 "$_target_pid" 2>/dev/null; then
                            kill -TERM "$_target_pid" 2>/dev/null || true
                        fi
                        break
                    fi
                    sleep 2
                done
            ) &
            _auto_exit_monitor_pid=$!

            # Run with exec so the subshell PID becomes the script PID
            # (monitor can then kill `script` directly)
            if [[ -n "$resolved_timeout_cmd" ]]; then
                (echo $BASHPID > "$_devin_pid_file"; cd "$work_dir" && exec script -q "$output_file" "$resolved_timeout_cmd" ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}")
            else
                (echo $BASHPID > "$_devin_pid_file"; cd "$work_dir" && exec script -q "$output_file" "${DEVIN_CMD_ARGS[@]}")
            fi
            exit_code=$?
        else
            # No auto-exit: run normally (user Ctrl+C's to end)
            if command -v script &>/dev/null && [[ -n "$resolved_timeout_cmd" ]]; then
                (cd "$work_dir" && script -q "$output_file" "$resolved_timeout_cmd" ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}")
                exit_code=$?
            elif [[ -n "$resolved_timeout_cmd" ]]; then
                (cd "$work_dir" && "$resolved_timeout_cmd" ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}")
                exit_code=$?
            else
                (cd "$work_dir" && "${DEVIN_CMD_ARGS[@]}")
                exit_code=$?
            fi
        fi

        # Cleanup auto-exit monitor
        if [[ -n "$_auto_exit_monitor_pid" ]]; then
            kill "$_auto_exit_monitor_pid" 2>/dev/null || true
            wait "$_auto_exit_monitor_pid" 2>/dev/null || true
        fi
        rm -f "$_devin_pid_file"

        # Restore the global cleanup trap
        trap cleanup SIGINT SIGTERM

        # In interactive mode, Ctrl+C or auto-exit termination (SIGTERM→143)
        # are both expected ways to end the session. Treat as normal exit.
        if [[ "$_devin_sigint_received" == "true" ]]; then
            log_status "INFO" "Devin session ended via Ctrl+C"
            exit_code=0
        elif [[ "$DEVIN_AUTO_EXIT" == "false" && $exit_code -ne 0 ]]; then
            log_status "INFO" "Interactive Devin session exited (code $exit_code) — treating as normal exit"
            exit_code=0
        fi

        cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Session ━━━━━━━━━━━━━━━━━━━${NC}"

        # Print post-session notice: Ralph handles PR/cleanup from here
        if [[ "$WORKTREE_ENABLED" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━ Post-Session ━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}Ralph will now auto-commit remaining changes,${NC}"
            echo -e "${BLUE}push the branch, and open a pull request.${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        fi
    else
        # Background mode: non-interactive (-p flag), output to file; LIVE_OUTPUT streams it.
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Devin Session (Live Output) ━━━━━━━━━━━━━━━━${NC}"
        (cd "$work_dir" && portable_timeout ${timeout_seconds}s "${DEVIN_CMD_ARGS[@]}") \
            < /dev/null > "$output_file" 2>&1 &
    fi

    if [[ "$print_mode" != "false" ]]; then
        local devin_pid=$!
        local progress_counter=0
        local last_displayed_line=0

        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            sleep 1  # Wait for output file to be created
        fi

        # Show progress while Devin is running
        while kill -0 $devin_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                if [[ "$LIVE_OUTPUT" == "true" ]]; then
                    local current_lines
                    current_lines=$(wc -l < "$output_file" 2>/dev/null || echo "0")
                    if [[ $current_lines -gt $last_displayed_line ]]; then
                        tail -n +$((last_displayed_line + 1)) "$output_file" 2>/dev/null
                        last_displayed_line=$current_lines
                    fi
                fi
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi

            if [[ "$LIVE_OUTPUT" != "true" ]]; then
                log_status "INFO" "$progress_indicator Devin working... (${progress_counter}x2s elapsed)"
            fi

            sleep 2
        done

        wait $devin_pid
        exit_code=$?

        # Flush any remaining output
        if [[ "$LIVE_OUTPUT" == "true" && -f "$output_file" ]]; then
            local final_lines
            final_lines=$(wc -l < "$output_file" 2>/dev/null || echo "0")
            if [[ $final_lines -gt $last_displayed_line ]]; then
                tail -n +$((last_displayed_line + 1)) "$output_file" 2>/dev/null
            fi
        fi
        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Session ━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    # Process results
    if [[ $exit_code -eq 0 ]]; then
        # Check for API errors hidden inside a successful exit code (e.g., rate limits)
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            local api_error=""
            api_error=$(jq -r 'select(.is_error == true) | .result // empty' "$output_file" 2>/dev/null | head -1)

            if [[ -n "$api_error" ]]; then
                log_status "ERROR" "API error: $api_error"
                echo -e "\n${RED}━━━ API Error ━━━${NC}"
                echo -e "${YELLOW}$api_error${NC}"
                echo -e "${RED}━━━━━━━━━━━━━━━━━${NC}\n"

                if echo "$api_error" | grep -qiE '(rate.limit|hit your limit|resets|quota|too many)'; then
                    return 2
                fi
                return 1
            fi
        fi

        echo "$calls_made" > "$CALL_COUNT_FILE"
        echo '{"status": "completed", "timestamp": "'"$(date '+%Y-%m-%d %H:%M:%S')"'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "Devin execution completed successfully"

        # Save session ID from output for future continuation
        devin_save_session "$output_file" 2>/dev/null || true

        # Analyze the response
        log_status "INFO" "Analyzing Devin response..."

        local devin_analysis
        devin_analysis=$(devin_parse_output "$output_file")

        local devin_exit_signal
        devin_exit_signal=$(echo "$devin_analysis" | jq -r '.exit_signal' 2>/dev/null || echo "false")
        local devin_summary
        devin_summary=$(echo "$devin_analysis" | jq -r '.work_summary' 2>/dev/null || echo "")

        jq -n \
            --arg exit_signal "$devin_exit_signal" \
            --arg work_summary "$devin_summary" \
            --argjson loop_count "$loop_count" \
            '{
                analysis: {
                    exit_signal: ($exit_signal == "true"),
                    work_summary: $work_summary,
                    has_permission_denials: false,
                    permission_denial_count: 0,
                    denied_commands: []
                },
                loop_count: $loop_count,
                engine: "devin"
            }' > "$RESPONSE_ANALYSIS_FILE"

        # Update exit signals
        update_exit_signals

        # Log analysis summary
        log_analysis_summary

        # Get file change count for circuit breaker
        local files_changed=0
        local current_sha=""
        local git_dir="$main_dir"
        [[ "$work_dir" != "$main_dir" ]] && git_dir="$work_dir"

        if command -v git &>/dev/null; then
            current_sha=$(cd "$git_dir" && git rev-parse HEAD 2>/dev/null || echo "")

            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                files_changed=$(
                    cd "$git_dir" && {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null
                        git diff --name-only --cached 2>/dev/null
                    } | sort -u | wc -l
                )
            else
                files_changed=$(
                    cd "$git_dir" && {
                        git diff --name-only 2>/dev/null
                        git diff --name-only --cached 2>/dev/null
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"
        if [[ -f "$output_file" ]]; then
            if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
               grep -qE '(^Error:|^ERROR:|^error:|\]: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
                has_errors="true"
                log_status "WARN" "Errors detected in output, check: $output_file"
            fi
        fi

        local output_length
        output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3
        fi

        return 0
    else
        echo '{"status": "failed", "timestamp": "'"$(date '+%Y-%m-%d %H:%M:%S')"'"}' > "$PROGRESS_FILE"
        log_status "ERROR" "Devin execution failed (exit code: $exit_code), check: $output_file"
        return 1
    fi
}

# =============================================================================
# CLEANUP & SIGNAL HANDLERS
# =============================================================================

cleanup() {
    log_status "INFO" "Ralph Devin loop interrupted. Cleaning up..."
    if worktree_is_active 2>/dev/null; then
        # Try to push and create PR before destroying the worktree
        if [[ "${PR_ENABLED:-true}" == "true" && "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
            log_status "INFO" "Attempting PR before cleanup..."
            worktree_commit_and_pr "" "" "true" "${loop_count:-0}" 2>/dev/null || true
            worktree_cleanup "false" 2>/dev/null || true   # preserve branch as PR head
        else
            log_status "INFO" "Cleaning up active worktree..."
            worktree_cleanup "true" 2>/dev/null || true
        fi
    fi
    reset_session "manual_interrupt"
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Global variable for loop count
loop_count=0

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc.devin"
        fi
    fi

    # Check Devin CLI availability
    if ! check_devin_cli; then
        exit 1
    fi

    log_status "SUCCESS" "Ralph loop starting with Devin CLI"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Timeout per session: ${DEVIN_TIMEOUT_MINUTES}m"
    log_status "INFO" "Logs: $LOG_DIR/ | Status: $STATUS_FILE"
    log_status "INFO" "Worktree: ${WORKTREE_ENABLED} | Merge: ${WORKTREE_MERGE_STRATEGY} | Gates: ${WORKTREE_QUALITY_GATES}"

    # Check if this is a Ralph project directory
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo "Run: ralph-migrate"
        exit 1
    fi

    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        echo "This directory is not a Ralph project."
        echo "To fix:"
        echo "  1. ralph-devin-enable   # Enable Ralph+Devin in existing project"
        echo "  2. ralph-devin-setup my-project  # Create new project"
        echo "  3. ralph-devin-import prd.md     # Import requirements"
        exit 1
    fi

    # Initialize worktree system
    if [[ "$WORKTREE_ENABLED" == "true" ]]; then
        if worktree_init; then
            log_status "SUCCESS" "Worktree mode enabled (base: $(worktree_get_base_dir))"
        else
            log_status "WARN" "Worktree init failed, using direct mode"
            WORKTREE_ENABLED="false"
        fi
    fi

    # Run PR preflight checks once before entering the loop
    pr_preflight_check

    log_status "INFO" "Starting task execution..."

    init_call_tracking

    # Beads pre-sync: pull new open beads into fix_plan.md
    if beads_sync_available; then
        log_status "INFO" "Syncing open beads into fix_plan.md..."
        beads_pre_sync "$RALPH_DIR/fix_plan.md" 2>&1 | while IFS= read -r sync_msg; do
            log_status "INFO" "$sync_msg"
        done
    fi

    # Pick one task (specific or next available)
    local picked_task_id="" picked_line_num="" picked_bead_id="" task_info="" picked_task_name=""
    if [[ -n "$SPECIFIC_TASK_NUM" ]]; then
        # Route: numeric → pick by ordinal, alphanumeric → pick by task ID (e.g. R05)
        local _pick_cmd="pick_task_by_number"
        [[ ! "$SPECIFIC_TASK_NUM" =~ ^[1-9][0-9]*$ ]] && _pick_cmd="pick_task_by_id"
        if task_info=$($_pick_cmd "$RALPH_DIR/fix_plan.md" "$SPECIFIC_TASK_NUM"); then
            picked_task_id=$(echo "$task_info" | cut -d'|' -f1)
            picked_line_num=$(echo "$task_info" | cut -d'|' -f2)
            picked_bead_id=$(echo "$task_info" | cut -d'|' -f3)
            picked_task_name=$(sed -n "${picked_line_num}p" "$RALPH_DIR/fix_plan.md" 2>/dev/null | sed 's/.*\[.\] //' | tr -d '\n' || echo "")
            log_status "SUCCESS" "Picked task $SPECIFIC_TASK_NUM: $picked_task_id (line $picked_line_num)"
        else
            log_status "ERROR" "Could not select task $SPECIFIC_TASK_NUM from fix_plan.md"
            exit 1
        fi
    elif task_info=$(pick_next_task "$RALPH_DIR/fix_plan.md"); then
        picked_task_id=$(echo "$task_info" | cut -d'|' -f1)
        picked_line_num=$(echo "$task_info" | cut -d'|' -f2)
        picked_bead_id=$(echo "$task_info" | cut -d'|' -f3)
        picked_task_name=$(sed -n "${picked_line_num}p" "$RALPH_DIR/fix_plan.md" 2>/dev/null | sed 's/.*\[.\] //' | tr -d '\n' || echo "")
        log_status "SUCCESS" "Picked task: $picked_task_id (line $picked_line_num)"
        if [[ -n "$picked_bead_id" ]] && beads_sync_available; then
            mark_single_bead_in_progress "$picked_bead_id" 2>&1 | while IFS= read -r m; do log_status "INFO" "$m"; done || true
        fi
    else
        log_status "INFO" "No unclaimed tasks in fix_plan.md — nothing to do."
        exit 0
    fi

    # Create worktree
    # NOTE: worktree_create must NOT be called inside $() — that runs a subshell
    # and the internal state variables (_WT_CURRENT_PATH, _WT_CURRENT_BRANCH)
    # would be lost. Instead, call directly and use accessors afterward.
    local work_dir
    work_dir="$(pwd)"
    if [[ "$WORKTREE_ENABLED" == "true" ]]; then
        local wt_task_id="${picked_task_id:-task-$(date +%s)}"
        if worktree_create 1 "$wt_task_id" > /dev/null; then
            work_dir="$(worktree_get_path)"
            log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
        else
            log_status "WARN" "Worktree creation failed, using main directory"
            WORKTREE_ENABLED="false"
        fi
    fi

    update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "executing" "running"

    # Capture HEAD SHA before execution for change detection
    local pre_exec_sha=""
    if command -v git &>/dev/null; then
        if [[ "$WORKTREE_ENABLED" == "true" && -n "$work_dir" && "$work_dir" != "$(pwd)" ]]; then
            pre_exec_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        else
            pre_exec_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi

    # Execute Devin session (pass picked task info so the AI works on the correct task)
    execute_devin_session 1 "$work_dir" "$picked_task_id" "$picked_line_num" "$picked_task_name"
    local exec_result=$?

    if [[ $exec_result -eq 0 ]]; then
        # ── Change detection ─────────────────────────────────────────────
        local git_dir="${work_dir}"
        [[ "$WORKTREE_ENABLED" != "true" ]] && git_dir="$(pwd)"
        local post_exec_sha=""
        local files_changed=0
        local lines_added=0
        local lines_removed=0
        local has_uncommitted=false

        if command -v git &>/dev/null; then
            post_exec_sha=$(cd "$git_dir" && git rev-parse HEAD 2>/dev/null || echo "")

            # Committed changes
            if [[ -n "$pre_exec_sha" && -n "$post_exec_sha" && "$pre_exec_sha" != "$post_exec_sha" ]]; then
                files_changed=$(cd "$git_dir" && git diff --name-only "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | wc -l | tr -d ' ')
                lines_added=$(cd "$git_dir" && git diff --stat "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
                lines_removed=$(cd "$git_dir" && git diff --stat "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
            fi

            # Uncommitted changes (staged + unstaged)
            local uncommitted_files=0
            uncommitted_files=$(cd "$git_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [[ $uncommitted_files -gt 0 ]]; then
                has_uncommitted=true
                files_changed=$((files_changed + uncommitted_files))
                local uc_added uc_removed
                uc_added=$(cd "$git_dir" && git diff HEAD --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
                uc_removed=$(cd "$git_dir" && git diff HEAD --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
                lines_added=$((lines_added + uc_added))
                lines_removed=$((lines_removed + uc_removed))
            fi
        fi

        [[ -z "$lines_added" ]] && lines_added=0
        [[ -z "$lines_removed" ]] && lines_removed=0

        # ── Feature 1: Early exit if no changes were made ────────────────
        if [[ $files_changed -eq 0 ]]; then
            log_status "WARN" "No changes were made during this execution."
            local _summary_session_id=""
            _summary_session_id=$(cat "$DEVIN_SESSION_FILE" 2>/dev/null || echo "")
            # Fallback: query Devin CLI for latest session if file is empty
            if [[ -z "$_summary_session_id" ]]; then
                _summary_session_id=$(devin_get_latest_session_id 2>/dev/null || echo "")
            fi
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║               Summary - No Changes Made                   ║${NC}"
            echo -e "${YELLOW}╠════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${YELLOW}║${NC}  Task:            ${picked_task_name:-$picked_task_id}"
            echo -e "${YELLOW}║${NC}  Files changed:   0"
            echo -e "${YELLOW}║${NC}  Lines added:     0"
            echo -e "${YELLOW}║${NC}  Lines removed:   0"
            echo -e "${YELLOW}║${NC}  Result:          No implementation changes detected"
            if [[ -n "$_summary_session_id" ]]; then
                echo -e "${YELLOW}║${NC}  Session ID:      ${_summary_session_id}"
                echo -e "${YELLOW}║${NC}  Resume with:     devin -r ${_summary_session_id}"
            fi
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            # Revert in-progress marker back to unclaimed so the task can be retried
            if [[ -n "$picked_line_num" ]]; then
                local tmp_file="${RALPH_DIR}/fix_plan.md.tmp.$$"
                awk -v ln="$picked_line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "$RALPH_DIR/fix_plan.md" > "$tmp_file" \
                    && mv "$tmp_file" "$RALPH_DIR/fix_plan.md"
            fi
            if worktree_is_active; then
                worktree_cleanup "true"
            fi
            update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "no_changes" "completed"
            log_status "SUCCESS" "Ralph Devin complete (no changes)."
            return 0
        fi

        # ── Worktree: quality gates + commit + push + PR + cleanup ───────
        if [[ "$WORKTREE_ENABLED" == "true" ]] && worktree_is_active; then
            log_status "INFO" "Running quality gates (install timeout ${WORKTREE_INSTALL_TIMEOUT}s, per-gate timeout ${WORKTREE_GATE_TIMEOUT}s)..."
            local gate_result
            worktree_run_quality_gates 2>&1 | while IFS= read -r line; do
                [[ -n "$line" ]] && log_status "INFO" "$line"
            done
            gate_result=${PIPESTATUS[0]}

            local wt_branch_for_log pr_result=0
            wt_branch_for_log="$(worktree_get_branch)"
            if [[ $gate_result -eq 0 ]]; then
                log_status "SUCCESS" "Quality gates passed."
                worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "true" "1" || pr_result=$?
            else
                log_status "WARN" "Quality gates failed — creating PR with failure details."
                worktree_commit_and_pr "$picked_task_id" "$picked_task_name" "false" "1" || pr_result=$?
            fi
            worktree_cleanup "false"
            if [[ $pr_result -ne 0 ]]; then
                log_status "ERROR" "PR workflow failed. Branch preserved: $wt_branch_for_log"
            elif [[ $gate_result -ne 0 ]]; then
                log_status "WARN" "Quality gates failed but PR created with failure details. Branch: $wt_branch_for_log"
            else
                [[ -n "$picked_line_num" ]] && mark_fix_plan_complete "$RALPH_DIR/fix_plan.md" "$picked_line_num"
            fi
        fi

        # Non-worktree PR
        if [[ "$WORKTREE_ENABLED" != "true" ]]; then
            worktree_fallback_branch_pr "$picked_task_id" "$picked_task_name" "1" "true" || true
        fi

        # Beads post-sync: close completed beads
        if beads_sync_available; then
            beads_post_sync "$RALPH_DIR/fix_plan.md" 1 2>&1 | while IFS= read -r m; do log_status "INFO" "$m"; done
        fi

        # Commit .ralph/ state files
        if git rev-parse --git-dir &>/dev/null 2>&1; then
            git add "$RALPH_DIR/fix_plan.md" "$RALPH_DIR/AGENT.md" 2>/dev/null || true
            if ! git diff --cached --quiet 2>/dev/null; then
                git commit -m "ralph-devin: update .ralph state" 2>/dev/null || true
            fi
        fi

        # ── Feature 2: End summary with files changed + lines committed ──
        local _summary_session_id=""
        _summary_session_id=$(cat "$DEVIN_SESSION_FILE" 2>/dev/null || echo "")
        # Fallback: query Devin CLI for latest session if file is empty
        if [[ -z "$_summary_session_id" ]]; then
            _summary_session_id=$(devin_get_latest_session_id 2>/dev/null || echo "")
        fi
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                  Execution Summary                        ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Task:            ${picked_task_name:-$picked_task_id}"
        echo -e "${GREEN}║${NC}  Files changed:   ${files_changed}"
        echo -e "${GREEN}║${NC}  Lines added:     +${lines_added}"
        echo -e "${GREEN}║${NC}  Lines removed:   -${lines_removed}"
        echo -e "${GREEN}║${NC}  Net change:      $((lines_added - lines_removed)) lines"
        if [[ -n "$_summary_session_id" ]]; then
            echo -e "${GREEN}║${NC}  Session ID:      ${_summary_session_id}"
            echo -e "${GREEN}║${NC}  Resume with:     devin -r ${_summary_session_id}"
        fi
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        update_status 1 "$(cat "$CALL_COUNT_FILE")" "completed" "success"
        log_status "SUCCESS" "Ralph Devin complete."
    else
        local _fail_branch=""
        local _fail_session_id=""
        _fail_session_id=$(cat "$DEVIN_SESSION_FILE" 2>/dev/null || echo "")
        if [[ -z "$_fail_session_id" ]]; then
            _fail_session_id=$(devin_get_latest_session_id 2>/dev/null || echo "")
        fi
        if worktree_is_active; then
            _fail_branch=$(worktree_get_branch)
        fi
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                  Execution Failed                         ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║${NC}  Task:            ${picked_task_name:-$picked_task_id}"
        echo -e "${RED}║${NC}  Exit code:       ${exec_result}"
        if [[ -n "$_fail_branch" ]]; then
            echo -e "${RED}║${NC}  Branch:          ${_fail_branch} (preserved for inspection)"
        fi
        if [[ -n "$_fail_session_id" ]]; then
            echo -e "${RED}║${NC}  Session ID:      ${_fail_session_id}"
            echo -e "${RED}║${NC}  Resume with:     devin -r ${_fail_session_id}"
        fi
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        if [[ -n "$picked_line_num" ]]; then
            local tmp_file="${RALPH_DIR}/fix_plan.md.tmp.$$"
            awk -v ln="$picked_line_num" 'NR==ln { sub(/- \[~\]/, "- [ ]") } 1' "$RALPH_DIR/fix_plan.md" > "$tmp_file" \
                && mv "$tmp_file" "$RALPH_DIR/fix_plan.md"
        fi

        if worktree_is_active; then
            log_status "WARN" "Removing worktree (branch preserved: ${_fail_branch})..."
            worktree_cleanup "false"
        fi
        update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "failed" "error"
        log_status "ERROR" "Devin execution failed (exit $exec_result)"
        exit 1
    fi
}

# =============================================================================
# WORKSPACE MODE — multi-repo orchestration
# =============================================================================
# Multi-repo workspace orchestration. Picks tasks from workspace fix_plan.md
# (which has ## repo-name sections) and executes them in the corresponding
# repository directories.
# Usage: ralph-devin --workspace [--parallel N]
#
run_workspace_mode() {
    # Load project-specific configuration from .ralphrc.devin
    if load_ralphrc; then
        [[ "$RALPHRC_LOADED" == "true" ]] && log_status "INFO" "Loaded configuration from .ralphrc.devin"
    fi

    # Validate Devin CLI is available
    if ! check_devin_cli; then
        exit 1
    fi

    log_status "SUCCESS" "Ralph Devin workspace mode starting"

    # Validate workspace structure (replaces normal PROMPT.md / integrity checks)
    local ws_validation
    ws_validation=$(validate_workspace "." 2>&1)
    if [[ $? -ne 0 ]]; then
        log_status "ERROR" "Invalid workspace structure"
        echo "$ws_validation" >&2
        echo ""
        echo "To set up a workspace, run:  ralph-enable --workspace"
        exit 1
    fi
    log_status "INFO" "$ws_validation"

    # List discovered repos
    local repos
    repos=$(discover_workspace_repos ".")
    log_status "INFO" "Repos: $(echo "$repos" | tr '\n' ' ')"

    # Initialize directories and tracking
    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    init_session_tracking
    update_session_last_used
    init_call_tracking

    # Reset exit signals for fresh start (Issue #194)
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null
    log_status "INFO" "Reset exit signals for fresh start"

    local fix_plan="$RALPH_DIR/fix_plan.md"

    # ── Parallel workspace mode ──────────────────────────────────────
    if [[ "$PARALLEL_COUNT" -gt 0 ]]; then
        _run_workspace_parallel "$fix_plan" "." "$PARALLEL_COUNT"
        return $?
    fi

    # ── Sequential workspace mode: pick one task ─────────────────────
    local task_info
    task_info=$(pick_workspace_task "$fix_plan")
    if [[ $? -ne 0 || -z "$task_info" ]]; then
        log_status "INFO" "No unclaimed workspace tasks — nothing to do."
        exit 0
    fi

    local repo_name task_id line_num task_desc
    repo_name=$(echo "$task_info" | cut -d'|' -f1)
    task_id=$(echo "$task_info" | cut -d'|' -f2)
    line_num=$(echo "$task_info" | cut -d'|' -f3)
    task_desc=$(echo "$task_info" | cut -d'|' -f4)

    log_status "SUCCESS" "Picked task: [$repo_name] $task_desc (line $line_num)"

    # Validate repo directory exists on disk
    local work_dir
    work_dir="$(pwd)/${repo_name}"
    if [[ ! -d "$work_dir" ]]; then
        log_status "ERROR" "Repository directory not found: $work_dir"
        revert_workspace_task "$fix_plan" "$line_num"
        exit 1
    fi

    # ── Worktree isolation (per-repo) ────────────────────────────────
    local ws_worktree_active=false
    if [[ "$WORKTREE_ENABLED" == "true" ]]; then
        local wt_task_id="${task_id:-task-$(date +%s)}"
        if workspace_repo_worktree_create "$work_dir" "$wt_task_id"; then
            work_dir="$(worktree_get_path)"
            ws_worktree_active=true
            log_status "SUCCESS" "Worktree: $work_dir (branch: $(worktree_get_branch))"
        else
            log_status "WARN" "Worktree creation failed for [$repo_name], using repo directory"
        fi
    fi

    local calls_made
    calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    update_status 1 "$calls_made" "workspace:${repo_name}" "running"

    # Capture pre-execution SHA for change detection
    local pre_exec_sha=""
    if command -v git &>/dev/null; then
        pre_exec_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
    fi

    # Execute Devin session with repo directory as work_dir.
    set +e
    execute_devin_session 1 "$work_dir" "$task_id" "$line_num" "$task_desc"
    local exec_result=$?
    set -e

    if [[ $exec_result -eq 0 ]]; then
        # ── Change detection in the repo directory ────────────────────
        local files_changed=0 lines_added=0 lines_removed=0

        if command -v git &>/dev/null; then
            local post_exec_sha=""
            post_exec_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")

            # Committed changes
            if [[ -n "$pre_exec_sha" && -n "$post_exec_sha" && "$pre_exec_sha" != "$post_exec_sha" ]]; then
                files_changed=$(cd "$work_dir" && git diff --name-only "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | wc -l | tr -d ' ')
                lines_added=$(cd "$work_dir" && git diff --stat "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
                lines_removed=$(cd "$work_dir" && git diff --stat "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
            fi

            # Uncommitted changes (staged + unstaged)
            local uncommitted_files=0
            uncommitted_files=$(cd "$work_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [[ $uncommitted_files -gt 0 ]]; then
                files_changed=$((files_changed + uncommitted_files))
                local uc_added uc_removed
                uc_added=$(cd "$work_dir" && git diff HEAD --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
                uc_removed=$(cd "$work_dir" && git diff HEAD --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
                lines_added=$((lines_added + uc_added))
                lines_removed=$((lines_removed + uc_removed))
            fi
        fi

        [[ -z "$lines_added" ]] && lines_added=0
        [[ -z "$lines_removed" ]] && lines_removed=0

        if [[ $files_changed -eq 0 ]]; then
            # No changes — revert task back to unclaimed
            log_status "WARN" "No changes made in [$repo_name] — reverting task"
            revert_workspace_task "$fix_plan" "$line_num"
            # Clean up worktree if active (delete branch — nothing to preserve)
            if [[ "$ws_worktree_active" == "true" ]]; then
                local _orig_repo_dir
                _orig_repo_dir="$(pwd)/${repo_name}"
                workspace_repo_cleanup "$_orig_repo_dir"
            fi
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║          Workspace Summary — No Changes Made              ║${NC}"
            echo -e "${YELLOW}╠════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${YELLOW}║${NC}  Repo:            ${repo_name}"
            echo -e "${YELLOW}║${NC}  Task:            ${task_desc}"
            echo -e "${YELLOW}║${NC}  Result:          No implementation changes detected"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "workspace:${repo_name}:no_changes" "completed"
            log_status "SUCCESS" "Ralph Devin workspace complete (no changes)."
            return 0
        fi

        # ── Changes detected: quality gates + PR + cleanup ────────────
        local repo_dir_abs
        repo_dir_abs="$(pwd)/${repo_name}"

        # Quality gates (run in worktree if active, else in repo dir)
        local gate_result=0
        if [[ "$WORKTREE_QUALITY_GATES" != "none" ]]; then
            log_status "INFO" "Running quality gates for [$repo_name]..."
            local gate_output
            gate_output=$(workspace_repo_run_quality_gates "$repo_dir_abs" 2>&1)
            gate_result=$?
            while IFS= read -r line; do [[ -n "$line" ]] && log_status "INFO" "$line"; done <<< "$gate_output"
            if [[ $gate_result -eq 0 ]]; then
                log_status "SUCCESS" "Quality gates passed for [$repo_name]."
            else
                log_status "WARN" "Quality gates failed for [$repo_name] — creating PR with failure details."
            fi
        fi

        # PR creation (commit, push, open PR)
        local pr_result=0
        local wt_branch_for_log=""
        if worktree_is_active; then
            wt_branch_for_log="$(worktree_get_branch)"
        fi

        if [[ "${PR_ENABLED:-true}" != "false" ]]; then
            local gate_flag="true"
            [[ $gate_result -ne 0 ]] && gate_flag="false"
            workspace_repo_commit_and_pr "$repo_dir_abs" "$task_id" "$task_desc" "$gate_flag" || pr_result=$?
        fi

        # Cleanup worktree
        if [[ "$ws_worktree_active" == "true" ]]; then
            workspace_repo_cleanup "$repo_dir_abs"
        fi

        # Determine task completion
        if [[ $pr_result -ne 0 ]]; then
            log_status "ERROR" "PR workflow failed for [$repo_name]. Branch preserved: $wt_branch_for_log"
        elif [[ $gate_result -ne 0 ]]; then
            log_status "WARN" "Quality gates failed for [$repo_name] but PR created. Branch: $wt_branch_for_log"
            # Mark task complete even if gates fail — PR is created for review
            mark_workspace_task_complete "$fix_plan" "$line_num"
        else
            mark_workspace_task_complete "$fix_plan" "$line_num"
        fi

        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║               Workspace Execution Summary                 ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Repo:            ${repo_name}"
        echo -e "${GREEN}║${NC}  Task:            ${task_desc}"
        echo -e "${GREEN}║${NC}  Files changed:   ${files_changed}"
        echo -e "${GREEN}║${NC}  Lines added:     +${lines_added}"
        echo -e "${GREEN}║${NC}  Lines removed:   -${lines_removed}"
        echo -e "${GREEN}║${NC}  Net change:      $((lines_added - lines_removed)) lines"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "workspace:${repo_name}:completed" "success"
        log_status "SUCCESS" "Ralph Devin workspace task complete: [$repo_name] $task_desc"
    else
        # Execution failed — revert task back to unclaimed
        revert_workspace_task "$fix_plan" "$line_num"
        # Clean up worktree if active
        if [[ "$ws_worktree_active" == "true" ]]; then
            local _orig_repo_dir
            _orig_repo_dir="$(pwd)/${repo_name}"
            workspace_repo_cleanup "$_orig_repo_dir"
        fi
        update_status 1 "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "workspace:${repo_name}:failed" "error"
        log_status "ERROR" "Workspace task failed for [$repo_name] (exit $exec_result)"
        exit 1
    fi
}

# _run_workspace_parallel — Execute multiple workspace tasks in parallel
# Uses run_workspace_tasks_parallel() from workspace_manager.sh with
# _workspace_execute_task as the per-repo executor.
#
# Args:
#   $1 - fix_plan: Path to workspace fix_plan.md
#   $2 - workspace_dir: Workspace root directory
#   $3 - requested_count: Requested number of parallel workers
_run_workspace_parallel() {
    local fix_plan="$1"
    local workspace_dir="$2"
    local requested_count="$3"

    local actual_count
    actual_count=$(get_workspace_parallel_limit "$fix_plan" "$workspace_dir" "$requested_count")

    if [[ "$actual_count" -eq 0 ]]; then
        log_status "INFO" "No repos with pending tasks for parallel execution — nothing to do."
        return 0
    fi

    log_status "INFO" "Parallel workspace: spawning $actual_count worker(s) (requested: $requested_count)..."

    run_workspace_tasks_parallel "$fix_plan" "$workspace_dir" "$actual_count" "_workspace_execute_task"
    local result=$?

    if [[ $result -eq 0 ]]; then
        log_status "SUCCESS" "All parallel workspace tasks completed successfully"
    else
        log_status "WARN" "Some parallel workspace tasks failed (see logs in .ralph/logs/parallel/)"
    fi

    return $result
}

# _workspace_execute_task — Execute a single workspace task in a repo directory
# This is the executor function passed to run_workspace_tasks_parallel().
# It runs in a forked subshell for each parallel task, inheriting all functions.
#
# Each task gets: worktree isolation → Devin execution → quality gates → PR → cleanup
#
# Args:
#   $1 - repo_name: Name of the repository
#   $2 - task_desc: Task description
#   $3 - workspace_dir: Workspace root directory
# Returns:
#   0 on success, 1 on failure
_workspace_execute_task() {
    local repo_name="$1"
    local task_desc="$2"
    local workspace_dir="$3"

    local repo_path
    if [[ "$workspace_dir" == "." ]]; then
        repo_path="$(pwd)/${repo_name}"
    else
        repo_path="${workspace_dir}/${repo_name}"
    fi

    if [[ ! -d "$repo_path" ]]; then
        echo "ERROR: Repository not found: $repo_path" >&2
        return 1
    fi

    # Build task_id from description (for logging and branch naming)
    local task_id
    task_id=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | head -c 50)

    # ── Worktree isolation ────────────────────────────────────────
    local work_dir="$repo_path"
    local ws_worktree_active=false
    if [[ "$WORKTREE_ENABLED" == "true" ]]; then
        if workspace_repo_worktree_create "$repo_path" "$task_id"; then
            work_dir="$(worktree_get_path)"
            ws_worktree_active=true
            echo "Worktree created: $work_dir (branch: $(worktree_get_branch))"
        else
            echo "WARN: Worktree creation failed for [$repo_name], using repo directory" >&2
        fi
    fi

    # Capture pre-execution SHA for change detection
    local pre_exec_sha=""
    pre_exec_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")

    echo "Executing task in [$repo_name]: $task_desc"

    # Execute Devin session with the repo as work directory.
    execute_devin_session 1 "$work_dir" "$task_id" "" "$task_desc"
    local result=$?

    if [[ $result -ne 0 ]]; then
        echo "Task failed in [$repo_name] (exit $result)" >&2
        if [[ "$ws_worktree_active" == "true" ]]; then
            workspace_repo_cleanup "$repo_path"
        fi
        return $result
    fi

    # ── Change detection ──────────────────────────────────────────
    local files_changed=0
    if command -v git &>/dev/null; then
        local post_exec_sha=""
        post_exec_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$pre_exec_sha" && -n "$post_exec_sha" && "$pre_exec_sha" != "$post_exec_sha" ]]; then
            files_changed=$(cd "$work_dir" && git diff --name-only "$pre_exec_sha" "$post_exec_sha" 2>/dev/null | wc -l | tr -d ' ')
        fi
        local uncommitted_files=0
        uncommitted_files=$(cd "$work_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        files_changed=$((files_changed + uncommitted_files))
    fi

    if [[ $files_changed -eq 0 ]]; then
        echo "No changes made in [$repo_name] — reverting task"
        if [[ "$ws_worktree_active" == "true" ]]; then
            workspace_repo_cleanup "$repo_path"
        fi
        return 1
    fi

    # ── Quality gates ─────────────────────────────────────────────
    local gate_result=0
    if [[ "$WORKTREE_QUALITY_GATES" != "none" ]]; then
        echo "Running quality gates for [$repo_name]..."
        workspace_repo_run_quality_gates "$repo_path" 2>&1
        gate_result=$?
        if [[ $gate_result -eq 0 ]]; then
            echo "Quality gates passed for [$repo_name]."
        else
            echo "Quality gates failed for [$repo_name] — creating PR with failure details." >&2
        fi
    fi

    # ── PR creation ───────────────────────────────────────────────
    if [[ "${PR_ENABLED:-true}" != "false" ]]; then
        local gate_flag="true"
        [[ $gate_result -ne 0 ]] && gate_flag="false"
        workspace_repo_commit_and_pr "$repo_path" "$task_id" "$task_desc" "$gate_flag" || true
    fi

    # ── Cleanup ───────────────────────────────────────────────────
    if [[ "$ws_worktree_active" == "true" ]]; then
        workspace_repo_cleanup "$repo_path"
    fi

    echo "Task completed in [$repo_name]"
    return 0
}
export -f _workspace_execute_task

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << HELPEOF
Ralph Loop for Devin CLI

Usage: ralph-devin [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Show Devin output in real-time
    -t, --timeout MIN       Set Devin session timeout in minutes (default: $DEVIN_TIMEOUT_MINUTES)
    --model MODEL           Set Devin model: opus, sonnet, swe, gpt
    --permission-mode MODE  Set permission mode: auto or dangerous (default: auto)
    --no-continue           Disable session continuity across loops
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup
    --reset-session         Reset session state and exit
    --devin-auto-exit       Force Devin to auto-exit with -p flag (default: true)
    --no-devin-auto-exit    Run Devin interactively (no -p flag, shows TUI)
    --no-worktree           Disable git worktree isolation
    --merge-strategy STR    Merge strategy: squash, merge, rebase (default: squash)
    --quality-gates GATES   Quality gates: auto, none, or "cmd1;cmd2" (default: auto)
    --task NUM|ID           Execute a specific task by number (1-based) or bold ID (e.g. R05)
    --workspace             Run in workspace mode (multi-repo orchestration)
    --parallel N            Run N tasks in parallel (workspace: N repos simultaneously)

Examples:
    ralph-devin --calls 50 --timeout 30
    ralph-devin --monitor
    ralph-devin --live --verbose
    ralph-devin --model opus
    ralph-devin --permission-mode dangerous
    ralph-devin --no-worktree
    ralph-devin --merge-strategy merge --quality-gates "npm test;npm run lint"
    ralph-devin --task 3               # Execute the 3rd task in fix_plan.md
    ralph-devin --task R05             # Execute task **R05** by its ID
    ralph-devin --task 5 --no-devin-auto-exit  # Interactively work on task 5
    ralph-devin --workspace               # Run workspace mode (multi-repo)
    ralph-devin --workspace --parallel 3  # Parallel workspace (3 repos simultaneously)

Bash Aliases (rpd):
    Add to ~/.bashrc or ~/.zshrc: source ~/.ralph/devin/ALIASES.sh

    rpd              # Run one task (non-interactive, live output)
    rpd.hitl         # Live + monitor
    rpd.opus         # Use Opus model
    rpd.wt.full      # Full worktree mode
    rpd.task 3       # Execute specific task #3 from fix_plan.md
    rpd.task.int 3   # Interactive mode for task #3
    rpd.ws           # Workspace mode (multi-repo)
    rpd.ws.p 3       # Parallel workspace (3 repos)
    rpd.install      # Install Ralph for Devin
    
    See devin/ALIASES.sh for complete list of 60+ aliases

HELPEOF
}

# =============================================================================
# CLI ARGUMENT PARSING
# =============================================================================

_RALPH_ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status (Devin):"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph Devin may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -l|--live)
            LIVE_OUTPUT=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                DEVIN_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --model)
            DEVIN_MODEL="$2"
            shift 2
            ;;
        --permission-mode)
            if [[ "$2" == "auto" || "$2" == "dangerous" ]]; then
                DEVIN_PERMISSION_MODE="$2"
            else
                echo "Error: --permission-mode must be 'auto' or 'dangerous'"
                exit 1
            fi
            shift 2
            ;;
        --no-continue)
            DEVIN_USE_CONTINUE=false
            shift
            ;;
        --reset-circuit)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/circuit_breaker.sh"
            source "$RALPH_ROOT/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32mSession state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$RALPH_ROOT/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
            ;;
        --no-worktree)
            WORKTREE_ENABLED=false
            shift
            ;;
        --devin-auto-exit)
            DEVIN_AUTO_EXIT=true
            shift
            ;;
        --no-devin-auto-exit)
            DEVIN_AUTO_EXIT=false
            shift
            ;;
        --merge-strategy)
            if [[ "$2" == "squash" || "$2" == "merge" || "$2" == "rebase" ]]; then
                WORKTREE_MERGE_STRATEGY="$2"
            else
                echo "Error: --merge-strategy must be 'squash', 'merge', or 'rebase'"
                exit 1
            fi
            shift 2
            ;;
        --quality-gates)
            WORKTREE_QUALITY_GATES="$2"
            shift 2
            ;;
        --task)
            if [[ -z "$2" ]]; then
                echo "Error: --task requires a task number (e.g. 3) or task ID (e.g. R05)"
                exit 1
            fi
            SPECIFIC_TASK_NUM="$2"
            shift 2
            ;;
        --parallel)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --parallel requires a positive integer (number of agents)"
                exit 1
            fi
            PARALLEL_COUNT="$2"
            shift 2
            ;;
        --parallel-bg)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --parallel-bg requires a positive integer (number of agents)"
                exit 1
            fi
            PARALLEL_COUNT="$2"
            PARALLEL_BG=true
            shift 2
            ;;
        --workspace)
            WORKSPACE_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If workspace mode requested, route to workspace handler
    # (workspace handles its own parallelism via run_workspace_tasks_parallel)
    if [[ "$WORKSPACE_MODE" == "true" ]]; then
        # Workspace + tmux: forward --workspace flag through tmux
        if [[ "$USE_TMUX" == "true" ]]; then
            check_tmux_available
            setup_tmux_session
        fi
        run_workspace_mode
        exit $?
    fi

    # If parallel mode requested (non-workspace), spawn agents (iTerm tabs or background jobs)
    if [[ "$PARALLEL_COUNT" -gt 0 ]]; then
        # Rebuild args without --parallel N / --parallel-bg N
        passthrough_args=()
        skip_next=false
        for arg in "${_RALPH_ORIGINAL_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                skip_next=false
                continue
            fi
            if [[ "$arg" == "--parallel" || "$arg" == "--parallel-bg" ]]; then
                skip_next=true
                continue
            fi
            passthrough_args+=("$arg")
        done
        export PARALLEL_BG
        spawn_parallel_agents "$PARALLEL_COUNT" ralph-devin "${passthrough_args[@]}"
        exit $?
    fi

    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    main
fi
