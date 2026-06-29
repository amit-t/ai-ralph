#!/usr/bin/env bats
# Unit tests for the Devin default model (swe-1.6).
#
# Behavior under test:
#   - The Ralph Devin loop defaults DEVIN_MODEL to swe-1.6 when unset.
#   - Override precedence is preserved: --model CLI > DEVIN_MODEL env >
#     .ralphrc.devin > built-in default.
#   - build_devin_command emits "--model <value>" from DEVIN_MODEL.
#   - The plan/workspace engine runners (ralph_plan.sh + lib/workspace_plan.sh)
#     default Devin to swe-1.6 while still honoring an explicit --model.

load '../helpers/test_helper'

LOOP_SCRIPT="${BATS_TEST_DIRNAME}/../../devin/ralph_loop_devin.sh"
ADAPTER="${BATS_TEST_DIRNAME}/../../devin/lib/devin_adapter.sh"
WORKSPACE_PLAN_LIB="${BATS_TEST_DIRNAME}/../../lib/workspace_plan.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# Loop default + precedence (top-level defaults in ralph_loop_devin.sh)
# =============================================================================

@test "devin loop defaults DEVIN_MODEL to swe-1.6 when unset" {
    run env -u DEVIN_MODEL bash -c \
        "source '$LOOP_SCRIPT' >/dev/null 2>&1; echo \"MODEL=\$DEVIN_MODEL\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL=swe-1.6"* ]]
}

@test "devin loop leaves _env_DEVIN_MODEL empty when DEVIN_MODEL unset" {
    # Critical: an unset DEVIN_MODEL must NOT be snapshotted as the default,
    # otherwise load_ralphrc would clobber a .ralphrc.devin override.
    run env -u DEVIN_MODEL bash -c \
        "source '$LOOP_SCRIPT' >/dev/null 2>&1; echo \"SNAP=[\$_env_DEVIN_MODEL]\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"SNAP=[]"* ]]
}

@test "DEVIN_MODEL env var overrides the swe-1.6 default" {
    run env DEVIN_MODEL=opus bash -c \
        "source '$LOOP_SCRIPT' >/dev/null 2>&1; echo \"MODEL=\$DEVIN_MODEL\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL=opus"* ]]
}

@test ".ralphrc.devin DEVIN_MODEL beats the swe-1.6 default" {
    printf 'DEVIN_MODEL=swe\n' > .ralphrc.devin
    run env -u DEVIN_MODEL bash -c \
        "cd '$TEST_DIR'; source '$LOOP_SCRIPT' >/dev/null 2>&1; load_ralphrc; echo \"MODEL=\$DEVIN_MODEL\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL=swe"* ]]
}

@test "DEVIN_MODEL env beats .ralphrc.devin (env > ralphrc)" {
    printf 'DEVIN_MODEL=swe\n' > .ralphrc.devin
    run env DEVIN_MODEL=opus bash -c \
        "cd '$TEST_DIR'; source '$LOOP_SCRIPT' >/dev/null 2>&1; load_ralphrc; echo \"MODEL=\$DEVIN_MODEL\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL=opus"* ]]
}

# =============================================================================
# build_devin_command passthrough (devin_adapter.sh)
# =============================================================================

@test "build_devin_command emits --model from DEVIN_MODEL" {
    printf 'do the thing\n' > prompt.md
    run bash -c "
        source '$ADAPTER' >/dev/null 2>&1
        DEVIN_MODEL=swe-1.6
        build_devin_command 'prompt.md' '' '' true ''
        printf '%s\n' \"\${DEVIN_CMD_ARGS[@]}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"--model"* ]]
    [[ "$output" == *"swe-1.6"* ]]
}

@test "build_devin_command omits --model when DEVIN_MODEL empty" {
    printf 'do the thing\n' > prompt.md
    run bash -c "
        source '$ADAPTER' >/dev/null 2>&1
        DEVIN_MODEL=''
        build_devin_command 'prompt.md' '' '' true ''
        printf '%s\n' \"\${DEVIN_CMD_ARGS[@]}\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"--model"* ]]
}

# =============================================================================
# Plan / workspace engine runner default (lib/workspace_plan.sh)
# =============================================================================

@test "workspace_plan_run_engine defaults Devin to swe-1.6 when no model given" {
    mkdir -p repo
    printf 'prompt body\n' > prompt.md

    # Stub devin: record args, then write the output file the runner checks for.
    cat > stub-devin << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RALPH_TEST_ARGS"
printf 'out\n' > "$RALPH_TEST_OUTPUT"
STUB
    chmod +x stub-devin

    run env DEVIN_CMD="$TEST_DIR/stub-devin" \
        RALPH_TEST_ARGS="$TEST_DIR/args.txt" \
        RALPH_TEST_OUTPUT="$TEST_DIR/out.md" \
        bash -c "
            source '$WORKSPACE_PLAN_LIB' >/dev/null 2>&1
            workspace_plan_run_engine devin '' '' repo '$TEST_DIR/repo' '$TEST_DIR/out.md' '$TEST_DIR/prompt.md' true
        "
    [ "$status" -eq 0 ]
    grep -q -- '--model' "$TEST_DIR/args.txt"
    grep -qx 'swe-1.6' "$TEST_DIR/args.txt"
}

@test "workspace_plan_run_engine honors explicit Devin model over the default" {
    mkdir -p repo
    printf 'prompt body\n' > prompt.md

    cat > stub-devin << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RALPH_TEST_ARGS"
printf 'out\n' > "$RALPH_TEST_OUTPUT"
STUB
    chmod +x stub-devin

    run env DEVIN_CMD="$TEST_DIR/stub-devin" \
        RALPH_TEST_ARGS="$TEST_DIR/args.txt" \
        RALPH_TEST_OUTPUT="$TEST_DIR/out.md" \
        bash -c "
            source '$WORKSPACE_PLAN_LIB' >/dev/null 2>&1
            workspace_plan_run_engine devin opus '' repo '$TEST_DIR/repo' '$TEST_DIR/out.md' '$TEST_DIR/prompt.md' true
        "
    [ "$status" -eq 0 ]
    grep -qx 'opus' "$TEST_DIR/args.txt"
    ! grep -qx 'swe-1.6' "$TEST_DIR/args.txt"
}
