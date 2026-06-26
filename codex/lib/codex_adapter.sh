#!/bin/bash

# Codex CLI Adapter Layer for Ralph
# Wraps the real (clap-based) Codex CLI to provide a consistent interface for
# the Ralph loop.
#
# Interface: codex [OPTIONS] [PROMPT]
#            codex <COMMAND> [ARGS]
#
# Key CLI mappings (verified against codex-cli 0.142.0):
#   Non-interactive:  codex exec [OPTIONS] "<prompt>"   (or `-` reads stdin)
#   JSONL events:     codex exec --json ...             (emits thread.started)
#   Resume session:   codex exec resume <SESSION_ID> "<prompt>"
#   Interactive TUI:  codex "<prompt>"  /  codex resume <SESSION_ID>
#   Auth check:       codex login status
#   Model select:     codex exec --model <MODEL>
#   Sandbox policy:   codex exec -s read-only|workspace-write|danger-full-access
#   Bypass all:       codex exec --dangerously-bypass-approvals-and-sandbox
#
# Session IDs are UUID "thread_id"s surfaced by `--json` (thread.started event)
# and persisted by the CLI under $CODEX_HOME/sessions/**/rollout-*.jsonl.
#
# NOTE on permission mapping: Ralph's user-facing CODEX_PERMISSION_MODE keeps the
# legacy values "auto" and "dangerous" for backward compat. They translate to:
#   auto      -> -s workspace-write                         (sandboxed, no prompts)
#   dangerous -> --dangerously-bypass-approvals-and-sandbox (no sandbox)
# `codex exec resume` does NOT accept -s, so on resume only the dangerous bypass
# flag is emitted; "auto" inherits the original session's sandbox policy.
#
# Version: 0.2.0

# Codex CLI command
CODEX_CMD="codex"

# Session tracking
CODEX_SESSION_ID=""
CODEX_SESSION_FILE="${RALPH_DIR:-.ralph}/.codex_session_id"
CODEX_SESSION_HISTORY_FILE="${RALPH_DIR:-.ralph}/.codex_session_history"

# Codex-specific configuration (can be overridden from .ralphrc.codex)
CODEX_MODEL="${CODEX_MODEL:-}"                         # e.g. gpt-5-codex, o3 (empty = config default)
CODEX_PERMISSION_MODE="${CODEX_PERMISSION_MODE:-dangerous}" # auto (-s workspace-write) or dangerous (bypass)

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

# Check if Codex CLI is installed and authenticated
check_codex_cli() {
    if ! command -v "$CODEX_CMD" &>/dev/null; then
        echo "ERROR: Codex CLI ('$CODEX_CMD') is not installed." >&2
        echo "" >&2
        echo "Install the official Codex CLI:" >&2
        echo "  npm install -g @openai/codex   (or: brew install codex)" >&2
        echo "" >&2
        echo "Then authenticate: codex login" >&2
        return 1
    fi

    # Check authentication status (real CLI: `codex login status`)
    local auth_output
    # shellcheck disable=SC2034 # captured for parallelism with auth_exit; reserved for future error message surface
    auth_output=$("$CODEX_CMD" login status 2>&1)
    local auth_exit=$?

    if [[ $auth_exit -ne 0 ]]; then
        echo "WARN: Codex CLI may not be authenticated. Run 'codex login'." >&2
    fi

    return 0
}

# Serialized auth pre-warm — run ONCE in the orchestrator before spawning
# parallel workers.
#
# Why: `codex login status` only checks that a session record exists; it does
# NOT prove codex can attach a bearer to a real request. When the on-disk
# ~/.codex/auth.json is stale/partial (or a token refresh is mid-write), codex
# sends no Authorization header and the API returns:
#   401 Unauthorized: Missing bearer or basic authentication in header
# Under `--parallel N` every worker shares the same ~/.codex/auth.json, so a
# refresh-write can race across workers and each failed worker spews ~10 retry
# lines of raw 401 JSON. Probing once, serially, before fan-out (a) forces any
# token refresh to happen a single time in the orchestrator and (b) aborts the
# whole dispatch with one actionable message instead of N walls of 401 noise.
#
# Controlled by:
#   CODEX_AUTH_PREWARM=true|false   (default true)
#   CODEX_AUTH_PREWARM_TIMEOUT=<s>  (default 60)
#
# Returns 0 if codex completed a trivial turn (auth healthy), 1 on auth failure.
codex_prewarm_auth() {
    if [[ "${CODEX_AUTH_PREWARM:-true}" != "true" ]]; then
        return 0
    fi
    command -v "$CODEX_CMD" &>/dev/null || return 0

    local timeout_s="${CODEX_AUTH_PREWARM_TIMEOUT:-45}"
    local tmp_out verdict="" waited=0 pid

    tmp_out=$(mktemp "${TMPDIR:-/tmp}/ralph_codex_prewarm.XXXXXX") || return 0

    # Trivial read-only turn streamed to a temp file. `-s read-only` avoids any
    # workspace mutation; the prompt is throwaway. We watch the JSONL stream and
    # short-circuit the moment auth is proven healthy or failed, so a healthy
    # probe returns in ~seconds instead of running a full agent turn.
    # stdin from /dev/null: `codex exec` otherwise blocks on "Reading additional
    # input from stdin..." when backgrounded without a closed stdin.
    ( "$CODEX_CMD" exec --json -s read-only "Reply with exactly: RALPH_AUTH_OK" \
        >"$tmp_out" 2>&1 </dev/null ) &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        # Failure: 401 / missing-bearer / turn.failed (websocket + https paths).
        if grep -qiE '401 Unauthorized|Missing bearer|Unauthorized:.*authentication|"type":"turn\.failed"' "$tmp_out" 2>/dev/null; then
            verdict="fail"; break
        fi
        # Success: post-auth activity. NOTE: "turn.started" fires BEFORE the API
        # call (it appears even in the 401 case), so it is NOT a success signal —
        # only item.* / turn.completed prove the bearer was accepted.
        if grep -qE '"type":"item\.started"|"type":"item\.completed"|"type":"turn\.completed"|RALPH_AUTH_OK' "$tmp_out" 2>/dev/null; then
            verdict="ok"; break
        fi
        if (( waited >= timeout_s )); then
            verdict="timeout"; break
        fi
        sleep 1; (( waited++ ))
    done

    # The probe turn is disposable — stop codex regardless of verdict.
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # Final evaluation: codex may finish so fast that the `kill -0` loop guard
    # exits before the last grep ran. Re-check the complete output once.
    if [[ -z "$verdict" ]]; then
        if grep -qiE '401 Unauthorized|Missing bearer|Unauthorized:.*authentication|"type":"turn\.failed"' "$tmp_out" 2>/dev/null; then
            verdict="fail"
        elif grep -qE '"type":"item\.started"|"type":"item\.completed"|"type":"turn\.completed"|RALPH_AUTH_OK' "$tmp_out" 2>/dev/null; then
            verdict="ok"
        fi
    fi

    rm -f "$tmp_out" 2>/dev/null

    if [[ "$verdict" == "fail" ]]; then
        echo "ERROR: Codex authentication failed (401 — no bearer token sent)." >&2
        echo "" >&2
        echo "  The Codex CLI could not attach credentials to its API request." >&2
        echo "  This usually means ~/.codex/auth.json is stale or was left in a" >&2
        echo "  partial state (e.g. an interrupted login or a concurrent token" >&2
        echo "  refresh). Parallel workers share that file, so the run was halted" >&2
        echo "  before fanning out to avoid a wall of 401 retries." >&2
        echo "" >&2
        echo "  Fix: re-authenticate, then retry:" >&2
        echo "      codex login" >&2
        echo "      codex exec --json -s read-only \"ok\"   # verify it works" >&2
        return 1
    fi

    if [[ "$verdict" == "ok" ]]; then
        # Auth healthy; any pending token refresh has now happened once, serially.
        return 0
    fi

    # Inconclusive (timeout / network blip). Don't hard-block on an ambiguous
    # probe — warn and let workers proceed.
    echo "WARN: Codex auth pre-warm was inconclusive (no verdict in ${timeout_s}s);" >&2
    echo "      proceeding. If workers fail with 401 'Missing bearer', run" >&2
    echo "      'codex login' and retry." >&2
    return 0
}

# =============================================================================
# COMMAND BUILDING
# =============================================================================

# Global array for Codex command arguments (avoids shell injection)
declare -a CODEX_CMD_ARGS=()

# Build Codex CLI command with proper flags using array (shell-injection safe)
# Populates global CODEX_CMD_ARGS array for direct execution
#
# Args:
#   $1 - prompt_file: Path to the prompt file
#   $2 - loop_context: Additional context string to append
#   $3 - session_id: Session ID for --resume (empty = new session)
#   $4 - print_mode: true = non-interactive (`codex exec`), false = interactive TUI
#   $5 - worktree_directive: If set, prepended at TOP of prompt so the agent
#        sees the working-directory constraint before any other instruction.
#
# Resulting argv shapes:
#   fresh   non-interactive: codex exec --json [--model M] <sandbox> "<prompt>"
#   resume  non-interactive: codex exec resume <id> --json [--model M] [bypass] "<prompt>"
#   fresh   interactive:     codex [--model M] "<prompt>"
#   resume  interactive:     codex resume <id> [--model M] "<prompt>"
#
# The full prompt text is passed as the final positional argument (the real
# `codex` CLI has no --prompt-file flag); callers invoke "${CODEX_CMD_ARGS[@]}"
# directly without redirecting stdin, so the prompt must live in argv.
build_codex_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local print_mode="${4:-false}"
    local worktree_directive="${5:-}"

    # Reset global array
    CODEX_CMD_ARGS=("$CODEX_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        echo "ERROR: Prompt file not found: $prompt_file" >&2
        return 1
    fi

    local resuming=false
    [[ -n "$session_id" ]] && resuming=true

    if [[ "$print_mode" == "true" ]]; then
        # Non-interactive: `codex exec` (optionally resuming a session).
        CODEX_CMD_ARGS+=("exec")
        if [[ "$resuming" == "true" ]]; then
            CODEX_CMD_ARGS+=("resume" "$session_id")
        fi
        # Structured JSONL events — lets us capture the thread_id (session id).
        CODEX_CMD_ARGS+=("--json")
    else
        # Interactive TUI: bare `codex` (or `codex resume <id>`).
        if [[ "$resuming" == "true" ]]; then
            CODEX_CMD_ARGS+=("resume" "$session_id")
        fi
    fi

    # Model selection (real flag: --model / -m)
    if [[ -n "$CODEX_MODEL" ]]; then
        CODEX_CMD_ARGS+=("--model" "$CODEX_MODEL")
    fi

    # Permission/sandbox mapping — only meaningful for non-interactive runs.
    # In interactive TUI mode the user approves actions manually, so no flag.
    if [[ "$print_mode" == "true" ]]; then
        case "$CODEX_PERMISSION_MODE" in
            dangerous)
                # Valid on both `codex exec` and `codex exec resume`.
                CODEX_CMD_ARGS+=("--dangerously-bypass-approvals-and-sandbox")
                ;;
            auto|"")
                # `codex exec resume` rejects -s; resumed sessions inherit the
                # original sandbox policy, so only set it on a fresh session.
                if [[ "$resuming" != "true" ]]; then
                    CODEX_CMD_ARGS+=("-s" "workspace-write")
                fi
                ;;
            read-only|workspace-write|danger-full-access)
                # Allow passing a raw codex sandbox value through directly.
                if [[ "$resuming" != "true" ]]; then
                    CODEX_CMD_ARGS+=("-s" "$CODEX_PERMISSION_MODE")
                fi
                ;;
            *)
                if [[ "$resuming" != "true" ]]; then
                    CODEX_CMD_ARGS+=("-s" "workspace-write")
                fi
                ;;
        esac
    fi

    # Build the effective prompt (merge worktree directive + loop context if any),
    # then pass its full text as the final positional PROMPT argument.
    local effective_prompt_file="$prompt_file"
    if [[ -n "$loop_context" || -n "$worktree_directive" ]]; then
        local prompt_dir
        prompt_dir=$(dirname "$prompt_file")
        local combined_file="${prompt_dir}/.codex_prompt_combined.md"

        # Worktree directive goes FIRST so the agent sees it before any other instruction
        if [[ -n "$worktree_directive" ]]; then
            printf '%s\n\n---\n\n' "$worktree_directive" > "$combined_file"
            cat "$prompt_file" >> "$combined_file"
        else
            cat "$prompt_file" > "$combined_file"
        fi

        if [[ -n "$loop_context" ]]; then
            printf '\n\n---\nRALPH LOOP CONTEXT: %s\n' "$loop_context" >> "$combined_file"
        fi
        effective_prompt_file="$combined_file"
    fi

    CODEX_CMD_ARGS+=("$(cat "$effective_prompt_file")")
}

# =============================================================================
# SESSION MANAGEMENT
# =============================================================================

# Directory where the Codex CLI persists session rollouts.
CODEX_SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"

# List recent Codex session IDs (newest first), one per line.
# The real CLI has no `codex list` command; sessions live as rollout files at
# $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl.
codex_list_sessions() {
    local limit="${1:-20}"
    [[ -d "$CODEX_SESSIONS_DIR" ]] || return 1
    # Newest-first by mtime; extract the trailing UUID from each filename.
    ls -t "$CODEX_SESSIONS_DIR"/*/*/*/rollout-*.jsonl 2>/dev/null \
        | head -n "$limit" \
        | sed -E 's/.*rollout-[0-9T:-]+-([0-9a-fA-F-]{36})\.jsonl$/\1/'
}

# Load saved session ID
codex_load_session() {
    if [[ -f "$CODEX_SESSION_FILE" ]]; then
        local session_id
        session_id=$(cat "$CODEX_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            CODEX_SESSION_ID="$session_id"
            echo "$session_id"
            return 0
        fi
    fi
    return 1
}

# Save session ID from Codex output or CLI list
# Tries multiple strategies to capture the session ID:
#   1. Extract from JSON output file (structured output)
#   2. Extract from text output (grep fallback)
#   3. Query `codex list --format json` for the most recent session
# Args:
#   $1 - output_file: Path to the Codex output file (may be raw terminal text)
codex_save_session() {
    local output_file=$1
    local session_id=""

    # Strategy 1+2: Extract from output file (JSON then text grep)
    if [[ -f "$output_file" ]]; then
        session_id=$(codex_extract_session_id "$output_file" 2>/dev/null)
    fi

    # Strategy 3: Query `codex list` for the most recent session
    # The Codex CLI output is often raw terminal text (TUI), so extraction may fail.
    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=$(codex_get_latest_session_id 2>/dev/null)
    fi

    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        echo "$session_id" > "$CODEX_SESSION_FILE"
        CODEX_SESSION_ID="$session_id"

        # Append to history with timestamp
        local timestamp
        timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
        echo "$timestamp $session_id" >> "$CODEX_SESSION_HISTORY_FILE"

        # Keep only last 50 entries
        if [[ -f "$CODEX_SESSION_HISTORY_FILE" ]]; then
            tail -50 "$CODEX_SESSION_HISTORY_FILE" > "${CODEX_SESSION_HISTORY_FILE}.tmp"
            mv "${CODEX_SESSION_HISTORY_FILE}.tmp" "$CODEX_SESSION_HISTORY_FILE"
        fi
        return 0
    fi

    return 1
}

# Reset session state
codex_reset_session() {
    rm -f "$CODEX_SESSION_FILE"
    # shellcheck disable=SC2034 # documented global side effect; consumed by other codex/* files
    CODEX_SESSION_ID=""
}

# Extract session ID from Codex `--json` output.
# The exec JSONL stream begins with: {"type":"thread.started","thread_id":"<uuid>"}
# Output files are often raw terminal captures (via `script`), so a robust regex
# grep is used in addition to a structured jq pass.
codex_extract_session_id() {
    local output_file=$1

    if [[ ! -f "$output_file" ]]; then
        return 1
    fi

    local session_id=""

    # Primary: grep the thread_id / session_id field (survives terminal noise).
    session_id=$(grep -oE '"(thread_id|session_id|sessionId|id)"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' "$output_file" 2>/dev/null \
        | grep -oE '[0-9a-fA-F-]{36}' \
        | head -1)

    # Secondary: structured jq pass over JSONL (clean output only).
    if [[ -z "$session_id" ]]; then
        session_id=$(jq -rs '
            (map(.thread_id // .session_id // .sessionId // empty) | map(select(. != null and . != "")) | .[0]) // empty
        ' "$output_file" 2>/dev/null)
    fi

    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        echo "$session_id"
        return 0
    fi

    return 1
}

# Get the most recent session ID from the Codex rollout store.
# Reads $CODEX_HOME/sessions/**/rollout-<ts>-<uuid>.jsonl (no `codex list` exists).
# Strategy: newest rollout file's session_meta payload, then its filename UUID.
# Returns: Session ID on stdout, or empty if unavailable.
codex_get_latest_session_id() {
    [[ -d "$CODEX_SESSIONS_DIR" ]] || return 1

    local newest
    newest=$(ls -t "$CODEX_SESSIONS_DIR"/*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
    [[ -n "$newest" ]] || return 1

    local session_id=""

    # Primary: first line is a session_meta record with payload.session_id / id.
    session_id=$(head -1 "$newest" 2>/dev/null \
        | jq -r '.payload.session_id // .payload.id // .session_id // .id // empty' 2>/dev/null)

    # Fallback: the UUID embedded in the rollout filename.
    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=$(printf '%s\n' "$newest" \
            | sed -E 's/.*rollout-[0-9T:-]+-([0-9a-fA-F-]{36})\.jsonl$/\1/')
    fi

    if [[ -n "$session_id" && "$session_id" != "null" ]]; then
        echo "$session_id"
        return 0
    fi

    return 1
}

# Check if session should be expired
codex_should_expire_session() {
    local expiry_hours="${CODEX_SESSION_EXPIRY_HOURS:-24}"
    
    if [[ ! -f "$CODEX_SESSION_FILE" ]]; then
        return 0  # No session file = expired
    fi
    
    local file_age_seconds
    if [[ "$(uname)" == "Darwin" ]]; then
        file_age_seconds=$(( $(date +%s) - $(stat -f %m "$CODEX_SESSION_FILE" 2>/dev/null || echo 0) ))
    else
        file_age_seconds=$(( $(date +%s) - $(stat -c %Y "$CODEX_SESSION_FILE" 2>/dev/null || echo 0) ))
    fi
    
    local expiry_seconds=$((expiry_hours * 3600))
    
    if [[ $file_age_seconds -gt $expiry_seconds ]]; then
        return 0  # Expired
    fi
    
    return 1  # Not expired
}

# Initialize session tracking
init_codex_session_tracking() {
    mkdir -p "$(dirname "$CODEX_SESSION_FILE")"
    
    # Check for expired session
    if codex_should_expire_session; then
        codex_reset_session
    fi
}

# =============================================================================
# RESULT / ERROR CLASSIFICATION
# =============================================================================

# codex_extract_turn_error - First error message from a Codex JSONL output file.
# Codex surfaces a failed turn as {"type":"error","message":...} and/or
# {"type":"turn.failed","error":{"message":...}}; the message often wraps a
# nested JSON carrying an HTTP status (e.g. 429 = rate limit).
# Args: $1 - output_file (Codex --json JSONL, may be wrapped by `script -q`)
# Echoes the first non-empty error message, or empty. Always returns 0.
codex_extract_turn_error() {
    local output_file=$1
    [[ -f "$output_file" && -s "$output_file" ]] || { echo ""; return 0; }
    jq -rs '
        [ (.[] | select(.type=="turn.failed") | .error.message?),
          (.[] | select(.type=="error")       | .message?) ]
        | map(select(. != null and . != "")) | .[0] // empty
    ' "$output_file" 2>/dev/null || true
}

# codex_is_rate_limit_message - True (rc 0) if an error message looks like a
# transient rate-limit / quota / 429 worth a backoff-retry (vs a hard failure).
# Args: $1 - error message string
codex_is_rate_limit_message() {
    local msg=$1
    echo "$msg" | grep -qiE '(rate.?limit|hit your limit|usage limit|resets|quota|too many|"status":[[:space:]]*429|(^|[^0-9])429([^0-9]|$))'
}

# =============================================================================
# BEADS BIDIRECTIONAL SYNC
# =============================================================================

# beads_mark_in_progress - Claim beads that are about to be worked on
# Scans fix_plan.md for uncompleted bead items and marks them in_progress via `bd update --claim`.
# Only claims beads whose current status is "open" (skips already in_progress/closed).
#
# Args:
#   $1 - fix_plan_file: Path to fix_plan.md
#   $2 - loop_count: Current loop number
# Returns:
#   0 on success, 1 if beads unavailable
beads_mark_in_progress() {
    local fix_plan_file="${1:-.ralph/fix_plan.md}"
    # shellcheck disable=SC2034 # documented function parameter; reserved for richer status output
    local loop_count="${2:-0}"

    if ! command -v bd &>/dev/null; then
        return 1
    fi

    if [[ ! -f "$fix_plan_file" ]]; then
        return 0
    fi

    # Find uncompleted items with bead IDs: "- [ ] [some-id] ..."
    local uncompleted_lines
    uncompleted_lines=$(grep -E '^\s*- \[ \] \[' "$fix_plan_file" 2>/dev/null) || return 0

    if [[ -z "$uncompleted_lines" ]]; then
        return 0
    fi

    # Get list of beads that are still in "open" status (not already in_progress)
    local open_ids=""
    local open_ids_json
    if open_ids_json=$(bd list --json --status open 2>/dev/null); then
        open_ids=$(echo "$open_ids_json" | jq -r '.[].id // empty' 2>/dev/null)
    fi

    local claimed=0
    while IFS= read -r line; do
        local bead_id
        bead_id=$(echo "$line" | sed -n 's/.*\[ \] \[\([a-zA-Z0-9_-]*\)\].*/\1/p' | head -1)

        if [[ -z "$bead_id" ]]; then
            continue
        fi

        # Only claim if this bead is currently open
        if echo "$open_ids" | grep -qxF "$bead_id" 2>/dev/null; then
            if bd update "$bead_id" --claim 2>/dev/null; then
                claimed=$((claimed + 1))
            fi
        fi
    done <<< "$uncompleted_lines"

    if [[ $claimed -gt 0 ]]; then
        echo "BEADS_CLAIM: Claimed $claimed bead(s) as in_progress" >&2
    fi

    return 0
}
