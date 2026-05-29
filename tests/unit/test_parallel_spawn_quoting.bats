#!/usr/bin/env bats
# Regression tests for lib/parallel_spawn.sh command quoting.
#
# Bug: the iTerm / IDE tab spawners joined the worker argv unquoted
# (${cmd_args[*]}) into the command typed into the new tab. The workspace task
# descriptor "repo|id|line|desc" routinely contains |, *, ;, (), and spaces, so
# the tab's shell (zsh) re-parsed it into bogus pipes / globs / separators and
# the worker command was mangled ("command not found", "no matches found").
#
# Fix: _ps_quote_cmd %q-quotes every token; _ps_applescript_escape handles the
# AppleScript string layer. These tests verify a descriptor survives quoting and
# re-parsing by both bash and zsh as a single intact argv element.

load '../helpers/test_helper'

setup() {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/parallel_spawn.sh"
    BIN="$(mktemp -d "${TMPDIR:-/tmp}/psq.XXXXXX")"
    OUT="$BIN/argv"
    # Stub that records each received argv element on its own line.
    cat > "$BIN/ralph-devin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$OUT"
EOF
    chmod +x "$BIN/ralph-devin"
    # A deliberately nasty descriptor: pipe field-seps, glob, comma, semicolon,
    # parens, spaces, and an embedded double-quote.
    DESC='gitlore|add-housekeeping|6|Add CODEOWNERS qa/fixtures/**, steering/**; (tier:mechanical) "note"'
}

teardown() {
    [[ -n "$BIN" && -d "$BIN" ]] && rm -rf "$BIN"
    return 0
}

# Build the worker command exactly as the spawners do, then run it through the
# given shell with the stub on PATH, and assert the descriptor arrives whole.
_assert_roundtrip() {
    local shell_bin="$1"
    local cmd
    cmd="$(_ps_quote_cmd ralph-devin --continuous-worker-id ws-2-1 --workspace-task "$DESC")"
    PATH="$BIN:$PATH" "$shell_bin" -c "$cmd"
    [[ -f "$OUT" ]] || { echo "stub never ran (shell=$shell_bin)"; return 1; }
    local got=() line
    while IFS= read -r line; do got+=("$line"); done < "$OUT"
    [[ "${got[0]}" == "--continuous-worker-id" ]] || { echo "argv0='${got[0]}'"; return 1; }
    [[ "${got[1]}" == "ws-2-1" ]]               || { echo "argv1='${got[1]}'"; return 1; }
    [[ "${got[2]}" == "--workspace-task" ]]      || { echo "argv2='${got[2]}'"; return 1; }
    [[ "${got[3]}" == "$DESC" ]]                 || { echo "descriptor mangled: '${got[3]}'"; return 1; }
    [[ "${#got[@]}" -eq 4 ]]                     || { echo "expected 4 args, got ${#got[@]}: ${got[*]}"; return 1; }
}

@test "descriptor survives quoting + re-parse under bash" {
    _assert_roundtrip bash
}

@test "descriptor survives quoting + re-parse under zsh" {
    if ! command -v zsh >/dev/null 2>&1; then skip "zsh not installed"; fi
    _assert_roundtrip zsh
}

@test "_ps_quote_cmd keeps simple args unchanged in token count" {
    run _ps_quote_cmd ralph --task 5
    [[ "$status" -eq 0 ]]
    # 3 whitespace-separated tokens, no metacharacters to escape.
    [[ "$(echo "$output" | wc -w | tr -d ' ')" == "3" ]]
}

@test "_ps_applescript_escape doubles backslash then escapes quote" {
    run _ps_applescript_escape 'a\b"c'
    [[ "$output" == 'a\\b\"c' ]]
}
