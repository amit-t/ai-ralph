#!/usr/bin/env bats
# Pin cross-platform behaviour of lib/timeout_utils.sh.
# Wave 2 PR 2b of the WSL2 port. Lib uses a uname switch: Linux -> 'timeout',
# macOS -> 'gtimeout' (Homebrew coreutils) with 'timeout' as a fallback. These
# tests lock both branches plus the portable_timeout wrapper contract.

load '../helpers/test_helper'

source "$BATS_TEST_DIRNAME/../../lib/timeout_utils.sh"

@test "detect_timeout_command resolves to a non-empty command name" {
    reset_timeout_detection
    run detect_timeout_command
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "portable_timeout returns 124 on timeout" {
    run portable_timeout 1s sleep 5
    [ "$status" -eq 124 ]
}

@test "portable_timeout returns 0 on quick success" {
    run portable_timeout 5s echo ok
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "detect_timeout_command on Linux returns 'timeout'" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux-only assertion"
    reset_timeout_detection
    run detect_timeout_command
    [ "$output" = "timeout" ]
}

@test "detect_timeout_command on Darwin returns 'gtimeout' when available" {
    [[ "$(uname)" == "Darwin" ]] || skip "Darwin-only assertion"
    command -v gtimeout >/dev/null 2>&1 || skip "gtimeout not installed"
    reset_timeout_detection
    run detect_timeout_command
    [ "$output" = "gtimeout" ]
}
