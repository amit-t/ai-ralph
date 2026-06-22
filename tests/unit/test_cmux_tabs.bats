#!/usr/bin/env bats
# Tests for cmux tabbed-layout spawning in lib/parallel_spawn.sh.
#
# Bug: opening one `cmux new-split down` pane per worker stacked 10-20 panes on
# top of each other in CMUX until none were legible. Fix: open ONE pane to the
# RIGHT of the dispatch surface and add each worker as a TAB (a new surface)
# inside that pane. cmux renders multiple surfaces in a pane as a tab strip.
#
# These tests drive a cmux mock (records every subcommand, maintains pane state)
# and assert: one right pane is opened, one tab per worker, the right pane is
# shared across the independent spawn_cmux_panes calls continuous mode makes,
# stale panes are recreated, tabs can be labelled, and the legacy panes layout
# is still reachable behind RALPH_CMUX_LAYOUT=panes.

load '../helpers/test_helper'

setup() {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh"

    BIN="$(mktemp -d "${TMPDIR:-/tmp}/cmuxtabs.XXXXXX")"
    export RALPH_CMUX_STATE_DIR="$BIN/state"
    mkdir -p "$RALPH_CMUX_STATE_DIR"
    export CMUX_MOCK_DIR="$BIN/mock"
    mkdir -p "$CMUX_MOCK_DIR"
    export CMUX_WORKSPACE_ID="workspace:42"
    export CMUX_SURFACE_ID="surface:9"

    # cmux mock: maintains pane state in $CMUX_MOCK_DIR/panes, records every
    # subcommand to $CMUX_MOCK_DIR/calls.log, and mimics the real ref output:
    #   new-split  -> "OK surface:<n> workspace:42"   (+ appends a pane)
    #   new-surface-> "OK surface:<n> pane:<p> workspace:42"
    #   list-panes -> one "  pane:<n>  [1 surface]" line per stored pane
    cat > "$BIN/cmux" <<'STUB'
#!/usr/bin/env bash
dir="${CMUX_MOCK_DIR:?}"
log="$dir/calls.log"; panes="$dir/panes"; seqf="$dir/seq"
mkdir -p "$dir"; : >> "$log"; : >> "$panes"
[[ -s "$seqf" ]] || echo 100 > "$seqf"
_next(){ local n; n=$(cat "$seqf"); n=$((n+1)); echo "$n" > "$seqf"; echo "$n"; }
cmd="$1"; shift || true
echo "$cmd $*" >> "$log"
case "$cmd" in
  list-panes)
    while IFS= read -r p; do [[ -n "$p" ]] && echo "  $p  [1 surface]"; done < "$panes" ;;
  new-split)
    pid="pane:$(_next)"; sid="surface:$(_next)"
    echo "$pid" >> "$panes"
    echo "OK $sid workspace:42" ;;
  new-surface)
    sid="surface:$(_next)"; pane=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "--pane" ]] && pane="$2"; shift; done
    echo "OK $sid ${pane:-pane:0} workspace:42" ;;
  *) echo "OK" ;;
esac
STUB
    chmod +x "$BIN/cmux"
    PATH="$BIN:$PATH"
}

teardown() {
    [[ -n "$BIN" && -d "$BIN" ]] && rm -rf "$BIN"
    return 0
}

_n() { grep -c "$1" "$CMUX_MOCK_DIR/calls.log" 2>/dev/null || true; }

@test "batch of 3 opens ONE right pane and 3 tabs (reusing the split surface)" {
    run spawn_cmux_panes 3 ralph --task X
    [ "$status" -eq 0 ]
    [ "$(_n '^new-split right')" -eq 1 ]
    [ "$(_n '^new-surface')" -eq 2 ]      # tab1 reuses split surface, +2 new = 3 tabs
    [ "$(_n '^send ')" -eq 3 ]
    [ "$(_n '^new-split down')" -eq 0 ]   # never stack panes in tab mode
}

@test "two separate count=1 calls share one right pane (continuous workers)" {
    spawn_cmux_panes 1 ralph --task A
    spawn_cmux_panes 1 ralph --task B
    [ "$(_n '^new-split right')" -eq 1 ]  # right pane created once, reused
    [ "$(_n '^new-surface')" -eq 1 ]      # call1 reuses split surface, call2 opens a tab
    [ "$(_n '^send ')" -eq 2 ]
}

@test "legacy RALPH_CMUX_LAYOUT=panes stacks new-split down per worker" {
    export RALPH_CMUX_LAYOUT=panes
    run spawn_cmux_panes 2 ralph --task Y
    [ "$status" -eq 0 ]
    [ "$(_n '^new-split down')" -eq 2 ]
    [ "$(_n '^new-surface')" -eq 0 ]
    [ "$(_n '^new-split right')" -eq 0 ]
}

@test "stale right pane is recreated when it disappears" {
    spawn_cmux_panes 1 ralph --task A
    : > "$CMUX_MOCK_DIR/panes"             # simulate the user closing the panes
    spawn_cmux_panes 1 ralph --task B
    [ "$(_n '^new-split right')" -eq 2 ]   # recreated rather than reusing a dead ref
}

@test "RALPH_CMUX_TAB_LABEL renames the worker tab" {
    export RALPH_CMUX_TAB_LABEL="task-alpha"
    run spawn_cmux_panes 1 ralph --task A
    [ "$status" -eq 0 ]
    grep -q '^rename-tab .*task-alpha' "$CMUX_MOCK_DIR/calls.log"
}

@test "missing cmux falls back to background processes (no panes opened)" {
    rm -f "$BIN/cmux"
    cd "$BIN"                              # keep the .ralph/logs fallback out of the repo
    run spawn_cmux_panes 1 true
    [ "$status" -eq 0 ]
    [ ! -s "$CMUX_MOCK_DIR/calls.log" ]
}
