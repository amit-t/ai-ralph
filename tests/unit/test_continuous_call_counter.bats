#!/usr/bin/env bats
# Unit tests for the continuous-mode call-counter wiring (P0 #3).
#
# Background: lib/worker_pool.sh exports _atomic_inc_call_count, a race-free
# mkdir-locked increment for $CALL_COUNT_FILE. Before this fix, the helper
# was defined and exported but never called — each engine's
# increment_call_counter() used a non-locked cat→echo path that loses
# increments under concurrent worker tabs (proposal §5.5 explicitly required
# atomic increments).
#
# These tests lock down the wiring across all three engine wrappers
# (ralph_loop.sh, devin/ralph_loop_devin.sh, codex/ralph_loop_codex.sh):
#
#   - When CONTINUOUS_MODE=true OR CONTINUOUS_WORKER_ID is non-empty,
#     increment_call_counter MUST delegate to _atomic_inc_call_count.
#   - When neither is set, increment_call_counter MUST use the legacy
#     non-locked path (preserves V1 behavior on the single-iteration loop).

load '../helpers/test_helper'

WORKER_POOL_LIB="${BATS_TEST_DIRNAME}/../../lib/worker_pool.sh"
RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
DEVIN_LOOP="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
CODEX_LOOP="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR="${TEST_DIR}/.ralph"
    export CALL_COUNT_FILE="${RALPH_DIR}/.call_count"
    mkdir -p "$RALPH_DIR"
    echo "0" > "$CALL_COUNT_FILE"

    source "$WORKER_POOL_LIB"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Extract just the increment_call_counter function from a script file.
# Avoids sourcing the full engine (which has side effects like trap setup).
_extract_inc_fn() {
    local script="$1"
    # awk-extract the function body. Both engines define
    # `increment_call_counter() {` on one line and the closing `}` at
    # column 1, matching this pattern.
    awk '
        /^increment_call_counter\(\) \{/ { capturing = 1 }
        capturing { print }
        capturing && /^\}/ { capturing = 0 }
    ' "$script"
}

# =============================================================================
# Source-level guard: every engine wrapper must include the delegate.
# (Cheap static check — fails fast if a future refactor drops the hook.)
# =============================================================================

@test "ralph_loop.sh increment_call_counter calls _atomic_inc_call_count (P0 #3)" {
    grep -q '_atomic_inc_call_count' "$RALPH_LOOP"
    _extract_inc_fn "$RALPH_LOOP" | grep -q '_atomic_inc_call_count'
}

@test "devin ralph_loop_devin.sh increment_call_counter calls _atomic_inc_call_count (P0 #3)" {
    grep -q '_atomic_inc_call_count' "$DEVIN_LOOP"
    _extract_inc_fn "$DEVIN_LOOP" | grep -q '_atomic_inc_call_count'
}

@test "codex ralph_loop_codex.sh increment_call_counter calls _atomic_inc_call_count (P0 #3)" {
    grep -q '_atomic_inc_call_count' "$CODEX_LOOP"
    _extract_inc_fn "$CODEX_LOOP" | grep -q '_atomic_inc_call_count'
}

# =============================================================================
# Behavior: extract the actual function and verify dispatch.
# =============================================================================

@test "claude increment_call_counter delegates to _atomic_inc_call_count when CONTINUOUS_MODE=true (P0 #3)" {
    eval "$(_extract_inc_fn "$RALPH_LOOP")"
    # Spy on _atomic_inc_call_count to ensure it's called.
    _atomic_inc_call_count() { echo "ATOMIC_CALLED"; }
    export -f _atomic_inc_call_count

    CONTINUOUS_MODE=true
    run increment_call_counter
    assert_success
    [[ "$output" == *"ATOMIC_CALLED"* ]]
}

@test "claude increment_call_counter delegates when CONTINUOUS_WORKER_ID is set (P0 #3)" {
    eval "$(_extract_inc_fn "$RALPH_LOOP")"
    _atomic_inc_call_count() { echo "ATOMIC_CALLED"; }
    export -f _atomic_inc_call_count

    CONTINUOUS_MODE=false
    CONTINUOUS_WORKER_ID="ws-0-12345-9999"
    run increment_call_counter
    assert_success
    [[ "$output" == *"ATOMIC_CALLED"* ]]
}

@test "claude increment_call_counter uses legacy path outside continuous mode (P0 #3)" {
    eval "$(_extract_inc_fn "$RALPH_LOOP")"
    # If the spy is invoked, the test will fail loudly.
    _atomic_inc_call_count() { echo "BUG: atomic helper called outside continuous mode"; return 99; }
    export -f _atomic_inc_call_count

    CONTINUOUS_MODE=false
    CONTINUOUS_WORKER_ID=""
    echo "0" > "$CALL_COUNT_FILE"
    run increment_call_counter
    assert_success
    [[ "$output" == "1" ]]
    [[ "$(cat "$CALL_COUNT_FILE")" == "1" ]]
}

@test "devin increment_call_counter delegates to _atomic_inc_call_count in continuous mode (P0 #3)" {
    eval "$(_extract_inc_fn "$DEVIN_LOOP")"
    _atomic_inc_call_count() { echo "ATOMIC_CALLED_DEVIN"; }
    export -f _atomic_inc_call_count

    CONTINUOUS_MODE=true
    run increment_call_counter
    assert_success
    [[ "$output" == *"ATOMIC_CALLED_DEVIN"* ]]
}

@test "codex increment_call_counter delegates to _atomic_inc_call_count in continuous mode (P0 #3)" {
    eval "$(_extract_inc_fn "$CODEX_LOOP")"
    _atomic_inc_call_count() { echo "ATOMIC_CALLED_CODEX"; }
    export -f _atomic_inc_call_count

    CONTINUOUS_MODE=true
    run increment_call_counter
    assert_success
    [[ "$output" == *"ATOMIC_CALLED_CODEX"* ]]
}

# =============================================================================
# End-to-end race: 10 concurrent callers in continuous mode must each
# observe a unique increment, total === 10. Without the atomic helper the
# count would frequently undercount due to the TOCTOU window in the
# legacy cat→echo path.
# =============================================================================

@test "claude increment_call_counter is race-free under 10 concurrent callers (continuous) (P0 #3)" {
    eval "$(_extract_inc_fn "$RALPH_LOOP")"
    export -f increment_call_counter
    CONTINUOUS_MODE=true
    export CONTINUOUS_MODE

    echo "0" > "$CALL_COUNT_FILE"
    local pids=()
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ( increment_call_counter > /dev/null ) & pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    [[ "$(cat "$CALL_COUNT_FILE")" == "10" ]]
}
