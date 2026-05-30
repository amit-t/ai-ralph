#!/usr/bin/env bats
# Regression tests for the .ralph scaffold guard + workspace anchor.
#
# Bug: the loop scripts created `.ralph/{logs,docs/generated}` at the top of the
# file, before argument parsing. Any invocation (even read-only --status/--help)
# scaffolded a stray .ralph/ in whatever directory the binary started in, which
# littered spurious stubs in e.g. a workbench root and tripped downstream
# is-ralph-enabled checks.
#
# Fix: scaffold only on an actual run, after arg parsing, refusing to scaffold
# outside a ralph-enabled or workspace directory.

load '../helpers/test_helper'

RALPH_BIN="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
DEVIN_BIN="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
CODEX_BIN="${BATS_TEST_DIRNAME}/../../codex/ralph_loop_codex.sh"

# Override the shared helper setup() so each test starts in a clean, EMPTY dir
# (the shared setup pre-creates .ralph/, which would mask the litter check).
setup() {
    TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ralphguard.XXXXXX")"
    cd "$TEST_TEMP_DIR" || return 1
    export RALPH_DISABLE_TABS=true
}

teardown() {
    cd /
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
    [[ -n "$WS_DIR" && -d "$WS_DIR" ]] && rm -rf "$WS_DIR"
    return 0
}

# --- read-only subcommands must not scaffold .ralph -------------------------

@test "claude --help in empty dir creates no .ralph" {
    run bash "$RALPH_BIN" --help
    assert_success
    [ ! -d .ralph ]
}

@test "devin --help in empty dir creates no .ralph" {
    run bash "$DEVIN_BIN" --help
    assert_success
    [ ! -d .ralph ]
}

@test "codex --help in empty dir creates no .ralph" {
    run bash "$CODEX_BIN" --help
    assert_success
    [ ! -d .ralph ]
}

@test "claude --status in empty dir creates no .ralph" {
    run bash "$RALPH_BIN" --status
    [ ! -d .ralph ]
}

@test "devin --status in empty dir creates no .ralph" {
    run bash "$DEVIN_BIN" --status
    [ ! -d .ralph ]
}

@test "codex --status in empty dir creates no .ralph" {
    run bash "$CODEX_BIN" --status
    [ ! -d .ralph ]
}

# --- plain run outside a ralph-enabled dir must refuse, not litter ----------

@test "claude plain run in non-enabled dir refuses and leaves no .ralph" {
    run bash "$RALPH_BIN"
    assert_failure
    echo "$output" | grep -q "not a ralph-enabled directory"
    [ ! -d .ralph ]
}

@test "devin plain run in non-enabled dir refuses and leaves no .ralph" {
    run bash "$DEVIN_BIN"
    assert_failure
    echo "$output" | grep -q "not a ralph-enabled directory"
    [ ! -d .ralph ]
}

@test "codex plain run in non-enabled dir refuses and leaves no .ralph" {
    run bash "$CODEX_BIN"
    assert_failure
    echo "$output" | grep -q "not a ralph-enabled directory"
    [ ! -d .ralph ]
}

# --- a ralph-enabled dir (.ralphrc) still scaffolds and is not refused ------

@test "claude run in enabled dir scaffolds .ralph and is not refused" {
    : > .ralphrc
    run timeout 8 bash "$RALPH_BIN" --task 1
    echo "$output" | grep -qv "not a ralph-enabled directory"
    [ -d .ralph/logs ]
}

@test "devin run in enabled dir scaffolds .ralph and is not refused" {
    : > .ralphrc
    run timeout 8 bash "$DEVIN_BIN" --task 1
    echo "$output" | grep -qv "not a ralph-enabled directory"
    [ -d .ralph/logs ]
}

@test "codex run in enabled dir scaffolds .ralph and is not refused" {
    : > .ralphrc
    run timeout 8 bash "$CODEX_BIN" --task 1
    echo "$output" | grep -qv "not a ralph-enabled directory"
    [ -d .ralph/logs ]
}

