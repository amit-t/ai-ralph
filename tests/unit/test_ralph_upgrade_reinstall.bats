#!/usr/bin/env bats
# Unit tests for ralph-upgrade.sh: --reinstall flag and per-engine install
# chaining.
#
# Why this exists: when an urgent fix lands on origin/main without a
# version.json bump (release-please runs async), `ralph.upgrade` reports
# "already at <ver>" and exits 0 without picking up the fix. The
# --reinstall flag bypasses that gate. Additionally, the upgrade path
# previously called only install.sh, leaving ~/.ralph/devin and
# ~/.ralph/codex stale — _run_engine_installs now chains them.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

    CLONE="$TEST_DIR/clone"
    mkdir -p "$CLONE/lib" "$CLONE/devin" "$CLONE/codex"
    cp "$REPO_ROOT/ralph-upgrade.sh"        "$CLONE/"
    cp "$REPO_ROOT/lib/version-check.sh"    "$CLONE/lib/"
    cp "$REPO_ROOT/lib/bootstrap-detection.sh" "$CLONE/lib/"
    cat > "$CLONE/version.json" <<JSON
{"version":"9.9.9","released":"2026-01-01","check_ttl_hours":12,"channel":"stable","requires":{}}
JSON

    # Marker installers — append to $CLONE_LOG so we can verify chaining.
    cat > "$CLONE/install.sh" <<'SH'
#!/usr/bin/env bash
echo "ROOT_INSTALL_RAN" >> "$CLONE_LOG"
SH
    cat > "$CLONE/devin/install_devin.sh" <<'SH'
#!/usr/bin/env bash
echo "DEVIN_INSTALL_RAN:$1" >> "$CLONE_LOG"
SH
    cat > "$CLONE/codex/install_codex.sh" <<'SH'
#!/usr/bin/env bash
echo "CODEX_INSTALL_RAN:$1" >> "$CLONE_LOG"
SH
    chmod +x "$CLONE/install.sh" "$CLONE/devin/install_devin.sh" "$CLONE/codex/install_codex.sh"

    git -C "$CLONE" init -q
    git -C "$CLONE" config user.email t@e.com
    git -C "$CLONE" config user.name t
    git -C "$CLONE" add -A
    git -C "$CLONE" commit -qm "init"
    # ralph-upgrade.sh requires the clone to be on 'main'.
    git -C "$CLONE" branch -m main 2>/dev/null || true
    git -C "$CLONE" clone -q --bare "$CLONE" "$TEST_DIR/origin.git"
    git -C "$CLONE" remote add origin "$TEST_DIR/origin.git"
    git -C "$CLONE" fetch -q origin

    export CLONE_LOG="$TEST_DIR/install.log"
    : > "$CLONE_LOG"

    export WB_UPDATES_CACHE_DIR="$TEST_DIR/cache"
    mkdir -p "$WB_UPDATES_CACHE_DIR"
    export RALPH_CLONE="$CLONE"
    # Mark this tool as already bootstrapped so the upgrade path doesn't try
    # to write to ~/.cache/wb-updates outside the sandbox.
    mkdir -p "$WB_UPDATES_CACHE_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Convenience runner that injects the per-test environment cleanly.
_run_upgrade() {
    env CLONE_LOG="$CLONE_LOG" \
        RALPH_CLONE="$CLONE" \
        WB_UPDATES_CACHE_DIR="$WB_UPDATES_CACHE_DIR" \
        HOME="$TEST_DIR" \
        bash "$CLONE/ralph-upgrade.sh" "$@"
}

@test "ralph-upgrade: --help advertises --reinstall flag" {
    grep -q -- '--reinstall' "$CLONE/ralph-upgrade.sh"
}

@test "ralph-upgrade: without --reinstall, equal version exits 0 with 'already at'" {
    run _run_upgrade --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"already at"* ]]
    [ ! -s "$CLONE_LOG" ]
}

@test "ralph-upgrade: --reinstall reruns install scripts at same version" {
    run _run_upgrade --yes --reinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"reinstall requested"* ]]
    grep -q "ROOT_INSTALL_RAN" "$CLONE_LOG"
    grep -q "DEVIN_INSTALL_RAN:install" "$CLONE_LOG"
    grep -q "CODEX_INSTALL_RAN:install" "$CLONE_LOG"
}

@test "ralph-upgrade: --reinstall with --skip-install bypasses installers" {
    run _run_upgrade --yes --reinstall --skip-install
    [ "$status" -eq 0 ]
    [ ! -s "$CLONE_LOG" ]
}

@test "ralph-upgrade: engine installers absent are silently skipped" {
    # Commit the deletion so the clone stays clean (ralph-upgrade refuses dirty clones).
    git -C "$CLONE" rm -q "codex/install_codex.sh"
    git -C "$CLONE" commit -qm "drop codex installer for this test"
    run _run_upgrade --yes --reinstall
    [ "$status" -eq 0 ]
    grep -q "ROOT_INSTALL_RAN" "$CLONE_LOG"
    grep -q "DEVIN_INSTALL_RAN" "$CLONE_LOG"
    ! grep -q "CODEX_INSTALL_RAN" "$CLONE_LOG"
}

@test "ralph-upgrade: unknown flag rejected" {
    run _run_upgrade --bogus
    [ "$status" -ne 0 ]
}
