# Fix Plan Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ralph-plan --status` that uses an AI engine to analyze `.ralph/fix_plan.md` and return a task summary, per-section breakdown, and actionable insights.

**Architecture:** A new `lib/fix_plan_status.sh` helper exports `find_fix_plan` (walk-up search) and `show_fix_plan_status` (builds prompt, invokes AI). `ralph_plan.sh` sources this helper when `--status` is passed and exits before any planning logic runs. Three alias files each get a `.plan.s` shortcut.

**Tech Stack:** Bash 3.2+, existing ralph engine CLIs (claude / codex / devin), mktemp

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| **Create** | `lib/fix_plan_status.sh` | `find_fix_plan` + `show_fix_plan_status` functions |
| **Create** | `tests/test_fix_plan_status.sh` | Unit tests for the lib helper |
| **Modify** | `ralph_plan.sh` | Add `STATUS_MODE` var, `--status` in `parse_args`, early exit in `main`, `--status` in `show_help` |
| **Modify** | `ALIASES.sh` | Add `rpc.plan.s` alias |
| **Modify** | `codex/ALIASES.sh` | Add `rpx.plan.s` alias |
| **Modify** | `devin/ALIASES.sh` | Add `rpd.plan.s` alias |

---

## Task 1: Write failing tests for `find_fix_plan`

**Files:**
- Create: `tests/test_fix_plan_status.sh`

- [ ] **Step 1.1: Create the test file**

```bash
#!/bin/bash
# Tests for lib/fix_plan_status.sh

TESTS_PASSED=0
TESTS_FAILED=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local name="$1"; local expected="$2"; local actual="$3"
    echo -e "\n${YELLOW}Test: $name${NC}"
    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL — expected: '$expected', got: '$actual'${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/fix_plan_status.sh"

# ── find_fix_plan: found in CWD ───────────────────────────────────────────────
test_find_in_cwd() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "$tmp_dir/.ralph"
    echo "# Fix Plan" > "$tmp_dir/.ralph/fix_plan.md"

    local result exit_code
    result=$(cd "$tmp_dir" && find_fix_plan); exit_code=$?

    run_test "find_fix_plan: found in CWD returns correct path" \
        "$tmp_dir/.ralph/fix_plan.md" "$result"
    run_test "find_fix_plan: found in CWD exits 0" \
        "0" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── find_fix_plan: found one level up ────────────────────────────────────────
test_find_one_level_up() {
    local tmp_dir child_dir
    tmp_dir=$(mktemp -d)
    child_dir="$tmp_dir/subproject"
    mkdir -p "$child_dir"
    mkdir -p "$tmp_dir/.ralph"
    echo "# Fix Plan" > "$tmp_dir/.ralph/fix_plan.md"

    local result exit_code
    result=$(cd "$child_dir" && find_fix_plan); exit_code=$?

    run_test "find_fix_plan: found one level up returns correct path" \
        "$tmp_dir/.ralph/fix_plan.md" "$result"
    run_test "find_fix_plan: found one level up exits 0" \
        "0" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── find_fix_plan: not found anywhere ────────────────────────────────────────
test_find_not_found() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local exit_code
    (cd "$tmp_dir" && find_fix_plan > /dev/null 2>&1); exit_code=$?

    run_test "find_fix_plan: not found exits 1" \
        "1" "$exit_code"
    rm -rf "$tmp_dir"
}

# ── show_fix_plan_status: unknown engine ──────────────────────────────────────
test_unknown_engine() {
    local exit_code
    (show_fix_plan_status "badengine" 2>/dev/null); exit_code=$?
    run_test "show_fix_plan_status: unknown engine exits 1" \
        "1" "$exit_code"
}

# ── show_fix_plan_status: engine CLI missing ──────────────────────────────────
test_engine_cli_missing() {
    # Override command to simulate missing CLI
    local exit_code
    (
        command() { return 1; }
        show_fix_plan_status "claude" 2>/dev/null
    ); exit_code=$?
    run_test "show_fix_plan_status: missing CLI exits 1" \
        "1" "$exit_code"
}

test_find_in_cwd
test_find_one_level_up
test_find_not_found
test_unknown_engine
test_engine_cli_missing

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]]
```

Save this to `tests/test_fix_plan_status.sh` and make it executable:
```bash
chmod +x tests/test_fix_plan_status.sh
```

- [ ] **Step 1.2: Run tests to verify they fail (lib doesn't exist yet)**

```bash
bash tests/test_fix_plan_status.sh
```

Expected: error sourcing `lib/fix_plan_status.sh` (file not found)

- [ ] **Step 1.3: Commit the test file**

```bash
git add tests/test_fix_plan_status.sh
git commit -m "test: add failing tests for fix_plan_status lib"
```

---

## Task 2: Implement `lib/fix_plan_status.sh`

**Files:**
- Create: `lib/fix_plan_status.sh`

- [ ] **Step 2.1: Create the library file**

```bash
#!/bin/bash
# lib/fix_plan_status.sh — Fix plan walk-up search and AI status display
#
# Exported functions:
#   find_fix_plan            — walk up from CWD to find .ralph/fix_plan.md
#   show_fix_plan_status     — validate engine, find plan, invoke AI
#
# IMPORTANT: All output uses echo/printf — never log() — because log() calls
# mkdir -p "$LOG_DIR" unconditionally, which would create .ralph/ in the wrong
# place when invoked from a parent directory during walk-up search.

# find_fix_plan
# Walks upward from CWD checking for .ralph/fix_plan.md at each level.
# Prints the absolute path on success (exit 0).
# Prints an error and exits 1 if not found.
find_fix_plan() {
    local dir searched=()
    dir="$(pwd)"
    while true; do
        if [[ -f "$dir/.ralph/fix_plan.md" ]]; then
            echo "$dir/.ralph/fix_plan.md"
            return 0
        fi
        searched+=("$dir/.ralph/fix_plan.md")
        local parent
        parent="$(dirname "$dir")"
        [[ "$parent" == "$dir" ]] && break   # filesystem root
        dir="$parent"
    done

    echo "Error: .ralph/fix_plan.md not found. Searched:" >&2
    for p in "${searched[@]}"; do
        echo "  $p" >&2
    done
    echo "Run 'ralph-enable' to set up Ralph in this project." >&2
    return 1
}

# show_fix_plan_status <engine>
# Validates the engine, finds fix_plan.md, builds an analysis prompt,
# and invokes the AI engine in TUI/interactive mode.
show_fix_plan_status() {
    local engine="${1:-claude}"

    # 1. Validate engine
    case "$engine" in
        claude|codex|devin) ;;
        *)
            echo "Error: Unknown engine: $engine (expected: claude, codex, devin)" >&2
            return 1
            ;;
    esac

    # 2. Verify engine CLI is installed
    local cli_cmd
    case "$engine" in
        claude) cli_cmd="claude" ;;
        codex)  cli_cmd="codex" ;;
        devin)  cli_cmd="devin" ;;
    esac
    if ! command -v "$cli_cmd" &>/dev/null; then
        echo "Error: $engine CLI ('$cli_cmd') not found. Install it first." >&2
        return 1
    fi

    # 3. Find the fix plan
    local fix_plan_path
    fix_plan_path=$(find_fix_plan) || return 1

    # 4. Read plan contents
    local fix_plan_contents
    fix_plan_contents=$(cat "$fix_plan_path")

    # 5. Build prompt
    local prompt
    prompt="You are analyzing a Ralph fix plan for a software project.

Here is the fix plan (from $fix_plan_path):

$fix_plan_contents

Please provide:

1. **Task Summary**
   - Total tasks, completed ([x]), pending ([ ])
   - Overall completion percentage

2. **Section Breakdown**
   For each section in the plan:
   - Section name
   - Tasks: X done / Y total (Z%)

3. **Insights**
   - What's next (highest-priority pending tasks)
   - Any risks or blockers you notice
   - Patterns (e.g. a section that hasn't been started, or one that's nearly done)
   - Any observations about the shape or quality of the plan itself"

    # 6. Invoke engine (TUI/interactive mode, same as run_ai_planning in ralph_plan.sh)
    # Claude and codex receive the prompt as a string argument directly.
    # Devin requires a prompt file — create via mktemp (no .ralph/ dependency needed).
    local cli_exit_code=0
    local prompt_file=""
    case "$engine" in
        claude)
            if "$cli_cmd" --permission-mode bypassPermissions --allowedTools Read "$prompt"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        codex)
            if "$cli_cmd" --permission-mode dangerous "$prompt"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        devin)
            prompt_file=$(mktemp)
            echo "$prompt" > "$prompt_file"
            if "$cli_cmd" --permission-mode dangerous --prompt-file "$prompt_file"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
    esac

    # 7. Unconditional temp file cleanup (only devin creates one)
    rm -f "$prompt_file"

    # 8. Return engine's exit code
    return $cli_exit_code
}
```

Save to `lib/fix_plan_status.sh`.

- [ ] **Step 2.2: Run tests — expect them to pass**

```bash
bash tests/test_fix_plan_status.sh
```

Expected output:
```
Test: find_fix_plan: found in CWD returns correct path
PASS

Test: find_fix_plan: found in CWD exits 0
PASS

Test: find_fix_plan: found one level up returns correct path
PASS

Test: find_fix_plan: found one level up exits 0
PASS

Test: find_fix_plan: not found exits 1
PASS

Test: show_fix_plan_status: unknown engine exits 1
PASS

Test: show_fix_plan_status: missing CLI exits 1
PASS

Results: 7 passed, 0 failed
```

If any test fails, fix `lib/fix_plan_status.sh` before continuing.

- [ ] **Step 2.3: Commit**

```bash
git add lib/fix_plan_status.sh
git commit -m "feat: add lib/fix_plan_status.sh with find_fix_plan and show_fix_plan_status"
```

---

## Task 3: Add `STATUS_MODE` variable and `--status` to `parse_args` in `ralph_plan.sh`

**Files:**
- Modify: `ralph_plan.sh`

The `STATUS_MODE` variable goes in the "Planning mode settings" block (around line 29).
The `--status` case goes in `parse_args` (around line 633).

- [ ] **Step 3.1: Add `STATUS_MODE=false` to the variables block**

In `ralph_plan.sh`, find the block at line ~29:
```bash
# Planning mode settings
PRD_DIR=""
PM_OS_DIR=""
DOE_OS_DIR=""
```

Add `STATUS_MODE=false` after `DOE_OS_DIR=""`:
```bash
# Planning mode settings
PRD_DIR=""
PM_OS_DIR=""
DOE_OS_DIR=""
STATUS_MODE=false
```

- [ ] **Step 3.2: Add `--status` case to `parse_args`**

In `parse_args`, find the `--yolo)` case (around line 652). Add `--status` before it:
```bash
            --status)
                STATUS_MODE=true
                shift
                ;;
            --yolo)
```

- [ ] **Step 3.3: Verify the file looks right around parse_args**

```bash
grep -n "STATUS_MODE\|--status\|--yolo" ralph_plan.sh
```

Expected: lines showing `STATUS_MODE=false` in variables, `--status)` in parse_args, and `YOLO_MODE` nearby.

- [ ] **Step 3.4: Commit**

```bash
git add ralph_plan.sh
git commit -m "feat(ralph_plan): add STATUS_MODE variable and --status flag to parse_args"
```

---

## Task 4: Add early-exit status block to `main()` in `ralph_plan.sh`

**Files:**
- Modify: `ralph_plan.sh`

- [ ] **Step 4.1: Add the early-exit block at the top of `main()`**

In `ralph_plan.sh`, find `main()` (around line 673). The body starts with `parse_args "$@"` then the banner echo lines. Add the status block immediately after `parse_args "$@"`:

```bash
main() {
    parse_args "$@"

    # Status mode: AI-powered fix plan analysis — exits before any planning
    # Note: ralph_plan.sh has `set -e`. Using `|| exit $?` disarms set -e for this
    # line so we can capture the exit code explicitly rather than relying on set -e
    # to exit on non-zero (which would work but is fragile if set -e is ever changed).
    if [[ "$STATUS_MODE" == true ]]; then
        source "$SCRIPT_DIR/lib/fix_plan_status.sh"
        show_fix_plan_status "$ENGINE" || exit $?
        exit 0
    fi

    echo ""
    echo -e "${PURPLE}Ralph Planning Mode${NC}"
    ...
```

- [ ] **Step 4.2: Verify the structure looks right**

```bash
grep -n "STATUS_MODE\|show_fix_plan_status\|parse_args\|Ralph Planning Mode" ralph_plan.sh
```

Expected: `STATUS_MODE` check appears between `parse_args` call and the banner echoes.

- [ ] **Step 4.3: Commit**

```bash
git add ralph_plan.sh
git commit -m "feat(ralph_plan): add early-exit status block to main()"
```

---

## Task 5: Update `show_help` in `ralph_plan.sh`

**Files:**
- Modify: `ralph_plan.sh`

- [ ] **Step 5.1: Add `--status` to the Options section in `show_help`**

Find the options block in `show_help` (around line 86). Add `--status` after `--sup`:

```
    --yolo             Yolo mode: --dangerously-skip-permissions (Claude only)
    --superpowers      Load obra/superpowers plugin (Claude only, auto-cloned)
    --sup              Alias for --superpowers
    --status           Show AI-powered fix plan status and insights (no planning runs)
    -h, --help         Show this help
```

- [ ] **Step 5.2: Add a usage example**

In the Examples block (around line 97), add after the last example:
```
    ralph-plan --status                         # AI fix plan status (Claude, default)
    ralph-plan --engine codex --status          # AI fix plan status via Codex
```

- [ ] **Step 5.3: Verify help output**

```bash
bash ralph_plan.sh --help | grep -A2 "status"
```

Expected: `--status` line appears in Options and an example line appears.

- [ ] **Step 5.4: Commit**

```bash
git add ralph_plan.sh
git commit -m "docs(ralph_plan): add --status to show_help options and examples"
```

---

## Task 6: Add aliases to all three ALIASES.sh files

**Files:**
- Modify: `ALIASES.sh`
- Modify: `codex/ALIASES.sh`
- Modify: `devin/ALIASES.sh`

- [ ] **Step 6.1: Add alias to `ALIASES.sh`**

Find the planning mode block (around line 69):
```bash
# Planning mode (AI-powered, always uses claude engine)
alias rpc.plan='ralph-plan'
alias rpc.plan.sup='ralph-plan --yolo --superpowers'
```

Add after `rpc.plan.sup`:
```bash
# Fix plan status (note: rpc.status is agent session status; rpc.plan.s is fix plan status)
alias rpc.plan.s='ralph-plan --status'
```

- [ ] **Step 6.2: Add alias to `codex/ALIASES.sh`**

Find the planning mode block (last line, around line 73):
```bash
# Planning mode (AI-powered, uses codex engine)
alias rpx.plan='ralph-plan --engine codex'
```

Add after it:
```bash
# Fix plan status (note: rpx.status is agent session status; rpx.plan.s is fix plan status)
alias rpx.plan.s='ralph-plan --engine codex --status'
```

- [ ] **Step 6.3: Add alias to `devin/ALIASES.sh`**

Find the planning mode block (last line, around line 74):
```bash
# Planning mode (AI-powered, uses devin engine)
alias rpd.plan='ralph-plan --engine devin'
```

Add after it:
```bash
# Fix plan status (note: rpd.status is agent session status; rpd.plan.s is fix plan status)
alias rpd.plan.s='ralph-plan --engine devin --status'
```

- [ ] **Step 6.4: Verify all three files**

```bash
grep "plan.s" ALIASES.sh codex/ALIASES.sh devin/ALIASES.sh
```

Expected:
```
ALIASES.sh:alias rpc.plan.s='ralph-plan --status'
codex/ALIASES.sh:alias rpx.plan.s='ralph-plan --engine codex --status'
devin/ALIASES.sh:alias rpd.plan.s='ralph-plan --engine devin --status'
```

- [ ] **Step 6.5: Commit**

```bash
git add ALIASES.sh codex/ALIASES.sh devin/ALIASES.sh
git commit -m "feat: add rpc.plan.s / rpx.plan.s / rpd.plan.s aliases for fix plan status"
```

---

## Task 7: Run full test suite and smoke test

- [ ] **Step 7.1: Run the fix_plan_status tests**

```bash
bash tests/test_fix_plan_status.sh
```

Expected: `Results: 7 passed, 0 failed`

- [ ] **Step 7.2: Run existing tests to check for regressions**

```bash
bash tests/test_pr_manager.sh
bash tests/test_error_detection.sh 2>/dev/null || true
bash tests/test_stuck_loop_detection.sh 2>/dev/null || true
```

Expected: no new failures.

- [ ] **Step 7.3: Smoke test `--help`**

```bash
bash ralph_plan.sh --help
```

Expected: `--status` appears in the Options section and in Examples.

- [ ] **Step 7.4: Smoke test `--status` with no `.ralph/` directory (error path)**

From a directory with no `.ralph/` anywhere above it (e.g. `/tmp`):
```bash
cd /tmp && bash /path/to/ai-ralph/ralph_plan.sh --status
```

Expected: error message listing searched paths, suggestion to run `ralph-enable`, exit 1.

- [ ] **Step 7.5: Smoke test `--status` with a real fix plan (happy path)**

From the `examples/rest-api` directory:
```bash
cd examples/rest-api && bash ../../ralph_plan.sh --status
```

Expected: Claude launches in TUI mode, analyzes the Bookstore API fix plan, outputs summary + insights.

- [ ] **Step 7.6: Final commit if any fixups were needed**

```bash
git add -p   # stage only actual fixes
git commit -m "fix: address smoke test issues in fix_plan_status"
```

---

## Summary of Commits

1. `test: add failing tests for fix_plan_status lib`
2. `feat: add lib/fix_plan_status.sh with find_fix_plan and show_fix_plan_status`
3. `feat(ralph_plan): add STATUS_MODE variable and --status flag to parse_args`
4. `feat(ralph_plan): add early-exit status block to main()`
5. `docs(ralph_plan): add --status to show_help options and examples`
6. `feat: add rpc.plan.s / rpx.plan.s / rpd.plan.s aliases for fix plan status`
7. (optional) `fix: address smoke test issues in fix_plan_status`
