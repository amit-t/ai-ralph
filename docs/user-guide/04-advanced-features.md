# Advanced Features

Once you're comfortable with the basics in [Quick Start](01-quick-start.md), this page walks through the advanced modes that make Ralph useful for larger projects, multi-repo workspaces, and unattended runs.

## Parallel agents

When your `fix_plan.md` has independent tasks, you can run Ralph with multiple agents in parallel. Each agent picks a different unclaimed `[ ]` task, works in its own git worktree, and opens its own PR.

```bash
# Claude engine
rpc.p 3          # 3 parallel agents, auto-exit, no streaming (quietest)
rpc.live.p 3     # 3 parallel agents, streams Claude output in each tab
rpc.int.p 3      # 3 parallel agents, full tmux 3-pane dashboard in each tab

# Background variants (detached; logs in .ralph/logs/parallel/)
rpc.p.b 3
rpc.live.p.b 3
rpc.int.p.b 3

# Devin and Codex follow the same pattern
rpd.p 3          # non-interactive parallel
rpd.int.p 3      # interactive TUI parallel
rpx.int.p 3      # Codex (interactive TUI)
```

### How Ralph keeps parallel runs safe

- **Atomic task locking.** `pick_next_task` uses a file lock so two agents never pick the same `[ ]` line.
- **Task assignment directive.** Ralph injects the picked task ID, line number, and description into the prompt, so the AI works on the exact task Ralph locked.
- **3-way merge on cleanup.** When a worktree finishes, Ralph merges its `fix_plan.md` back into the main copy with `git merge-file` (worktree-final × baseline × main-current), guarded by a mutex. Sibling agents' `[~]` / `[x]` marks are preserved; if `git merge-file` can't resolve, a line-level fallback picks the most-advanced mark per task (`[x] > [~] > [ ]`).
- **Fresh Claude session per iteration.** In worktree mode, Claude sessions are scoped to the worktree cwd, so every iteration is a fresh session. `--resume` errors like "No conversation found" no longer happen in parallel runs.

### When to pick which parallel variant

| Variant | Use when |
|---|---|
| `rpc.p N` | Unattended / CI -- you don't need to watch |
| `rpc.live.p N` | You want to see Claude's stream-json output, one pane per agent |
| `rpc.int.p N` | You want the full tmux dashboard (loop + log + monitor) per agent |
| `.p.b` variants | Detach and go -- logs to `.ralph/logs/parallel/` |

`rpc.int.p` wraps each agent in tmux + a stream-json tee/FIFO. Prefer `rpc.p` for unattended runs -- it has no tmux overhead.

## Workspace mode (multi-repo)

If your work spans several git repos that live side-by-side under one parent directory, enable Ralph at the workspace level. One `fix_plan.md` holds tasks for every child repo, and Ralph runs each task in the correct repo.

```bash
# Layout:
# ~/work/my-workspace/            <- parent directory (NOT a git repo)
# ├── api-service/.git/
# ├── web-frontend/.git/
# └── shared-lib/.git/

cd ~/work/my-workspace
ralph-enable --workspace          # Claude (interactive)
ralph-enable-ci --workspace       # Claude (CI / non-interactive)
ralph-devin-enable --workspace    # Devin
ralph-codex-enable --workspace    # Codex
```

This creates a workspace-level `.ralph/` with:
- `fix_plan.md` containing a `## repo-name` section per child repo (plus an optional `## cross-repo` section for tasks that span multiple repos)
- `PROMPT.md` with workspace-specific orchestration instructions
- `.ralphrc` with `WORKSPACE_MODE=true`

### Running workspace loops

```bash
ralph --workspace                       # sequential across repos
ralph --workspace --parallel 3          # up to 3 repos at once (one task per repo)
ralph --workspace --monitor             # live tmux dashboard

# Engine aliases
rpc.ws           # ralph --workspace
rpc.ws.int       # ralph --workspace --live --monitor
rpc.ws.p 3       # ralph --workspace --parallel 3
rpd.ws.p 3       # same for Devin
rpx.ws.p 3       # same for Codex
```

Under `--parallel N`, Ralph picks up to N tasks (one per repo), skips repos with in-progress tasks and the `cross-repo` section, atomically marks them `[~]`, then spawns background workers. Per-worker logs land in `.ralph/logs/parallel/ws_worker_<repo>_<pid>.log`.

### Workspace planning

You can also plan tasks across multiple repos at once:

```bash
ralph-plan --workspace                        # sequential multi-repo plan (Claude)
ralph-plan --workspace --engine devin         # via Devin
ralph-plan --workspace --repos api,web        # only plan two repos
ralph-plan --workspace --dry-run              # preview; don't write fix_plan.md
```

The planner:
- Reads planning context from both `ai/` (workbench convention) and `.ralph/specs/` (ralph-native).
- Writes structured output per repo to `.ralph/.workspace_plan/<repo>.out.md`.
- Merges new tasks into each `## repo-name` section, deduped against preserved `[~]` / `[x]` lines.
- Consolidates cross-repo tasks into a single `## cross-repo` section.
- Prints a summary: repos planned, new vs preserved tasks, cross-repo count, ambiguities, engine, elapsed time.

## Planning modes (`ralph-plan`)

`ralph-plan` uses AI to build or update `fix_plan.md`. It always runs in a single-shot TUI, not a loop.

| Mode | What it does |
|---|---|
| `ralph-plan` | Default: scans PRDs, specs, bead IDs, and the codebase; writes `fix_plan.md`. Auto-detects PM-OS / DoE-OS sibling dirs. |
| `ralph-plan --file <path>` | File-based: reads one MD / JSON / YAML / TXT file and extracts tasks from it. |
| `ralph-plan --adhoc "Login broken on iOS"` | Ad-hoc: a one-liner description becomes a structured `fix_plan.md` entry (with a new `AHxx` task ID printed to stdout, pipeable into `rpc.task $ID`). |
| `ralph-plan --compress` | Compresses `fix_plan.md` to reduce token usage: collapses completed items, shortens verbose descriptions, preserves task IDs and progress. Archives a backup in `.ralph/logs/` first. |
| `ralph-plan --status` | AI-powered status insights on the current `fix_plan.md` -- no writes. |
| `ralph-plan --workspace` | Multi-repo planning (see above). |

### Choosing a model and thinking depth

```bash
# Model override (Claude + Devin)
ralph-plan --model opus                        # Claude Opus
ralph-plan --model sonnet                      # Claude Sonnet
ralph-plan --engine devin --model claude-opus-4.6

# Thinking depth
ralph-plan --thinking hard                     # "Think hard..." preamble + --effort high (Claude)
ralph-plan --thinking ultra                    # ultrathink preamble + --effort max (Claude)

# Combined
ralph-plan --model opus --thinking ultra --yolo --superpowers   # deepest Claude plan
```

Aliases: `rpc.plan.opus`, `rpc.plan.ultra`, `rpc.plan.opus.ultra`, `rpc.plan.max`, plus `rpd.plan.*` equivalents for Devin.

## Quality-gate fix mode (`--qg`)

After a loop run fails its quality gates, Ralph will still open a PR (tagged `quality-gates-failed`). If you'd rather have an AI pass attempt a fix without running a full new loop:

```bash
ralph --qg             # Claude
rpc.qg                 # alias
ralph-devin --qg       # Devin
rpd.qg                 # alias
ralph-codex --qg       # Codex
rpx.qg                 # alias
```

Ralph runs the gates, feeds failures to the AI (with Claude's `Task` tool temporarily enabled so it can spawn subagents), auto-commits any fix, and retries up to `MAX_QG_RETRIES` (default: 3) attempts.

## Timeouts and live gate output

Long builds and flaky installs used to hang the loop silently. Two knobs now bound the worst-case wait, and gate output streams live to the loop log (no more silent "Running quality gates..."):

```bash
# In .ralphrc (or as env vars)
WORKTREE_INSTALL_TIMEOUT=600   # seconds (10 min default) -- pre-gate npm/pnpm/yarn/bun install
WORKTREE_GATE_TIMEOUT=600      # seconds (10 min default) -- each detected/configured gate
```

Both paths redirect stdin from `/dev/null` so TTY prompts (registry auth, `npm login`, watch-mode tests) can't block. A timeout exit (124/137) is recorded in the QG fix prompt and PR description so you can see the real reason.

The start log prints the bounds each run:

```
Running quality gates (install timeout 600s, per-gate timeout 600s)...
```

## Execution Failed summary

When the AI invocation fails (API error, timeout, non-zero exit), Ralph prints a red "Execution Failed" box with:

- Task name and exit code
- **Preserved** worktree branch (not deleted) so you can inspect and re-run it
- Session ID and the engine-specific resume command
- `[~]` marker reverted to `[ ]` in `fix_plan.md` so the task is retryable on the next loop

This is wired into all three engine loops; no configuration needed.

## Further reading

- [Aliases reference in the main README](../../README.md#aliases-reference) -- every `rpc.*`, `rpd.*`, `rpx.*` alias
- [Configuration](../../README.md#configuration) -- `.ralphrc`, `.ralphrc.devin`, `.ralphrc.codex` full reference
- [How It Works](../../README.md#how-it-works) -- worktree lifecycle, task selection, change detection
