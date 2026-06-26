#!/usr/bin/env bats
# Unit tests for Codex result/error classification helpers
# (codex_extract_turn_error, codex_is_rate_limit_message) in codex/lib/codex_adapter.sh.
# These back the is_error/429 handling in ralph_loop_codex.sh (parity with the
# Claude-path fix in PR #104).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # The adapter references RALPH_DIR at source time; give it a temp home.
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    source "$REPO_ROOT/codex/lib/codex_adapter.sh"
    OUT="$BATS_TEST_TMPDIR/out.jsonl"
}

# ── codex_extract_turn_error ────────────────────────────────────────────────

@test "extract: clean success returns empty" {
    cat > "$OUT" <<'EOF'
{"type":"thread.started","thread_id":"t1"}
{"type":"item.completed","item":{"type":"agent_message","text":"done"}}
{"type":"turn.completed"}
EOF
    run codex_extract_turn_error "$OUT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "extract: turn.failed message is surfaced" {
    cat > "$OUT" <<'EOF'
{"type":"thread.started","thread_id":"t1"}
{"type":"turn.failed","error":{"message":"{\"status\":400,\"error\":{\"message\":\"model not supported\"}}"}}
EOF
    run codex_extract_turn_error "$OUT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"model not supported"* ]]
}

@test "extract: top-level error message is surfaced" {
    cat > "$OUT" <<'EOF'
{"type":"error","message":"You have hit your usage limit"}
EOF
    run codex_extract_turn_error "$OUT"
    [[ "$output" == *"usage limit"* ]]
}

@test "extract: missing / empty file returns empty without error" {
    run codex_extract_turn_error "$BATS_TEST_TMPDIR/does-not-exist.jsonl"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── codex_is_rate_limit_message ─────────────────────────────────────────────

@test "ratelimit: 429 status is detected" {
    run codex_is_rate_limit_message '{"status":429,"error":{"message":"slow down"}}'
    [ "$status" -eq 0 ]
}

@test "ratelimit: usage-limit text is detected" {
    run codex_is_rate_limit_message "You have hit your usage limit"
    [ "$status" -eq 0 ]
}

@test "ratelimit: bare 429 token is detected" {
    run codex_is_rate_limit_message "HTTP 429 Too Many Requests"
    [ "$status" -eq 0 ]
}

@test "ratelimit: a 400 hard error is NOT a rate limit" {
    run codex_is_rate_limit_message '{"status":400,"error":{"message":"model not supported"}}'
    [ "$status" -ne 0 ]
}

@test "ratelimit: a value containing 4290 does not false-positive" {
    run codex_is_rate_limit_message "request id 4290 failed validation"
    [ "$status" -ne 0 ]
}
