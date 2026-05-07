#!/usr/bin/env bats
# Unit tests for continuous-mode shell aliases across all 3 engines.

bats_require_minimum_version 1.5.0

setup() {
    CLAUDE_ALIASES="${BATS_TEST_DIRNAME}/../../ALIASES.sh"
    DEVIN_ALIASES="${BATS_TEST_DIRNAME}/../../devin/ALIASES.sh"
    CODEX_ALIASES="${BATS_TEST_DIRNAME}/../../codex/ALIASES.sh"
}

@test "Claude ALIASES.sh defines rpc.cont" {
    grep -q '^rpc\.cont()' "$CLAUDE_ALIASES"
}

@test "Claude ALIASES.sh defines rpc.ws.cont" {
    grep -q '^rpc\.ws\.cont()' "$CLAUDE_ALIASES"
}

@test "Devin ALIASES.sh defines rpd.cont" {
    grep -q '^rpd\.cont()' "$DEVIN_ALIASES"
}

@test "Devin ALIASES.sh defines rpd.ws.cont" {
    grep -q '^rpd\.ws\.cont()' "$DEVIN_ALIASES"
}

@test "Codex ALIASES.sh defines rpx.cont" {
    grep -q '^rpx\.cont()' "$CODEX_ALIASES"
}

@test "Codex ALIASES.sh defines rpx.ws.cont" {
    grep -q '^rpx\.ws\.cont()' "$CODEX_ALIASES"
}

@test "rpc.cont calls --parallel and --max-tasks" {
    grep '^rpc\.cont()' "$CLAUDE_ALIASES" | grep -q -- '--parallel'
    grep '^rpc\.cont()' "$CLAUDE_ALIASES" | grep -q -- '--max-tasks'
}

@test "rpd.cont calls --parallel and --max-tasks" {
    grep '^rpd\.cont()' "$DEVIN_ALIASES" | grep -q -- '--parallel'
    grep '^rpd\.cont()' "$DEVIN_ALIASES" | grep -q -- '--max-tasks'
}

@test "rpx.cont calls --parallel and --max-tasks" {
    grep '^rpx\.cont()' "$CODEX_ALIASES" | grep -q -- '--parallel'
    grep '^rpx\.cont()' "$CODEX_ALIASES" | grep -q -- '--max-tasks'
}

@test "Claude workspace continuous alias passes --workspace" {
    grep '^rpc\.ws\.cont()' "$CLAUDE_ALIASES" | grep -q -- '--workspace'
}

@test "Devin workspace continuous alias passes --workspace" {
    grep '^rpd\.ws\.cont()' "$DEVIN_ALIASES" | grep -q -- '--workspace'
}

@test "Codex workspace continuous alias passes --workspace" {
    grep '^rpx\.ws\.cont()' "$CODEX_ALIASES" | grep -q -- '--workspace'
}

@test "rpc.cont rejects missing N argument with usage hint" {
    # The `${1:?...}` expansion exits the shell with status 127 when arg is
    # unset, so we declare that explicitly to avoid bats' BW01 warning.
    run -127 bash -c "source '$CLAUDE_ALIASES'; rpc.cont 2>&1"
    [[ "$output" == *"Usage: rpc.cont"* ]]
}
