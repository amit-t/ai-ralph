#!/usr/bin/env bash
# session_tracking.sh — shared Ralph session lifecycle helpers.
#
# These helpers were originally defined only in ralph_loop.sh (Claude engine).
# devin/ralph_loop_devin.sh and codex/ralph_loop_codex.sh called them without
# defining or sourcing them, producing
#     init_session_tracking: command not found
#     update_session_last_used: command not found
# in workspace continuous mode (issue surfaced via wb.ralph-dispatch).
# Extracting to a shared lib keeps the three engines from drifting again.
#
# Dependencies (caller responsibility):
#   - jq                                            (graceful no-op if missing)
#   - get_iso_timestamp from lib/date_utils.sh
#   - log_status                                    (best-effort, fallback echo)
#
# Required globals (or sensible defaults applied):
#   RALPH_DIR              defaults to ".ralph"
#   RALPH_SESSION_FILE     defaults to "$RALPH_DIR/.ralph_session"

# Resolve session file path even when the engine loop hasn't set RALPH_SESSION_FILE.
_session_tracking_resolve_file() {
    if [[ -n "${RALPH_SESSION_FILE:-}" ]]; then
        printf '%s' "$RALPH_SESSION_FILE"
        return 0
    fi
    printf '%s' "${RALPH_DIR:-.ralph}/.ralph_session"
}

# Fallback log_status if the engine hasn't sourced one yet.
_session_tracking_log() {
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$1" "$2"
    else
        echo "[$1] $2" >&2
    fi
}

# Generate a unique session ID (timestamp + RANDOM).
generate_session_id() {
    local ts rand
    ts=$(date +%s)
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking — called once per loop start.
# Creates RALPH_SESSION_FILE if missing; recovers it if corrupted.
init_session_tracking() {
    if ! command -v jq >/dev/null 2>&1; then
        _session_tracking_log "WARN" "jq not found — session tracking disabled"
        return 0
    fi

    local session_file
    session_file="$(_session_tracking_resolve_file)"
    mkdir -p "$(dirname "$session_file")" 2>/dev/null || true

    local ts
    ts=$(get_iso_timestamp)

    if [[ ! -f "$session_file" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$session_file"

        _session_tracking_log "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    if ! jq empty "$session_file" 2>/dev/null; then
        _session_tracking_log "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$session_file"
    fi
}

# Update last_used timestamp — called per loop iteration.
update_session_last_used() {
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi

    local session_file
    session_file="$(_session_tracking_resolve_file)"

    if [[ ! -f "$session_file" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    local updated jq_status
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$session_file" 2>/dev/null)
    jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$session_file"
    fi
}
