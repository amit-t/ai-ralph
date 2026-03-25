# Fix Plan Status — Design Spec

**Date:** 2026-03-25
**Feature:** `ralph-plan --status` — AI-powered fix plan analysis

---

## Summary

Add a `--status` flag to `ralph-plan` that uses an AI engine to analyze `.ralph/fix_plan.md` and return a rich status report: task counts by section, completion percentages, and actionable insights about the plan.

---

## Architecture

### New file: `lib/fix_plan_status.sh`

A sourced bash helper that exports two functions:

**`find_fix_plan`**
- Walks upward from CWD, checking `.ralph/fix_plan.md` at each level
- Returns the absolute path of the first match
- Fails with a descriptive error (showing the search path) if not found
- Suggests running `ralph-enable` on failure

**`show_fix_plan_status <engine>`**
- Reads the fix_plan.md found by `find_fix_plan`
- Builds an analysis prompt (see Prompt Design below)
- Invokes the AI engine in non-interactive / print mode
- Streams output to terminal

### Modified: `ralph_plan.sh`

- Add `--status` to `parse_args`; sets `STATUS_MODE=true`
- At the top of `main`, check `STATUS_MODE`: source `lib/fix_plan_status.sh`, call `show_fix_plan_status "$ENGINE"`, then `exit 0`
- `--status` is compatible with `--engine <name>` (defaults to `claude`)
- No AI planning runs when `--status` is set

### Modified: `ALIASES.sh`

```bash
alias rpc.plan.s='ralph-plan --status'
```

### Modified: `codex/ALIASES.sh`

```bash
alias rpx.plan.s='ralph-plan --engine codex --status'
```

### Modified: `devin/ALIASES.sh`

```bash
alias rpd.plan.s='ralph-plan --engine devin --status'
```

### Not modified: `install.sh`

`install.sh` already copies all of `lib/*` to `$RALPH_HOME/lib/` — no changes needed.

---

## Data Flow

```
ralph-plan --status [--engine <name>]
    │
    ├── parse_args: STATUS_MODE=true, ENGINE=<name> (default: claude)
    │
    ├── find_fix_plan()
    │     check ./. ralph/fix_plan.md
    │     check ../.ralph/fix_plan.md
    │     ... walk up to filesystem root
    │     error + exit if not found
    │
    ├── read fix_plan.md contents into variable
    │
    ├── build AI prompt (see below)
    │
    └── invoke engine non-interactively
          claude -p "<prompt>"
          codex   [equivalent non-interactive flag]
          devin   [equivalent non-interactive flag]
          stream output to terminal
```

---

## Prompt Design

```
You are analyzing a Ralph fix plan for a software project.

Here is the fix plan:

<fix_plan contents>

Please provide:

1. **Task Summary**
   - Total tasks, completed, pending
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

## Error Handling

| Condition | Behavior |
|---|---|
| `fix_plan.md` not found anywhere in walk | Print error listing directories searched; suggest `ralph-enable` |
| AI CLI not installed | Same error as existing `run_ai_planning` in `ralph_plan.sh` |
| Empty fix plan | AI runs; will note there are no tasks |
| Unknown engine | Same error as existing `run_ai_planning` |

---

## Engine Aliases

| Alias | Expands to | Engine |
|---|---|---|
| `rpc.plan.s` | `ralph-plan --status` | Claude (default) |
| `rpx.plan.s` | `ralph-plan --engine codex --status` | Codex |
| `rpd.plan.s` | `ralph-plan --engine devin --status` | Devin |

---

## Out of Scope

- Writing or modifying `fix_plan.md` based on the AI response
- Caching AI responses
- Machine-readable output format (JSON, etc.)
