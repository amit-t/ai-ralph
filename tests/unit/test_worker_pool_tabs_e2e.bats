#!/usr/bin/env bats
# End-to-end tests for the tab-mode orchestrator using a mock engine that
# simulates a worker by writing a completion file. Validates the full
# picker → spawn → completion → respawn cycle without needing real
# ralph / ralph-devin / ralph-codex binaries.
#
# See docs/proposals/continuous-with-tabs.md.

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
WORKER_POOL_TABS_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool_tabs.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export TEST_DIR
    export RALPH_DIR="${TEST_DIR}/.ralph"
    mkdir -p "${RALPH_DIR}/logs"

    [[ -f "$WORKER_POOL_LIB" ]] && source "$WORKER_POOL_LIB"
    [[ -f "$WORKER_POOL_TABS_LIB" ]] && source "$WORKER_POOL_TABS_LIB"

    # Fast polling and short heartbeat threshold for quick test runs.
    export WORKER_POOL_TABS_POLL_INTERVAL=0.05
    export WORKER_POOL_TABS_HEARTBEAT_INTERVAL=1
    export WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS=2

    # Build a mock engine that, when given --continuous-worker-id <wid>,
    # immediately writes a completion file with the desired rc. The rc is
    # encoded in the task id: tasks named "ok-*" succeed (rc=0), tasks
    # named "fail-*" fail (rc=1). This lets the picker / orchestrator
    # exercise all branches without real engine binaries.
    cat > "${TEST_DIR}/mock-engine.sh" << 'EOF'
#!/usr/bin/env bash
# Mock engine: $1 onwards contains --continuous-worker-id WID, --task TID
# (single-repo) or --workspace-task DESC (workspace).
WID=""
TID=""
DESC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --continuous-worker-id) WID="$2"; shift 2 ;;
        --task)                 TID="$2"; shift 2 ;;
        --workspace-task)       DESC="$2"; shift 2 ;;
        *)                                  shift   ;;
    esac
done
# Decide rc by looking at the task or descriptor.
TASK="${TID:-${DESC%%|*}}"
case "$TASK" in
    fail*)   RC=1 ;;
    timeout*) sleep 60 ; RC=0 ;;
    *)       RC=0 ;;
esac
# Write completion atomically.
DIR="${RALPH_DIR}/.continuous_completions"
mkdir -p "$DIR"
NOW=$(date +%s)
FILE="${DIR}/${WID}-${NOW}.json"
cat > "${FILE}.tmp" << JSON
{
  "worker_id": "${WID}",
  "task_id": "${TASK}",
  "line_num": 0,
  "rc": ${RC},
  "started_at": ${NOW},
  "ended_at": ${NOW},
  "tab_pid": $$,
  "changes_detected": false
}
JSON
mv "${FILE}.tmp" "${FILE}"
exit "$RC"
EOF
    chmod +x "${TEST_DIR}/mock-engine.sh"
    export RALPH_TABS_ENGINE_CMD="${TEST_DIR}/mock-engine.sh"
    # Force background mode so no real tab is opened.
    export PARALLEL_BG=true
    export RALPH_DISABLE_TABS=true   # ensure tabs_supported_by_terminal == false; test bypasses it
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

# Per-test picker / on-complete fixtures kept in a file so they survive
# subshell forks if needed. Tests set $TASK_QUEUE_FILE to a newline-separated
# list of descriptors; the picker peels one off the top each call.
_make_picker() {
    export TASK_QUEUE_FILE="${TEST_DIR}/queue.txt"
    : > "$TASK_QUEUE_FILE"
    for desc in "$@"; do
        echo "$desc" >> "$TASK_QUEUE_FILE"
    done

    _test_picker() {
        local skip_list="${1:-}"
        # Read first non-empty line, then trim it from the queue.
        local line
        line=$(head -1 "$TASK_QUEUE_FILE" 2>/dev/null)
        [[ -z "$line" ]] && return 1
        # Skip if in skip-list (the orchestrator handles re-pulls).
        if [[ -n "$skip_list" ]]; then
            local task_key="${line%% *}"
            if echo "$skip_list" | grep -qxF "$task_key"; then
                # Drop and recurse.
                tail -n +2 "$TASK_QUEUE_FILE" > "${TASK_QUEUE_FILE}.new" && mv "${TASK_QUEUE_FILE}.new" "$TASK_QUEUE_FILE"
                _test_picker "$skip_list"
                return $?
            fi
        fi
        tail -n +2 "$TASK_QUEUE_FILE" > "${TASK_QUEUE_FILE}.new" && mv "${TASK_QUEUE_FILE}.new" "$TASK_QUEUE_FILE"
        echo "$line"
    }
    export -f _test_picker
    _test_on_complete() { :; }
    export -f _test_on_complete
}

# =============================================================================
# End-to-end: picker + spawn + completion + respawn cycle
# =============================================================================

@test "run_continuous_worker_pool_tabs processes M=1 N=1 single-repo task" {
    _make_picker "ok-1|10|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    run run_continuous_worker_pool_tabs 1 1 1 0 _test_picker "" _test_on_complete
    [[ "$status" -eq 0 ]]
    # Summary printed.
    echo "$output" | grep -q "Continuous Execution Summary"
    echo "$output" | grep -q "Succeeded:       1"
    echo "$output" | grep -q "Stop reason:     target reached"
}

@test "run_continuous_worker_pool_tabs N=2 M=4 keeps both slots saturated" {
    _make_picker "ok-1|10|" "ok-2|20|" "ok-3|30|" "ok-4|40|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    run run_continuous_worker_pool_tabs 2 4 1 0 _test_picker "" _test_on_complete
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q "Completed:       4 attempts"
    echo "$output" | grep -q "Succeeded:       4"
}

@test "run_continuous_worker_pool_tabs honors K=1 skip-list on failure" {
    _make_picker "fail-1|10|" "ok-2|20|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    run run_continuous_worker_pool_tabs 1 3 1 0 _test_picker "" _test_on_complete
    # Mix of success and failure → exit 1; one fail counted toward M.
    echo "$output" | grep -q "Succeeded:       1"
    echo "$output" | grep -q "Failed:          1"
    echo "$output" | grep -q "Skipped:         1"
}

@test "run_continuous_worker_pool_tabs returns 0 when queue empties before M" {
    _make_picker "ok-1|10|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    run run_continuous_worker_pool_tabs 2 5 1 0 _test_picker "" _test_on_complete
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q "Stop reason:     queue empty"
}

@test "run_continuous_worker_pool_tabs returns 2 when another orchestrator is alive" {
    # Write a state file with the current PID — initial init refuses second
    # orchestrator by default.
    local sf="${RALPH_DIR}/.continuous_state"
    printf 'orchestrator_pid\t%s\nstarted_at\t%s\nin_flight\t\n' "$$" "$(date +%s)" > "$sf"

    _make_picker "ok-1|10|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    # Fork a child shell with a different PID; the parent shell's $$ is in
    # the state file so init_continuous_state should detect a live owner.
    run bash -c "
        source '$WORKER_POOL_LIB'
        source '$WORKER_POOL_TABS_LIB'
        export RALPH_DIR='$RALPH_DIR'
        export TASK_QUEUE_FILE='$TASK_QUEUE_FILE'
        export RALPH_TABS_ENGINE_CMD='${TEST_DIR}/mock-engine.sh'
        export WORKER_POOL_TABS_POLL_INTERVAL=0.05
        _test_picker() {
            local line=\$(head -1 \"\$TASK_QUEUE_FILE\" 2>/dev/null)
            [[ -z \"\$line\" ]] && return 1
            tail -n +2 \"\$TASK_QUEUE_FILE\" > \"\${TASK_QUEUE_FILE}.new\" && mv \"\${TASK_QUEUE_FILE}.new\" \"\$TASK_QUEUE_FILE\"
            echo \"\$line\"
        }
        _test_on_complete() { :; }
        run_continuous_worker_pool_tabs 1 1 1 0 _test_picker '' _test_on_complete
    "
    [[ "$status" -eq 2 ]]
}

# =============================================================================
# Workspace-mode spawning
# =============================================================================

@test "run_continuous_worker_pool_tabs spawns workspace workers with --workspace-task" {
    _make_picker "api|fix-login|42|Fix login flow" "web|update-deps|7|Bump deps"
    export RALPH_TABS_WORKSPACE_MODE="true"

    run run_continuous_worker_pool_tabs 2 2 1 0 _test_picker "" _test_on_complete
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q "Succeeded:       2"
}

# =============================================================================
# Stale heartbeat detection
# =============================================================================

# =============================================================================
# P0 #4 — Orphan-completion path must NOT collide with slot 0.
#
# Before this fix, _tabs_process_completion returned 0 on the
# unknown-worker_id (orphan) branch, which the caller's `local freed_slot=$?`
# interpreted as "slot 0 freed" — and would spawn a replacement into slot 0
# even though the real worker there was still alive. The fix uses the
# _TABS_LAST_SLOT global instead of the return value, so freed_slot is -1
# on the orphan path and the caller's `freed_slot -ge 0` guard rejects it.
# =============================================================================

@test "P0 #4: _tabs_process_completion uses _TABS_LAST_SLOT global, not return value (source contract)" {
    local lib="${BATS_TEST_DIRNAME}/../../lib/worker_pool_tabs.sh"
    # Default sentinel set at the top of the function.
    grep -q '_TABS_LAST_SLOT=-1' "$lib"
    # Success path stores the resolved slot index.
    grep -q '_TABS_LAST_SLOT="\$slot"' "$lib"
    # Caller reads the global instead of $? from the function call.
    grep -q 'freed_slot="\${_TABS_LAST_SLOT' "$lib"
}

@test "P0 #4: orphan completion does NOT cause a spurious spawn (behavioral)" {
    # Mock engine: writes BOTH (a) a completion with a junk worker_id
    # (orphan, processed first) AND (b) the legitimate completion with
    # the assigned worker_id. The orchestrator must:
    #   - Process the orphan as a no-op (no slot freed, no respawn).
    #   - Process the legitimate completion as slot 0 freed → respawn ok-2.
    #   - Total succeeded == 2, total executions == 2 (no extra spawn from
    #     the orphan being mis-credited as slot 0).
    cat > "${TEST_DIR}/dual-engine.sh" << 'EOF'
#!/usr/bin/env bash
WID=""
TID=""
DESC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --continuous-worker-id) WID="$2"; shift 2 ;;
        --task)                 TID="$2"; shift 2 ;;
        --workspace-task)       DESC="$2"; shift 2 ;;
        *)                                  shift   ;;
    esac
done
DIR="${RALPH_DIR}/.continuous_completions"
mkdir -p "$DIR"

# Orphan completion FIRST so ls -tr emits it before the legitimate one.
ORPHAN_WID="orphan-junk-${RANDOM}"
NOW=$(date +%s)
cat > "${DIR}/${ORPHAN_WID}-${NOW}.json.tmp" << JSON
{
  "worker_id": "${ORPHAN_WID}",
  "task_id": "junk",
  "line_num": 0,
  "rc": 0,
  "started_at": ${NOW},
  "ended_at": ${NOW},
  "tab_pid": $$,
  "changes_detected": false
}
JSON
mv "${DIR}/${ORPHAN_WID}-${NOW}.json.tmp" "${DIR}/${ORPHAN_WID}-${NOW}.json"

# Small mtime gap so the legitimate completion sorts AFTER the orphan.
sleep 0.1

NOW2=$(date +%s)
TASK="${TID:-${DESC%%|*}}"
case "$TASK" in
    fail*)    RC=1 ;;
    *)        RC=0 ;;
esac
cat > "${DIR}/${WID}-${NOW2}.json.tmp" << JSON
{
  "worker_id": "${WID}",
  "task_id": "${TASK}",
  "line_num": 0,
  "rc": ${RC},
  "started_at": ${NOW},
  "ended_at": ${NOW2},
  "tab_pid": $$,
  "changes_detected": false
}
JSON
mv "${DIR}/${WID}-${NOW2}.json.tmp" "${DIR}/${WID}-${NOW2}.json"
exit "$RC"
EOF
    chmod +x "${TEST_DIR}/dual-engine.sh"
    export RALPH_TABS_ENGINE_CMD="${TEST_DIR}/dual-engine.sh"

    _make_picker "ok-1|10|" "ok-2|20|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    run run_continuous_worker_pool_tabs 1 2 1 0 _test_picker "" _test_on_complete
    [[ "$status" -eq 0 ]]
    # M=2 expected: exactly 2 successes, no extra spurious spawn from the orphan.
    echo "$output" | grep -q "Succeeded:       2"
    echo "$output" | grep -q "Failed:          0"
}

@test "stale heartbeat declares worker dead and synthesizes a completion" {
    # We pre-populate the in-flight slot via a real worker that NEVER writes
    # a completion. The orchestrator should detect the stale heartbeat and
    # synthesize a completion with rc=124.
    # Approach: replace the engine with a no-op that ignores its args.
    cat > "${TEST_DIR}/silent-engine.sh" << 'EOF'
#!/usr/bin/env bash
# Sleep 30s without writing anything; the orchestrator must declare us dead.
sleep 30
EOF
    chmod +x "${TEST_DIR}/silent-engine.sh"
    export RALPH_TABS_ENGINE_CMD="${TEST_DIR}/silent-engine.sh"

    _make_picker "ok-1|10|"
    export RALPH_TABS_WORKSPACE_MODE="false"

    # Heartbeat stale threshold is 2s in setup; orchestrator should detect
    # within ~5s and synthesize the rc=124 completion.
    SECONDS=0
    run timeout 15 bash -c "
        source '$WORKER_POOL_LIB'
        source '$WORKER_POOL_TABS_LIB'
        export RALPH_DIR='$RALPH_DIR'
        export TASK_QUEUE_FILE='$TASK_QUEUE_FILE'
        export RALPH_TABS_ENGINE_CMD='${TEST_DIR}/silent-engine.sh'
        export WORKER_POOL_TABS_POLL_INTERVAL=0.2
        export WORKER_POOL_TABS_HEARTBEAT_INTERVAL=1
        export WORKER_POOL_TABS_HEARTBEAT_STALE_SECONDS=2
        export RALPH_TABS_WORKSPACE_MODE=false
        _test_picker() {
            local line=\$(head -1 \"\$TASK_QUEUE_FILE\" 2>/dev/null)
            [[ -z \"\$line\" ]] && return 1
            tail -n +2 \"\$TASK_QUEUE_FILE\" > \"\${TASK_QUEUE_FILE}.new\" && mv \"\${TASK_QUEUE_FILE}.new\" \"\$TASK_QUEUE_FILE\"
            echo \"\$line\"
        }
        _test_on_complete() { :; }
        run_continuous_worker_pool_tabs 1 1 1 0 _test_picker '' _test_on_complete
    "
    # The orchestrator should have exited with a stale-heartbeat synth completion.
    echo "$output" | grep -q "stale heartbeat for worker" || {
        echo "Output: $output"
        false
    }
    echo "$output" | grep -q "rc=124"
}
