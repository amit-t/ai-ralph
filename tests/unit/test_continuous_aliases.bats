#!/usr/bin/env bats
# Unit tests for continuous-mode shell aliases across all 3 engines.
# After the proposal amendment (2026-05-08), the *.cont aliases were removed
# and the `*.p` / `*.ws.p` family extended to accept an optional second arg
# (M) which engages continuous mode.

bats_require_minimum_version 1.5.0

setup() {
    CLAUDE_ALIASES="${BATS_TEST_DIRNAME}/../../ALIASES.sh"
    DEVIN_ALIASES="${BATS_TEST_DIRNAME}/../../devin/ALIASES.sh"
    CODEX_ALIASES="${BATS_TEST_DIRNAME}/../../codex/ALIASES.sh"
}

# =============================================================================
# *.cont aliases must be GONE (collapsed into *.p)
# =============================================================================

@test "Claude ALIASES.sh no longer defines rpc.cont" {
    ! grep -q '^rpc\.cont()' "$CLAUDE_ALIASES"
}

@test "Claude ALIASES.sh no longer defines rpc.ws.cont" {
    ! grep -q '^rpc\.ws\.cont()' "$CLAUDE_ALIASES"
}

@test "Devin ALIASES.sh no longer defines rpd.cont" {
    ! grep -q '^rpd\.cont()' "$DEVIN_ALIASES"
}

@test "Devin ALIASES.sh no longer defines rpd.ws.cont" {
    ! grep -q '^rpd\.ws\.cont()' "$DEVIN_ALIASES"
}

@test "Codex ALIASES.sh no longer defines rpx.cont" {
    ! grep -q '^rpx\.cont()' "$CODEX_ALIASES"
}

@test "Codex ALIASES.sh no longer defines rpx.ws.cont" {
    ! grep -q '^rpx\.ws\.cont()' "$CODEX_ALIASES"
}

# =============================================================================
# *.p / *.ws.p still defined and now accept optional M
# =============================================================================

@test "rpc.p signature accepts optional M" {
    grep -q '^rpc\.p()' "$CLAUDE_ALIASES"
    # The function body must contain --parallel "$1" and pass $2 if present.
    grep '^rpc\.p()' "$CLAUDE_ALIASES" | grep -q -- '--parallel'
    grep '^rpc\.p()' "$CLAUDE_ALIASES" | grep -qE '\$\{?2\}?'
}

@test "rpc.ws.p signature accepts optional M" {
    grep -q '^rpc\.ws\.p()' "$CLAUDE_ALIASES"
    grep '^rpc\.ws\.p()' "$CLAUDE_ALIASES" | grep -q -- '--parallel'
    grep '^rpc\.ws\.p()' "$CLAUDE_ALIASES" | grep -qE '\$\{?2\}?'
}

@test "rpd.p signature accepts optional M" {
    grep -q '^rpd\.p()' "$DEVIN_ALIASES"
    grep '^rpd\.p()' "$DEVIN_ALIASES" | grep -q -- '--parallel'
    grep '^rpd\.p()' "$DEVIN_ALIASES" | grep -qE '\$\{?2\}?'
}

@test "rpd.ws.p signature accepts optional M" {
    grep -q '^rpd\.ws\.p()' "$DEVIN_ALIASES"
    grep '^rpd\.ws\.p()' "$DEVIN_ALIASES" | grep -q -- '--parallel'
    grep '^rpd\.ws\.p()' "$DEVIN_ALIASES" | grep -qE '\$\{?2\}?'
}

@test "rpx.p signature accepts optional M" {
    grep -q '^rpx\.p()' "$CODEX_ALIASES"
    grep '^rpx\.p()' "$CODEX_ALIASES" | grep -q -- '--parallel'
    grep '^rpx\.p()' "$CODEX_ALIASES" | grep -qE '\$\{?2\}?'
}

@test "rpx.ws.p signature accepts optional M" {
    grep -q '^rpx\.ws\.p()' "$CODEX_ALIASES"
    grep '^rpx\.ws\.p()' "$CODEX_ALIASES" | grep -q -- '--parallel'
    grep '^rpx\.ws\.p()' "$CODEX_ALIASES" | grep -qE '\$\{?2\}?'
}

# =============================================================================
# Behavior tests: alias produces correct command line for one and two args
# =============================================================================

# `rpc.p N` should produce `ralph --parallel N` (no extra positional).
# `rpc.p N M` should produce `ralph --parallel N M`.
# We assert this by overriding `ralph` as a function that records its argv.

@test "rpc.p N invokes ralph with --parallel N (no M)" {
    run -0 bash -c "
        source '$CLAUDE_ALIASES'
        ralph() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpc.p 3
    "
    [[ "$output" == "argv: --parallel 3" ]]
}

@test "rpc.p N M invokes ralph with --parallel N M" {
    run -0 bash -c "
        source '$CLAUDE_ALIASES'
        ralph() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpc.p 3 10
    "
    [[ "$output" == "argv: --parallel 3 10" ]]
}

@test "rpc.ws.p N M invokes ralph with --workspace --parallel N M" {
    run -0 bash -c "
        source '$CLAUDE_ALIASES'
        ralph() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpc.ws.p 2 8
    "
    [[ "$output" == "argv: --workspace --parallel 2 8" ]]
}

@test "rpd.p N M invokes ralph-devin with --parallel N M" {
    run -0 bash -c "
        source '$DEVIN_ALIASES'
        ralph-devin() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpd.p 2 6
    "
    [[ "$output" == "argv: --parallel 2 6" ]]
}

@test "rpd.ws.p N M invokes ralph-devin with --workspace --parallel N M" {
    run -0 bash -c "
        source '$DEVIN_ALIASES'
        ralph-devin() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpd.ws.p 3 12
    "
    [[ "$output" == "argv: --workspace --parallel 3 12" ]]
}

@test "rpx.p N invokes ralph-codex with --parallel N (no M)" {
    run -0 bash -c "
        source '$CODEX_ALIASES'
        ralph-codex() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpx.p 4
    "
    [[ "$output" == "argv: --parallel 4" ]]
}

@test "rpx.p N M invokes ralph-codex with --parallel N M" {
    run -0 bash -c "
        source '$CODEX_ALIASES'
        ralph-codex() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpx.p 2 7
    "
    [[ "$output" == "argv: --parallel 2 7" ]]
}

@test "rpx.ws.p N M invokes ralph-codex with --workspace --parallel N M" {
    run -0 bash -c "
        source '$CODEX_ALIASES'
        ralph-codex() { printf 'argv:'; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; }
        rpx.ws.p 2 5
    "
    [[ "$output" == "argv: --workspace --parallel 2 5" ]]
}

# =============================================================================
# Missing required N argument is still rejected with usage hint
# =============================================================================

@test "rpc.p with no args rejects with usage hint" {
    run -127 bash -c "source '$CLAUDE_ALIASES'; rpc.p 2>&1"
    [[ "$output" == *"Usage: rpc.p"* ]]
}

@test "rpd.p with no args rejects with usage hint" {
    run -127 bash -c "source '$DEVIN_ALIASES'; rpd.p 2>&1"
    [[ "$output" == *"Usage: rpd.p"* ]]
}

@test "rpx.p with no args rejects with usage hint" {
    run -127 bash -c "source '$CODEX_ALIASES'; rpx.p 2>&1"
    [[ "$output" == *"Usage: rpx.p"* ]]
}
