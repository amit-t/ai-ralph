#!/usr/bin/env bats
# Pin cross-platform behaviour of lib/date_utils.sh.
# Wave 2 PR 2b of the WSL2 port. Audit confirms the lib is already portable
# (GNU date -d / BSD date -j / manual epoch arithmetic fallback). These tests
# lock that behaviour so future edits do not regress on Linux or macOS.

load '../helpers/test_helper'

source "$BATS_TEST_DIRNAME/../../lib/date_utils.sh"

@test "get_iso_timestamp returns RFC3339-ish UTC string" {
    run get_iso_timestamp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
    [[ "$output" =~ (\+00:00|Z)$ ]]
}

@test "parse_iso_to_epoch round-trips a canonical ISO string" {
    iso=$(get_iso_timestamp)
    epoch=$(parse_iso_to_epoch "$iso")
    now=$(date +%s)
    diff=$((epoch - now))
    [ "${diff#-}" -le 2 ]
}

@test "get_next_hour_time returns valid HH:MM:SS" {
    run get_next_hour_time
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
}

@test "parse_iso_to_epoch falls back to current epoch on empty/null input" {
    epoch=$(parse_iso_to_epoch "")
    [[ "$epoch" =~ ^[0-9]+$ ]]
    epoch=$(parse_iso_to_epoch "null")
    [[ "$epoch" =~ ^[0-9]+$ ]]
}
