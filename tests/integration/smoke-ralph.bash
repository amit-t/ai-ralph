#!/usr/bin/env bash
# Local mirror of .github/workflows/smoke-ralph.yml.
#
# Runs install + enable workspace end-to-end against a tiny fixture repo in a
# temp sandbox. Cross-platform: skips apt-get on macOS (assumes brew prereqs).
#
# Usage: bash tests/integration/smoke-ralph.bash
# Exit codes: 0 success, non-zero on any failed assert.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OS="$(uname -s)"
log() { printf '[smoke-ralph] %s\n' "$*"; }
fail() { printf '[smoke-ralph] FAIL: %s\n' "$*" >&2; exit 1; }

# 1. Prereq check (Linux installs via apt; macOS assumes brew install jq gh git).
log "OS=$OS, sandbox=$TMP_DIR"
if [[ "$OS" == "Linux" ]]; then
    if ! command -v jq >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            log "installing jq + gh via apt-get"
            sudo apt-get update -qq
            sudo apt-get install -y -qq jq gh git
        else
            fail "missing jq/gh and apt-get unavailable; install manually"
        fi
    fi
elif [[ "$OS" == "Darwin" ]]; then
    for tool in jq gh git; do
        command -v "$tool" >/dev/null 2>&1 \
            || fail "$tool missing; install via 'brew install $tool'"
    done
else
    fail "unsupported OS for smoke test: $OS (Linux and Darwin only)"
fi

# 2. Run the installer. install.sh is already non-interactive (no prompts).
# We isolate HOME so the smoke test does not clobber a real ~/.ralph install.
SANDBOX_HOME="$TMP_DIR/home"
mkdir -p "$SANDBOX_HOME"
log "running installer with HOME=$SANDBOX_HOME"
HOME="$SANDBOX_HOME" bash "$REPO_ROOT/install.sh" >"$TMP_DIR/install.log" 2>&1 \
    || { cat "$TMP_DIR/install.log"; fail "install.sh failed"; }
log "install.sh exit=0"

# 3. Build the tiny fixture target repo.
FIXTURE="$TMP_DIR/fixture-repo"
mkdir -p "$FIXTURE"
(
    cd "$FIXTURE"
    git init -q -b main 2>/dev/null || git init -q
    git config user.email a@b.c
    git config user.name a
    : > fix_plan.md
    git add fix_plan.md
    git commit -q -m "init"
)
log "fixture repo built at $FIXTURE"

# 4. Enable ralph workspace (non-interactive variant). Uses the local script to
# bypass dependence on a global install when iterating.
(
    cd "$FIXTURE"
    HOME="$SANDBOX_HOME" RALPH_HOME="$SANDBOX_HOME/.ralph" \
        bash "$REPO_ROOT/ralph_enable_ci.sh" >"$TMP_DIR/enable.log" 2>&1
) || { cat "$TMP_DIR/enable.log"; fail "ralph_enable_ci.sh failed"; }
log "ralph_enable_ci.sh exit=0"

# 5. Plan binary loads (smoke; real planning needs an AI engine + API key,
# which is out of scope for this end-to-end shape).
HOME="$SANDBOX_HOME" bash "$REPO_ROOT/ralph_plan.sh" --help \
    >"$TMP_DIR/plan-help.log" 2>&1 \
    || { cat "$TMP_DIR/plan-help.log"; fail "ralph_plan.sh --help failed"; }
log "ralph_plan.sh --help exit=0"

# 6. Final assertion: fixture has .ralph/fix_plan.md.
if [[ ! -f "$FIXTURE/.ralph/fix_plan.md" ]]; then
    fail ".ralph/fix_plan.md missing in fixture after enable"
fi
log "asserted $FIXTURE/.ralph/fix_plan.md exists"

log "OK"
