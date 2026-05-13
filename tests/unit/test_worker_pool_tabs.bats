#!/usr/bin/env bats
# Unit tests for lib/worker_pool_tabs.sh — completion-protocol primitives,
# heartbeat, worker-id, GC, and tab-mode orchestrator basics.
#
# See docs/proposals/continuous-with-tabs.md for the design.

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
WORKER_POOL_TABS_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool_tabs.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export TEST_DIR
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"
    if [[ -f "$WORKER_POOL_LIB" ]]; then
        source "$WORKER_POOL_LIB"
    fi
    if [[ -f "$WORKER_POOL_TABS_LIB" ]]; then
        source "$WORKER_POOL_TABS_LIB"
    fi
    # Shorten heartbeat config so stale paths exercise quickly.
    export WORKER_POOL_TABS_HEARTBEAT_INTERVAL=1
    export WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS=2
    export WORKER_POOL_TABS_POLL_INTERVAL=0.05
    # Silence log helpers when present.
    log_status() { echo "[$1] ${@:2}"; }
    log_info()   { echo "[INFO] $*"; }
    export -f log_status log_info
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# generate_worker_id
# =============================================================================

@test "generate_worker_id produces unique IDs across rapid calls" {
    local a b c
    a=$(generate_worker_id "ws-0")
    b=$(generate_worker_id "ws-0")
    c=$(generate_worker_id "ws-0")
    [[ -n "$a" && -n "$b" && -n "$c" ]]
    # Tag should be at the start.
    [[ "$a" == ws-0-* ]]
    # All three should not all be identical (random suffix differentiates
    # within the same second).
    [[ ! ( "$a" == "$b" && "$b" == "$c" ) ]]
}

# =============================================================================
# write_completion_file / parse_completion_file
# =============================================================================

@test "write_completion_file writes valid JSON with all schema fields" {
    write_completion_file "ws-3-1715080000" "fix-login" 42 0 1715080000 12345 true
    local dir="${RALPH_DIR}/.continuous_completions"
    [[ -d "$dir" ]]
    local files
    files=$(ls "$dir" 2>/dev/null | grep -v '\.tmp$')
    [[ -n "$files" ]]
    local count
    count=$(echo "$files" | wc -l | tr -d ' ')
    [[ "$count" == "1" ]]
    # Schema fields all present.
    local content
    content=$(cat "${dir}/${files}")
    grep -q '"worker_id": "ws-3-1715080000"' <<< "$content"
    grep -q '"task_id": "fix-login"' <<< "$content"
    grep -q '"line_num": 42' <<< "$content"
    grep -q '"rc": 0' <<< "$content"
    grep -q '"started_at": 1715080000' <<< "$content"
    grep -q '"changes_detected": true' <<< "$content"
}

@test "write_completion_file performs atomic rename (no .tmp files visible after success)" {
    write_completion_file "wid" "" 0 0 100
    local dir="${RALPH_DIR}/.continuous_completions"
    # No tmp files left behind.
    local tmps
    tmps=$(ls "$dir" 2>/dev/null | grep '\.tmp$' || true)
    [[ -z "$tmps" ]]
}

@test "write_completion_file rejects missing required args" {
    run write_completion_file "" "" 0 0 100
    [[ "$status" -ne 0 ]]
}

@test "parse_completion_file extracts every field as tab-separated kv" {
    write_completion_file "myid" "abc-task" 7 1 1700000000 9999 false
    local file
    file=$(ls "${RALPH_DIR}/.continuous_completions/"*.json | head -1)
    run parse_completion_file "$file"
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -qE '^worker_id\smyid$'
    echo "$output" | grep -qE '^task_id\sabc-task$'
    echo "$output" | grep -qE '^line_num\s7$'
    echo "$output" | grep -qE '^rc\s1$'
    echo "$output" | grep -qE '^changes_detected\sfalse$'
}

# =============================================================================
# read_completion_files / delete_completion_file
# =============================================================================

@test "read_completion_files lists only finished (non-.tmp) completions" {
    local dir="${RALPH_DIR}/.continuous_completions"
    mkdir -p "$dir"
    : > "${dir}/a-100.json"
    : > "${dir}/b-200.json"
    : > "${dir}/c-300.json.tmp"
    run read_completion_files
    [[ "$status" -eq 0 ]]
    # 2 ready files, no .tmp file.
    [[ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]]
    ! echo "$output" | grep -q '\.tmp'
}

@test "read_completion_files returns empty output when dir is missing or empty" {
    run read_completion_files
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "delete_completion_file removes the named file" {
    local dir="${RALPH_DIR}/.continuous_completions"
    mkdir -p "$dir"
    : > "${dir}/foo.json"
    [[ -f "${dir}/foo.json" ]]
    delete_completion_file "foo.json"
    [[ ! -f "${dir}/foo.json" ]]
}

# =============================================================================
# Heartbeat
# =============================================================================

@test "write_heartbeat creates the heartbeat file" {
    write_heartbeat "ws-1"
    local file="${RALPH_DIR}/.continuous_heartbeats/ws-1"
    [[ -f "$file" ]]
}

@test "heartbeat_age_seconds is small for a freshly written heartbeat" {
    write_heartbeat "ws-2"
    local age
    age=$(heartbeat_age_seconds "ws-2")
    [[ "$age" =~ ^[0-9]+$ ]]
    [[ $age -lt 3 ]]
}

@test "heartbeat_age_seconds returns -1 for unknown worker" {
    run heartbeat_age_seconds "nonexistent"
    [[ "$output" == "-1" ]]
}

@test "is_heartbeat_stale returns true for missing heartbeat" {
    run is_heartbeat_stale "missing-worker"
    [[ "$status" -eq 0 ]]
}

@test "is_heartbeat_stale returns false for a fresh heartbeat" {
    write_heartbeat "ws-fresh"
    run is_heartbeat_stale "ws-fresh"
    [[ "$status" -ne 0 ]]
}

@test "is_heartbeat_stale returns true after the threshold elapses" {
    write_heartbeat "ws-old"
    # Backdate the mtime past the threshold (default is 2s in test setup).
    local file="${RALPH_DIR}/.continuous_heartbeats/ws-old"
    # macOS BSD touch supports -t with [[CC]YY]MMDDhhmm[.ss]; GNU touch
    # supports it too. Use an unambiguous old date.
    touch -t 200001010000 "$file"
    run is_heartbeat_stale "ws-old"
    [[ "$status" -eq 0 ]]
}

@test "start_heartbeat_writer ticks repeatedly and stop_heartbeat_writer halts it" {
    local pid
    pid=$(start_heartbeat_writer "ticker")
    [[ -n "$pid" ]]
    # Wait long enough for >= 2 ticks at interval=1s.
    sleep 2
    local file="${RALPH_DIR}/.continuous_heartbeats/ticker"
    [[ -f "$file" ]]
    local age_before
    age_before=$(heartbeat_age_seconds "ticker")
    [[ "$age_before" =~ ^[0-9]+$ ]]
    [[ $age_before -lt 2 ]]
    stop_heartbeat_writer "$pid"
    # Process should be gone.
    ! kill -0 "$pid" 2>/dev/null
}

# =============================================================================
# gc_stale_continuous_artifacts
# =============================================================================

@test "gc_stale_continuous_artifacts wipes orphaned completions/heartbeats when no orchestrator alive" {
    local comp="${RALPH_DIR}/.continuous_completions"
    local hb="${RALPH_DIR}/.continuous_heartbeats"
    mkdir -p "$comp" "$hb"
    : > "${comp}/stale-1.json"
    : > "${hb}/dead-worker"
    # No state file => no live orchestrator.
    gc_stale_continuous_artifacts
    [[ ! -f "${comp}/stale-1.json" ]]
    [[ ! -f "${hb}/dead-worker" ]]
}

@test "gc_stale_continuous_artifacts is a no-op when the recorded orchestrator is alive" {
    local comp="${RALPH_DIR}/.continuous_completions"
    local hb="${RALPH_DIR}/.continuous_heartbeats"
    mkdir -p "$comp" "$hb"
    : > "${comp}/keep-me.json"
    : > "${hb}/keep-me"
    # Write state with our own PID — guaranteed to be alive.
    local state="${RALPH_DIR}/.continuous_state"
    printf 'orchestrator_pid\t%s\nstarted_at\t%s\nin_flight\t\n' "$$" "$(date +%s)" > "$state"
    gc_stale_continuous_artifacts
    [[ -f "${comp}/keep-me.json" ]]
    [[ -f "${hb}/keep-me" ]]
}

# =============================================================================
# tabs_supported_by_terminal
# =============================================================================

@test "tabs_supported_by_terminal returns 1 when RALPH_DISABLE_TABS=true" {
    export RALPH_DISABLE_TABS=true
    run tabs_supported_by_terminal
    [[ "$status" -eq 1 ]]
}

@test "tabs_supported_by_terminal returns 0 under iTerm2 env" {
    unset RALPH_DISABLE_TABS
    export TERM_PROGRAM=iTerm.app
    # Reload parallel_spawn (provides detect_terminal_env).
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh" ]] && \
        source "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh"
    run tabs_supported_by_terminal
    [[ "$status" -eq 0 ]]
}

@test "tabs_supported_by_terminal returns 1 under plain terminal" {
    unset RALPH_DISABLE_TABS
    unset TERM_PROGRAM
    unset VSCODE_PID
    unset TERMINAL_EMULATOR
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh" ]] && \
        source "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh"
    run tabs_supported_by_terminal
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# worker_init_completion_protocol / worker_exit_handler
# =============================================================================

@test "worker_init_completion_protocol rejects missing CONTINUOUS_WORKER_ID" {
    unset CONTINUOUS_WORKER_ID
    run worker_init_completion_protocol
    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "CONTINUOUS_WORKER_ID is required"
}

@test "worker_exit_handler writes completion JSON with correct rc and IDs" {
    export CONTINUOUS_WORKER_ID="ws-test-42"
    export CONTINUOUS_WORKER_TASK_ID="R05"
    export CONTINUOUS_WORKER_LINE_NUM=12
    export CONTINUOUS_WORKER_STARTED_AT=1700000000
    # Skip the heartbeat writer for this synchronous test.
    export CONTINUOUS_WORKER_HB_PID=""

    worker_exit_handler 7

    local dir="${RALPH_DIR}/.continuous_completions"
    local file
    file=$(ls "$dir"/*.json 2>/dev/null | head -1)
    [[ -n "$file" ]]
    grep -q '"worker_id": "ws-test-42"' "$file"
    grep -q '"task_id": "R05"' "$file"
    grep -q '"line_num": 12' "$file"
    grep -q '"rc": 7' "$file"
    grep -q '"started_at": 1700000000' "$file"
}

@test "worker_exit_handler is idempotent (second call no-ops)" {
    export CONTINUOUS_WORKER_ID="ws-test-99"
    export CONTINUOUS_WORKER_STARTED_AT=1700000000
    export CONTINUOUS_WORKER_HB_PID=""

    worker_exit_handler 0
    local dir="${RALPH_DIR}/.continuous_completions"
    local count_after_first
    count_after_first=$(ls "$dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count_after_first" -eq 1 ]]
    # Sleep so the timestamp suffix would differ if we did re-write.
    sleep 1
    worker_exit_handler 0
    local count_after_second
    count_after_second=$(ls "$dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count_after_second" -eq 1 ]]
}

@test "worker_init_completion_protocol installs heartbeat and trap survives exit" {
    # Run a forked subshell so we can observe its completion file from the parent.
    export RALPH_DIR="${TEST_DIR}/.ralph"  # already set in setup, but make sure
    (
        export CONTINUOUS_WORKER_ID="ws-subshell-1"
        export CONTINUOUS_WORKER_TASK_ID="T-1"
        export CONTINUOUS_WORKER_LINE_NUM=3
        worker_init_completion_protocol
        # Sanity: heartbeat file was created.
        [[ -f "${RALPH_DIR}/.continuous_heartbeats/ws-subshell-1" ]] || exit 99
        # Subshell exits with rc=5; the EXIT trap should write the completion.
        exit 5
    ) || true
    # The completion file must exist with rc=5.
    local file
    file=$(ls "${RALPH_DIR}/.continuous_completions"/*.json 2>/dev/null | head -1)
    [[ -n "$file" ]]
    grep -q '"worker_id": "ws-subshell-1"' "$file"
    grep -q '"rc": 5' "$file"
    # Heartbeat was deleted on exit.
    [[ ! -f "${RALPH_DIR}/.continuous_heartbeats/ws-subshell-1" ]]
}
