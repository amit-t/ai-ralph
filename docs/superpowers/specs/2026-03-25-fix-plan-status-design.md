# Fix Plan Status — Design Spec

**Date:** 2026-03-25
**Feature:** `ralph-plan --status` — AI-powered fix plan analysis

---

## Summary

Add a `--status` flag to `ralph-plan` that uses an AI engine to analyze `.ralph/fix_plan.md` and return a rich status report: task counts by section, completion percentages, and actionable insights about the plan.

---

## Architecture

### New file: `lib/fix_plan_status.sh`

A sourced bash helper that exports two functions. All output uses `echo`/`printf` directly — **never the shared `log()` function** — because `log()` calls `mkdir -p "$LOG_DIR"` (`.ralph/logs`) unconditionally, which would create a spurious `.ralph/` directory when invoked from a parent directory during the walk-up search.

**`find_fix_plan`**
- Walks upward from CWD, checking `.ralph/fix_plan.md` at each level
- Terminates when `.ralph/fix_plan.md` is found, or when the directory stops changing (filesystem root)
- Returns the absolute path of the first match via stdout
- On failure: prints an error listing every directory searched, suggests running `ralph-enable`, and returns exit code 1

Termination pseudocode:
```bash
dir="$(pwd)"
while true; do
    if [[ -f "$dir/.ralph/fix_plan.md" ]]; then
        echo "$dir/.ralph/fix_plan.md"
        return 0
    fi
    parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break   # reached filesystem root
    dir="$parent"
done
# not found
```

**`show_fix_plan_status <engine>`**

Argument:
- `engine` — one of `claude`, `codex`, `devin`

Steps:
1. Validate engine (same error message as `run_ai_planning` for unknown engine); exit 1 on unknown engine before any other work
2. Verify the engine CLI is installed; exit 1 with same error pattern as `run_ai_planning` if missing
3. Call `find_fix_plan`; exit 1 on failure
4. Read fix_plan.md contents into a variable
5. Build the AI analysis prompt (see Prompt Design below)
6. Write prompt to a temp file via `mktemp` (e.g. `prompt_file=$(mktemp)`). Using `mktemp` avoids any dependency on `.ralph/` existing in CWD, since `--status` runs before the `mkdir -p "$RALPH_DIR"` calls in `main()`.
7. Invoke the AI engine in TUI/interactive mode (see Engine Invocation below) — same as `run_ai_planning`, user watches the AI work
8. `rm -f "$prompt_file"` unconditionally after invocation (whether or not the engine succeeded)
9. Exit with the engine's exit code

### Modified: `ralph_plan.sh`

Four locations change:

1. **`parse_args`** — add `--status` case; sets `STATUS_MODE=true`
2. **`main`** — at the top, before any planning logic (and before any `mkdir -p "$RALPH_DIR"`):
   ```bash
   if [[ "$STATUS_MODE" == true ]]; then
       source "$SCRIPT_DIR/lib/fix_plan_status.sh"
       show_fix_plan_status "$ENGINE"
       exit $?
   fi
   ```
   `$SCRIPT_DIR` is set at the top of `ralph_plan.sh` (line 19). When installed, the stub at `~/.local/bin/ralph-plan` execs `$RALPH_HOME/ralph_plan.sh`, so `$SCRIPT_DIR` resolves to `~/.ralph/` and `$SCRIPT_DIR/lib/fix_plan_status.sh` = `~/.ralph/lib/fix_plan_status.sh` — installed correctly because `install.sh` already copies all `lib/*` to `$RALPH_HOME/lib/`.
3. **`show_help`** — add `--status` to the options section:
   ```
   --status           Show AI-powered fix plan status and insights (no planning runs)
   ```
4. **Incompatible flags** — `--status` causes early exit before `--yolo` and `--superpowers` are used; they are silently ignored.

### Modified: `ALIASES.sh`

```bash
# Fix plan status (note: rpc.status is the agent session status; rpc.plan.s is the fix plan status)
alias rpc.plan.s='ralph-plan --status'
```

### Modified: `codex/ALIASES.sh`

```bash
# Fix plan status (note: rpx.status is the agent session status; rpx.plan.s is the fix plan status)
alias rpx.plan.s='ralph-plan --engine codex --status'
```

### Modified: `devin/ALIASES.sh`

```bash
# Fix plan status (note: rpd.status is the agent session status; rpd.plan.s is the fix plan status)
alias rpd.plan.s='ralph-plan --engine devin --status'
```

**Note:** `ralph.plan.s` (engine-agnostic shared alias) is intentionally out of scope — there is no existing `ralph.plan.*` family of aliases beyond `ralph.plan` itself.

### Not modified: `install.sh`

`install.sh` already copies all of `lib/*` to `$RALPH_HOME/lib/` — no changes needed.

---

## Data Flow

```
ralph-plan --status [--engine <name>]
    │
    ├── parse_args: STATUS_MODE=true, ENGINE=<name> (default: claude)
    │   --yolo / --superpowers silently ignored (early exit before they apply)
    │
    ├── source "$SCRIPT_DIR/lib/fix_plan_status.sh"
    │
    ├── show_fix_plan_status "$ENGINE"
    │     │
    │     ├── validate engine; exit 1 if unknown
    │     ├── verify engine CLI installed; exit 1 if missing
    │     ├── find_fix_plan() — walk up; exit 1 if not found
    │     ├── read fix_plan.md contents
    │     ├── build prompt
    │     ├── prompt_file=$(mktemp)   — no .ralph/ dependency
    │     ├── write prompt to $prompt_file
    │     ├── invoke engine TUI/interactive mode (see below)
    │     └── rm -f "$prompt_file" (unconditional)
    │
    └── exit with engine's exit code
```

---

## Prompt Design

```
You are analyzing a Ralph fix plan for a software project.

Here is the fix plan:

<fix_plan contents>

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
   - Any observations about the shape or quality of the plan itself
```

---

## Engine Invocation

Invocation mirrors `run_ai_planning()` in `ralph_plan.sh` exactly — TUI/interactive mode, user watches the AI work. `--status` always uses `--permission-mode bypassPermissions` for claude (yolo/superpowers flags are silently ignored since `--status` exits early).

| Engine | Invocation |
|--------|-----------|
| claude | `claude --permission-mode bypassPermissions --allowedTools Read "$prompt_content"` — intentionally `Read` only (unlike `run_ai_planning` which passes all four tools); the AI is analyzing, not writing files |
| codex  | `codex --permission-mode dangerous "$prompt_content"` |
| devin  | `devin --permission-mode dangerous --prompt-file "$prompt_file"` |

For claude and codex, the prompt content is passed as a string argument. For devin, it is passed via the `$prompt_file` temp file (created by `mktemp`).

---

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Unknown engine | Same error + exit 1 as `run_ai_planning`; checked first, before any other work |
| AI CLI not installed | Same error message pattern as `run_ai_planning`; checked second |
| `fix_plan.md` not found anywhere in walk | Print error listing each directory searched; suggest `ralph-enable`; exit 1 |
| Empty fix plan | AI runs; will note there are no tasks |

---

## Engine Aliases

| Alias | Expands to | Engine | Note |
|-------|-----------|--------|------|
| `rpc.plan.s` | `ralph-plan --status` | Claude (default) | Different from `rpc.status` (agent session status) |
| `rpx.plan.s` | `ralph-plan --engine codex --status` | Codex | Different from `rpx.status` |
| `rpd.plan.s` | `ralph-plan --engine devin --status` | Devin | Different from `rpd.status` |

---

## Out of Scope

- Writing or modifying `fix_plan.md` based on the AI response
- Caching AI responses
- Machine-readable output format (JSON, etc.)
- `ralph.plan.s` engine-agnostic shared alias
