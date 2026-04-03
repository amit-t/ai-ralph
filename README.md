# AI Ralph

> **Multi-engine autonomous AI development loop** -- Devin, Claude Code, and Codex under one roof.

Ralph is an autonomous development loop system inspired by [Geoffrey Huntley's Ralph technique](https://ghuntley.com/ralph/). It wraps AI coding agents in a persistent bash loop with intelligent exit detection, circuit breakers, rate limiting, git worktree isolation, and automatic PR creation -- so you can kick off a task and walk away.

This project is a fork of [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) extended with first-class **Devin CLI** and **Codex CLI** support, parallel agent spawning, interactive TUI mode, automatic PR workflows, and 150+ shell aliases for rapid operation.

## Project Status

| | |
|---|---|
| **Repo** | [amit-t/ai-ralph](https://github.com/amit-t/ai-ralph) |
| **Upstream** | [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) |
| **Engines** | Devin CLI, Claude Code, Codex CLI |
| **Architecture** | Single-run per loop iteration, git worktree isolation, auto-PR |
| **Status** | Active development |

### What this fork adds over upstream

- **Devin CLI engine** (`ralph-devin`, `rpd.*` aliases) with cloud session polling, ACU limits, and parallel agent spawning
- **Codex CLI engine** (`ralph-codex`, `rpx.*` aliases) with GPT-4/Claude model selection
- **Single-run architecture** -- each loop iteration is one agent invocation (no inner while-loop)
- **Git worktree isolation** -- each loop runs on a dedicated branch; changes merge back only after quality gates pass
- **Automatic PR creation** via `lib/pr_manager.sh` with quality-gate labels
- **Parallel agent spawning** via `lib/parallel_spawn.sh` (iTerm2 tabs, IDE terminals, or background processes)
- **Interactive TUI mode** for Devin and Codex (`--no-devin-auto-exit` / `--no-codex-auto-exit`)
- **Task-specific execution** via `--task NUM|ID` flag -- run a specific task from `fix_plan.md` by ordinal number or bold task ID (e.g. `--task R05`)
- **Non-interactive directive injection** -- prevents "Shall I proceed?" stalls in headless loop mode
- **Automatic dependency installation** in worktrees -- detects package manager and installs before quality gates
- **Change detection with execution summary** -- shows files changed, lines added/removed after each run; no-change early exit reverts the task marker so it can be retried
- **150+ shell aliases** across three engines (`rpc.*`, `rpd.*`, `rpx.*`)
- **Planning mode** (`ralph-plan`) with PM-OS / DoE-OS auto-detection
- **File-based planning** (`ralph-plan --file`) for generating fix_plan from any MD, JSON, or text file

---

## Table of Contents

- [Installation](#installation)
- [Enabling Ralph in a Project](#enabling-ralph-in-a-project)
- [Quick Start](#quick-start)
- [Aliases Reference](#aliases-reference)
  - [Devin Aliases (rpd)](#devin-aliases-rpd)
  - [Claude Code Aliases (rpc)](#claude-code-aliases-rpc)
  - [Codex Aliases (rpx)](#codex-aliases-rpx)
  - [Shared Aliases](#shared-aliases)
- [Commands Reference](#commands-reference)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
  - [Task Selection](#task-selection)
  - [Non-Interactive Directive](#non-interactive-directive)
  - [Change Detection and Execution Summary](#change-detection-and-execution-summary)
  - [Git Worktree Isolation](#git-worktree-isolation)
- [System Requirements](#system-requirements)
- [Uninstalling](#uninstalling)
- [Project Status](#project-status-1)

---

## Installation

Ralph has a **base install** (Claude Code engine) plus **optional engine installs** for Devin and Codex.

### Step 1 -- Clone this repo

```bash
git clone git@github.com:amit-t/ai-ralph.git
cd ai-ralph
```

### Step 2 -- Install base Ralph (Claude Code engine)

```bash
./install.sh
```

This installs global commands to `~/.local/bin/`:

| Command | Description |
|---|---|
| `ralph` | Main autonomous loop (Claude Code) |
| `ralph-monitor` | Live tmux monitoring dashboard |
| `ralph-setup` | Create a new Ralph project from scratch |
| `ralph-enable` | Interactive wizard to enable Ralph in an existing project |
| `ralph-enable-ci` | Non-interactive enable for CI/automation |
| `ralph-import` | Convert a PRD/spec document into a Ralph project |
| `ralph-migrate` | Migrate old flat-structure projects to `.ralph/` subfolder |
| `ralph-plan` | AI-powered planning mode (builds `fix_plan.md` from PRDs) |
| `ralph-check-beads` | Diagnostic tool for beads integration |

> Make sure `~/.local/bin` is in your `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile if needed.

### Step 3 -- Install Devin engine (recommended)

```bash
./devin/install_devin.sh
```

This adds:

| Command | Description |
|---|---|
| `ralph-devin` | Main autonomous loop (Devin CLI) |
| `ralph-devin-monitor` | Devin monitoring dashboard |
| `ralph-devin-setup` | Create a new project configured for Devin |
| `ralph-devin-enable` | Enable Ralph+Devin in an existing project |
| `ralph-devin-enable-ci` | Non-interactive enable for Devin |
| `ralph-devin-import` | Convert PRD for Devin |

### Step 4 -- Install Codex engine (optional)

```bash
./codex/install_codex.sh
```

This adds:

| Command | Description |
|---|---|
| `ralph-codex` | Main autonomous loop (Codex CLI) |
| `ralph-codex-monitor` | Codex monitoring dashboard |
| `ralph-codex-setup` | Create a new project configured for Codex |
| `ralph-codex-enable` | Enable Ralph+Codex in an existing project |
| `ralph-codex-enable-ci` | Non-interactive enable for Codex |
| `ralph-codex-import` | Convert PRD for Codex |

### Install all engines at once

If you have the aliases loaded, you can reinstall everything with:

```bash
rp.install   # runs install.sh + devin/install_devin.sh + codex/install_codex.sh
```

### Load aliases

Add one or more of these to your `~/.bashrc` or `~/.zshrc`:

```bash
source ~/Projects/Tools-Utilities/ai-ralph/ALIASES.sh          # rpc.* aliases (Claude)
source ~/Projects/Tools-Utilities/ai-ralph/devin/ALIASES.sh    # rpd.* aliases (Devin)
source ~/Projects/Tools-Utilities/ai-ralph/codex/ALIASES.sh    # rpx.* aliases (Codex)
```

Then `source ~/.zshrc` (or restart your terminal).

---

## Enabling Ralph in a Project

Before running Ralph in any project, you need to enable it. This creates a `.ralph/` directory with configuration files.

### Option A -- Interactive wizard (recommended)

```bash
cd my-project

# For Devin:
ralph-devin-enable

# For Claude Code:
ralph-enable

# For Codex:
ralph-codex-enable
```

The wizard auto-detects your project type (TypeScript, Python, Rust, Go) and framework, lets you import tasks from beads, GitHub Issues, or PRD documents, and generates all configuration files.

### Option B -- Non-interactive (CI / automation)

```bash
ralph-enable-ci                              # Claude, sensible defaults
ralph-enable-ci --from github               # Import tasks from GitHub Issues
ralph-enable-ci --from prd ./docs/spec.md   # Import from PRD

ralph-devin-enable-ci                       # Devin
ralph-codex-enable-ci                       # Codex
```

### Option C -- Import an existing PRD

```bash
ralph-import requirements.md my-project     # Claude
ralph-devin-import requirements.md my-project   # Devin
ralph-codex-import requirements.md my-project   # Codex
```

### Option D -- New project from scratch

```bash
ralph-setup my-project           # Claude
ralph-devin-setup my-project     # Devin
ralph-codex-setup my-project     # Codex
```

### What gets created

```
my-project/
├── .ralph/                 # Ralph configuration and state
│   ├── PROMPT.md           # Main development instructions
│   ├── fix_plan.md         # Prioritized task list
│   ├── AGENT.md            # Build/test/run instructions (auto-maintained)
│   ├── specs/              # Detailed specifications
│   ├── logs/               # Execution logs
│   └── docs/generated/     # Auto-generated docs
├── .ralphrc                # Project config (tool permissions, loop settings)
└── src/                    # Your source code
```

| File | You should... |
|---|---|
| `.ralph/PROMPT.md` | **Review and customize** -- your project goals and principles |
| `.ralph/fix_plan.md` | **Add/modify** -- specific implementation tasks |
| `.ralph/AGENT.md` | Rarely edit (auto-maintained by Ralph) |
| `.ralphrc` | Rarely edit (sensible defaults) |

### .gitignore

When you run `ralph-enable` (or any engine variant), Ralph automatically appends the following entries to your project's `.gitignore`. If no `.gitignore` exists, one is created.

```gitignore
# Ralph — ignore everything except key files
.ralph/*
!.ralph/fix_plan.md
!.ralph/PROMPT.md
!.ralph/PROMPT_PLAN.md
!.ralph/constitution.md
```

This keeps Ralph's runtime state (logs, session files, circuit breaker state) out of version control while preserving the files you actually edit: your task plan, prompt instructions, planning prompt, and constitution.

If you're setting up `.gitignore` manually, copy the block above into your project's `.gitignore`.

---

## Quick Start

### With Devin (recommended)

```bash
cd my-project
ralph-devin-enable           # One-time setup
ralph-devin --monitor        # Start the loop with tmux dashboard

# Or use aliases:
rpd.hitl                     # Human-in-the-loop (live + monitor)
rpd.dev                      # Development mode (live + monitor + verbose)
rpd.task 3                   # Execute specific task #3 from fix_plan.md
rpd.task R05                 # Execute task **R05** by its ID
rpd.task.int 3               # Interactive TUI mode for task #3
rpd.p 3                      # Spawn 3 parallel Devin agents
```

### With Claude Code

```bash
cd my-project
ralph-enable                 # One-time setup
ralph --monitor              # Start the loop

# Or use aliases:
rpc.hitl                     # Human-in-the-loop (live + monitor)
rpc.dev                      # Development mode
rpc.task 3                   # Execute specific task #3 from fix_plan.md
rpc.task R05                 # Execute task **R05** by its ID
```

### With Codex

```bash
cd my-project
ralph-codex-enable           # One-time setup
ralph-codex --monitor        # Start the loop

# Or use aliases:
rpx.hitl                     # Human-in-the-loop (live + monitor)
rpx.gpt4                     # Use GPT-4 model
rpx.task 3                   # Execute specific task #3 from fix_plan.md
rpx.task R05                 # Execute task **R05** by its ID
```

---

## Aliases Reference

All aliases follow a consistent naming convention: `<prefix>.<category>.<variant>`

| Prefix | Engine |
|---|---|
| `rpd` | Devin CLI |
| `rpc` | Claude Code |
| `rpx` | Codex CLI |

### Devin Aliases (rpd)

Source: `devin/ALIASES.sh`

#### Basic Execution

| Alias | Expands To | Description |
|---|---|---|
| `rpd` | `ralph-devin` | Start the Devin loop |
| `rpd.live` | `ralph-devin --live` | Live streaming output |
| `rpd.monitor` | `ralph-devin --monitor` | tmux monitoring dashboard |
| `rpd.verbose` | `ralph-devin --verbose` | Verbose progress updates |
| `rpd.hitl` | `ralph-devin --live --monitor` | Human-in-the-loop (live + monitor) |

#### Session Management

| Alias | Expands To | Description |
|---|---|---|
| `rpd.continue` | `ralph-devin --continue` | Resume previous session |
| `rpd.reset` | `ralph-devin --reset-session` | Reset session state |
| `rpd.status` | `ralph-devin --status` | Show current loop status |

#### Circuit Breaker

| Alias | Expands To | Description |
|---|---|---|
| `rpd.cb.reset` | `ralph-devin --reset-circuit` | Reset circuit breaker |
| `rpd.cb.status` | `ralph-devin --circuit-status` | Show circuit breaker status |
| `rpd.cb.auto` | `ralph-devin --auto-reset-circuit` | Auto-reset on startup |

#### Rate Limiting

| Alias | Expands To | Description |
|---|---|---|
| `rpd.fast` | `ralph-devin --calls 200` | 200 calls/hour |
| `rpd.slow` | `ralph-devin --calls 50` | 50 calls/hour |

#### Model Selection

| Alias | Expands To | Description |
|---|---|---|
| `rpd.opus` | `ralph-devin --model opus` | Use Opus model |
| `rpd.sonnet` | `ralph-devin --model sonnet` | Use Sonnet model |
| `rpd.swe` | `ralph-devin --model swe` | Use SWE model |
| `rpd.gpt` | `ralph-devin --model gpt` | Use GPT model |

#### Permission Modes

| Alias | Expands To | Description |
|---|---|---|
| `rpd.safe` | `ralph-devin --permission-mode auto` | Safe auto-permission mode |
| `rpd.danger` | `ralph-devin --permission-mode dangerous` | Dangerous mode (skip permissions) |

#### Git Worktree

| Alias | Expands To | Description |
|---|---|---|
| `rpd.nowt` | `ralph-devin --no-worktree` | Disable worktree isolation |
| `rpd.wt.squash` | `ralph-devin --merge-strategy squash` | Squash merge strategy |
| `rpd.wt.merge` | `ralph-devin --merge-strategy merge` | Merge commit strategy |
| `rpd.wt.rebase` | `ralph-devin --merge-strategy rebase` | Rebase strategy |
| `rpd.wt.nogate` | `ralph-devin --quality-gates none` | Skip quality gates |

#### Interactive / TUI Mode

| Alias | Expands To | Description |
|---|---|---|
| `rpd.int` | `ralph-devin --no-devin-auto-exit` | Interactive TUI mode (no auto-exit) |
| `rpd.wt.int` | `ralph-devin --no-devin-auto-exit --live --monitor` | Interactive + live + monitor |

#### Parallel Agents

| Alias | Usage | Description |
|---|---|---|
| `rpd.p N` | `rpd.p 3` | Spawn N parallel agents (auto-exit) |
| `rpd.int.p N` | `rpd.int.p 3` | Spawn N parallel agents (interactive TUI) |
| `rpd.p.b N` | `rpd.p.b 3` | Spawn N agents as background processes |
| `rpd.int.p.b N` | `rpd.int.p.b 3` | Spawn N interactive agents in background |

#### Task-Specific Execution

| Alias | Usage | Description |
|---|---|---|
| `rpd.task N\|ID` | `rpd.task 3` or `rpd.task R05` | Execute task #N or task ID from fix_plan.md (non-interactive) |
| `rpd.task.int N\|ID` | `rpd.task.int 3` or `rpd.task.int R05` | Execute task #N or task ID in interactive TUI mode |

#### Workflow Presets

| Alias | Expands To | Description |
|---|---|---|
| `rpd.dev` | `ralph-devin --live --monitor --verbose` | Development mode |
| `rpd.prod` | `ralph-devin --calls 50 --auto-reset-circuit --permission-mode dangerous` | Production / unattended mode |
| `rpd.wt.full` | `ralph-devin --live --monitor --merge-strategy squash --quality-gates auto` | Full worktree mode |

#### Setup and Management

| Alias | Expands To | Description |
|---|---|---|
| `rpd.monitor` | `ralph-monitor-devin` | Launch Devin monitor |
| `rpd.install` | *(runs install_devin.sh)* | Install/reinstall Devin engine |
| `rpd.uninstall` | *(runs uninstall_devin.sh)* | Uninstall Devin engine |
| `rpd.enable` | `ralph-devin-enable` | Enable Ralph+Devin in current project |
| `rpd.plan` | `ralph-plan --engine devin` | Planning mode with Devin |
| `rpd.plan.file <path>` | `ralph-plan --engine devin --file <path>` | Plan from a specific file (MD/JSON/text) |
| `rpd.compress` | `ralph-plan --engine devin --compress` | Compress fix plan to reduce token usage |

---

### Claude Code Aliases (rpc)

Source: `ALIASES.sh`

#### Basic Execution

| Alias | Expands To | Description |
|---|---|---|
| `rpc` | `ralph` | Start the Claude Code loop |
| `rpc.live` | `ralph --live` | Live streaming output |
| `rpc.monitor` | `ralph --monitor` | tmux monitoring dashboard |
| `rpc.verbose` | `ralph --verbose` | Verbose progress updates |
| `rpc.hitl` | `ralph --live --monitor` | Human-in-the-loop (live + monitor) |

#### Session Management

| Alias | Expands To | Description |
|---|---|---|
| `rpc.continue` | `ralph --continue` | Resume previous session |
| `rpc.reset` | `ralph --reset-session` | Reset session state |
| `rpc.status` | `ralph --status` | Show current loop status |

#### Circuit Breaker

| Alias | Expands To | Description |
|---|---|---|
| `rpc.cb.reset` | `ralph --reset-circuit` | Reset circuit breaker |
| `rpc.cb.status` | `ralph --circuit-status` | Show circuit breaker status |
| `rpc.cb.auto` | `ralph --auto-reset-circuit` | Auto-reset on startup |

#### Rate Limiting / Loop Control

| Alias | Expands To | Description |
|---|---|---|
| `rpc.fast` | `ralph --calls 200` | 200 calls/hour |
| `rpc.slow` | `ralph --calls 50` | 50 calls/hour |
| `rpc.test` | `ralph --max-loops 1` | Single loop iteration (test) |
| `rpc.5` | `ralph --max-loops 5` | Run 5 loops |
| `rpc.10` | `ralph --max-loops 10` | Run 10 loops |

#### Model Selection

| Alias | Expands To | Description |
|---|---|---|
| `rpc.opus` | `ralph --model opus` | Use Opus model |
| `rpc.sonnet` | `ralph --model sonnet` | Use Sonnet model |

#### Output Format

| Alias | Expands To | Description |
|---|---|---|
| `rpc.json` | `ralph --output-format json` | JSON output mode |
| `rpc.text` | `ralph --output-format text` | Text output mode |

#### Git Worktree

| Alias | Expands To | Description |
|---|---|---|
| `rpc.nowt` | `ralph --no-worktree` | Disable worktree isolation |
| `rpc.wt.squash` | `ralph --merge-strategy squash` | Squash merge strategy |
| `rpc.wt.merge` | `ralph --merge-strategy merge` | Merge commit strategy |
| `rpc.wt.rebase` | `ralph --merge-strategy rebase` | Rebase strategy |
| `rpc.wt.nogate` | `ralph --quality-gates none` | Skip quality gates |
| `rpc.wt.full` | `ralph --live --monitor --merge-strategy squash --quality-gates auto` | Full worktree mode |

#### Interactive / Parallel

| Alias | Usage | Description |
|---|---|---|
| `rpc.int` | `rpc.int` | Interactive mode (live + monitor) |
| `rpc.int.p N` | `rpc.int.p 3` | Spawn N parallel agents |
| `rpc.int.p.b N` | `rpc.int.p.b 3` | Spawn N agents in background |

#### Task-Specific Execution

| Alias | Usage | Description |
|---|---|---|
| `rpc.task N\|ID` | `rpc.task 3` or `rpc.task R05` | Execute task #N or task ID from fix_plan.md |
| `rpc.task.int N\|ID` | `rpc.task.int 3` or `rpc.task.int R05` | Execute task #N or task ID in interactive mode (live + monitor) |

#### Workflow Presets

| Alias | Expands To | Description |
|---|---|---|
| `rpc.dev` | `ralph --live --monitor --verbose` | Development mode |
| `rpc.prod` | `ralph --calls 50 --auto-reset-circuit` | Production / unattended mode |
| `rpc.debug` | `ralph --live --verbose --max-loops 1` | Debug mode (single loop) |

#### Setup, Management, and Planning

| Alias | Expands To | Description |
|---|---|---|
| `rpc.monitor` | `ralph-monitor` | Launch Claude monitor |
| `rpc.install` | *(runs install.sh)* | Install/reinstall Claude engine |
| `rpc.uninstall` | *(runs uninstall.sh)* | Uninstall Claude engine |
| `rpc.plan` | `ralph-plan` | Planning mode (Claude engine) |
| `rpc.plan.sup` | `ralph-plan --yolo --superpowers` | Planning with yolo + superpowers plugin |
| `rpc.plan.file <path>` | `ralph-plan --file <path>` | Plan from a specific file (MD/JSON/text) |
| `rpc.compress` | `ralph-plan --compress` | Compress fix plan to reduce token usage |

---

### Codex Aliases (rpx)

Source: `codex/ALIASES.sh`

#### Basic Execution

| Alias | Expands To | Description |
|---|---|---|
| `rpx` | `ralph-codex` | Start the Codex loop |
| `rpx.live` | `ralph-codex --live` | Live streaming output |
| `rpx.monitor` | `ralph-codex --monitor` | tmux monitoring dashboard |
| `rpx.verbose` | `ralph-codex --verbose` | Verbose progress updates |
| `rpx.hitl` | `ralph-codex --live --monitor` | Human-in-the-loop (live + monitor) |

#### Session Management

| Alias | Expands To | Description |
|---|---|---|
| `rpx.continue` | `ralph-codex --continue` | Resume previous session |
| `rpx.reset` | `ralph-codex --reset-session` | Reset session state |
| `rpx.status` | `ralph-codex --status` | Show current loop status |

#### Circuit Breaker

| Alias | Expands To | Description |
|---|---|---|
| `rpx.cb.reset` | `ralph-codex --reset-circuit` | Reset circuit breaker |
| `rpx.cb.status` | `ralph-codex --circuit-status` | Show circuit breaker status |
| `rpx.cb.auto` | `ralph-codex --auto-reset-circuit` | Auto-reset on startup |

#### Rate Limiting / Loop Control

| Alias | Expands To | Description |
|---|---|---|
| `rpx.fast` | `ralph-codex --calls 200` | 200 calls/hour |
| `rpx.slow` | `ralph-codex --calls 50` | 50 calls/hour |
| `rpx.test` | `ralph-codex --max-loops 1` | Single loop iteration (test) |
| `rpx.5` | `ralph-codex --max-loops 5` | Run 5 loops |
| `rpx.10` | `ralph-codex --max-loops 10` | Run 10 loops |

#### Model Selection

| Alias | Expands To | Description |
|---|---|---|
| `rpx.gpt4` | `ralph-codex --model gpt-4` | Use GPT-4 |
| `rpx.gpt35` | `ralph-codex --model gpt-3.5` | Use GPT-3.5 |
| `rpx.claude` | `ralph-codex --model claude` | Use Claude |

#### Permission Modes

| Alias | Expands To | Description |
|---|---|---|
| `rpx.safe` | `ralph-codex --permission-mode auto` | Safe auto-permission mode |
| `rpx.danger` | `ralph-codex --permission-mode dangerous` | Dangerous mode (skip permissions) |

#### Git Worktree

| Alias | Expands To | Description |
|---|---|---|
| `rpx.nowt` | `ralph-codex --no-worktree` | Disable worktree isolation |
| `rpx.wt.squash` | `ralph-codex --merge-strategy squash` | Squash merge strategy |
| `rpx.wt.merge` | `ralph-codex --merge-strategy merge` | Merge commit strategy |
| `rpx.wt.rebase` | `ralph-codex --merge-strategy rebase` | Rebase strategy |
| `rpx.wt.nogate` | `ralph-codex --quality-gates none` | Skip quality gates |

#### Auto-Exit / Interactive

| Alias | Usage | Description |
|---|---|---|
| `rpx.autoexit` | `rpx.autoexit` | Force auto-exit mode |
| `rpx.int` | `rpx.int` | Interactive mode (no auto-exit) |
| `rpx.wt.int` | `rpx.wt.int` | Interactive + live + monitor |
| `rpx.int.p N` | `rpx.int.p 3` | Spawn N parallel interactive agents |
| `rpx.int.p.b N` | `rpx.int.p.b 3` | Spawn N interactive agents in background |

#### Task-Specific Execution

| Alias | Usage | Description |
|---|---|---|
| `rpx.task N\|ID` | `rpx.task 3` or `rpx.task R05` | Execute task #N or task ID from fix_plan.md (non-interactive) |
| `rpx.task.int N\|ID` | `rpx.task.int 3` or `rpx.task.int R05` | Execute task #N or task ID in interactive TUI mode |

#### Workflow Presets

| Alias | Expands To | Description |
|---|---|---|
| `rpx.dev` | `ralph-codex --live --monitor --verbose` | Development mode |
| `rpx.prod` | `ralph-codex --calls 50 --auto-reset-circuit --permission-mode dangerous` | Production / unattended mode |
| `rpx.debug` | `ralph-codex --live --verbose --max-loops 1` | Debug mode (single loop) |
| `rpx.wt.full` | `ralph-codex --live --monitor --merge-strategy squash --quality-gates auto` | Full worktree mode |

#### Setup and Management

| Alias | Expands To | Description |
|---|---|---|
| `rpx.monitor` | `ralph-monitor-codex` | Launch Codex monitor |
| `rpx.install` | *(runs install_codex.sh)* | Install/reinstall Codex engine |
| `rpx.uninstall` | *(runs uninstall_codex.sh)* | Uninstall Codex engine |
| `rpx.enable` | `ralph-codex-enable` | Enable Ralph+Codex in current project |
| `rpx.plan` | `ralph-plan --engine codex` | Planning mode with Codex |
| `rpx.plan.file <path>` | `ralph-plan --engine codex --file <path>` | Plan from a specific file (MD/JSON/text) |
| `rpx.compress` | `ralph-plan --engine codex --compress` | Compress fix plan to reduce token usage |

---

### Shared Aliases

These work regardless of engine:

| Alias | Expands To | Description |
|---|---|---|
| `ralph.setup` | `ralph-setup` | Create new project |
| `ralph.enable` | `ralph-enable` | Enable Ralph (Claude) |
| `ralph.enable.ci` | `ralph-enable-ci` | Non-interactive enable |
| `ralph.migrate` | `ralph-migrate` | Migrate to `.ralph/` structure |
| `ralph.import` | `ralph-import` | Import PRD |
| `ralph.check.beads` | `ralph-check-beads` | Beads diagnostic |
| `ralph.plan` | `ralph-plan` | Planning mode |
| `rp.install` | *(all three install scripts)* | Install all engines at once |

---

## Commands Reference

### Global Commands (per engine)

| Action | Devin | Claude Code | Codex |
|---|---|---|---|
| Main loop | `ralph-devin` | `ralph` | `ralph-codex` |
| Monitor dashboard | `ralph-devin-monitor` | `ralph-monitor` | `ralph-codex-monitor` |
| New project | `ralph-devin-setup` | `ralph-setup` | `ralph-codex-setup` |
| Enable in project | `ralph-devin-enable` | `ralph-enable` | `ralph-codex-enable` |
| Enable (CI) | `ralph-devin-enable-ci` | `ralph-enable-ci` | `ralph-codex-enable-ci` |
| Import PRD | `ralph-devin-import` | `ralph-import` | `ralph-codex-import` |
| Planning mode | `ralph-plan --engine devin` | `ralph-plan` | `ralph-plan --engine codex` |

### Common Loop Options

These flags work across all engines (substitute `ralph-devin` / `ralph` / `ralph-codex`):

```
-h, --help              Show help message
-c, --calls NUM         Max calls per hour (default: 100)
-p, --prompt FILE       Custom prompt file
-s, --status            Show current status and exit
-m, --monitor           Start with tmux monitoring
-v, --verbose           Detailed progress updates
-l, --live              Live streaming output
-t, --timeout MIN       Execution timeout in minutes (default: 15)
--no-continue           Disable session continuity
--reset-circuit         Reset circuit breaker
--circuit-status        Show circuit breaker status
--auto-reset-circuit    Auto-reset circuit breaker on startup
--reset-session         Reset session state
--task NUM|ID           Execute a specific task by number (1-based) or bold ID (e.g. R05)
```

### Devin-Specific Options

```
--model MODEL           Model: opus, sonnet, swe, gpt
--permission-mode MODE  Permission mode: auto, dangerous
--max-loops NUM         Stop after N loops (0 = unlimited)
--no-worktree           Disable git worktree isolation
--merge-strategy STR    Merge strategy: squash, merge, rebase
--quality-gates GATES   Quality gates: auto, none, or "cmd1;cmd2"
--no-devin-auto-exit    Interactive TUI mode (no auto-exit)
--parallel N            Spawn N parallel agents
--parallel-bg N         Spawn N background agents
```

### Codex-Specific Options

```
--model MODEL           Model: gpt-4, gpt-3.5, claude
--permission-mode MODE  Permission mode: auto, dangerous
--max-loops NUM         Stop after N loops (0 = unlimited)
--no-worktree           Disable git worktree isolation
--merge-strategy STR    Merge strategy: squash, merge, rebase
--quality-gates GATES   Quality gates: auto, none, or "cmd1;cmd2"
--no-codex-auto-exit    Interactive mode (no auto-exit)
--codex-auto-exit       Force auto-exit with -p flag
--parallel N            Spawn N parallel agents
--parallel-bg N         Spawn N background agents
```

### Claude-Specific Options

```
--model MODEL           Model: opus, sonnet
--output-format FORMAT  Output format: json, text
--allowed-tools TOOLS   Restrict allowed tools
--yolo                  Skip all permission checks (plan mode)
--superpowers           Load superpowers plugin (plan mode)
```

---

## Configuration

### Project Configuration (.ralphrc)

Each project gets a `.ralphrc` file with engine-specific settings:

```bash
# .ralphrc -- Ralph project configuration
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"

# Engine: claude (default), devin, codex
RALPH_ENGINE="devin"

# Loop settings
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15

# Tool permissions (Claude Code)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *)"

# Session management
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

# Circuit breaker
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false

# Auto-PR (all engines)
PR_ENABLED=true
```

### Devin-Specific Configuration (.ralphrc.devin)

```bash
RALPH_ENGINE="devin"
DEVIN_TIMEOUT_MINUTES=30
DEVIN_MAX_ACU=100
DEVIN_POLL_INTERVAL=15
DEVIN_USE_CONTINUE=true

# Worktree isolation
WORKTREE_ENABLED=true
WORKTREE_MERGE_STRATEGY=squash
WORKTREE_QUALITY_GATES=auto
WORKTREE_AUTO_CLEANUP=true
WORKTREE_BRANCH_PREFIX=ralph-devin
```

### Codex-Specific Configuration (.ralphrc.codex)

```bash
RALPH_ENGINE="codex"
CODEX_TIMEOUT_MINUTES=30
CODEX_MODEL="gpt-4"
CODEX_PERMISSION_MODE="dangerous"
CODEX_USE_CONTINUE=true
CODEX_AUTO_EXIT=true

# Worktree isolation (same options as Devin)
WORKTREE_ENABLED=true
WORKTREE_MERGE_STRATEGY=squash
WORKTREE_QUALITY_GATES=auto
```

---

## How It Works

Ralph operates on a loop cycle:

1. **Read instructions** -- Loads `.ralph/PROMPT.md` with your project goals
2. **Pick a task** -- Selects the next unclaimed `[ ]` task from `fix_plan.md` (or a specific task via `--task NUM` or `--task ID`), marks it in-progress `[~]`
3. **Inject directives** -- Prepends worktree constraints and a non-interactive directive to prevent "Shall I proceed?" stalls
4. **Execute AI agent** -- Runs the configured engine (Devin / Claude / Codex) with current context
5. **Detect changes** -- Compares git state before and after execution to count files changed, lines added/removed
6. **Early exit on no changes** -- If zero files changed, prints a yellow summary, reverts the `[~]` marker back to `[ ]` so the task can be retried, and exits cleanly
7. **Quality gates** -- Installs dependencies if needed, then runs lint/test/build checks (when worktree isolation is enabled)
8. **Merge and PR** -- Squash-merges changes back and optionally creates a PR
9. **Execution summary** -- Prints a green summary box with task name, files changed, lines added/removed, and net change
10. **Evaluate completion** -- Checks exit conditions (all tasks done, circuit breaker, rate limits)
11. **Repeat** -- Continues until the project is complete or limits are reached

### Task Selection

By default, Ralph picks the first unclaimed task (`- [ ]`) from `.ralph/fix_plan.md`. You can override this with the `--task` flag using either a 1-based ordinal number or a bold task ID (e.g. `**R05**`):

```bash
ralph-devin --task 3        # Execute the 3rd task in fix_plan.md
ralph --task R05 --live     # Execute task **R05** by its ID with live output
ralph --task 5 --live       # Execute the 5th task with live output
ralph-codex --task r05      # Case-insensitive: matches **R05**
```

Task numbers are 1-based ordinals counting all task lines (`[ ]`, `[~]`, and `[x]` markers). Task IDs match the bold `**ID**` prefix in the task line (case-insensitive). The corresponding aliases are:

```bash
rpd.task 3                  # Devin: non-interactive, task #3
rpd.task.int 3              # Devin: interactive TUI, task #3
rpc.task 3                  # Claude: task #3
rpc.task.int 3              # Claude: interactive (live + monitor), task #3
rpx.task 3                  # Codex: non-interactive, task #3
rpx.task.int 3              # Codex: interactive TUI, task #3
```

### Non-Interactive Directive

When running in autonomous mode (default for all engines), Ralph injects a **"NON-INTERACTIVE MODE -- ALWAYS EXECUTE"** directive at the top of the prompt. This tells the AI agent to:

- Never ask for confirmation or approval
- Pick the best approach and execute immediately
- Make pragmatic decisions on ambiguities and document them

This prevents stalls where the agent outputs "Shall I proceed?" and waits indefinitely for a human response that will never come.

### Change Detection and Execution Summary

After each execution, Ralph compares the git state before and after to detect what changed:

- **Committed changes** -- `git diff --stat` between pre/post execution SHAs
- **Uncommitted changes** -- `git status --porcelain` for staged and unstaged files

If **no files changed** (committed or uncommitted), Ralph:
1. Prints a yellow "No Changes Made" summary box
2. Reverts the in-progress marker (`[~]`) back to unclaimed (`[ ]`) in `fix_plan.md`
3. Cleans up the worktree
4. Exits with status "no_changes"

If **files were changed**, Ralph proceeds with quality gates and PR creation, then prints a green "Execution Summary" box showing:
- Task name
- Files changed count
- Lines added / removed
- Net line change

### Git Worktree Isolation

When enabled (default for Devin and Codex), each loop iteration runs on a dedicated git branch:

1. **Create** -- New worktree + branch (`ralph-devin/loop-<N>-<ts>`)
2. **Execute** -- Agent works inside the isolated worktree
3. **Install dependencies** -- Auto-detects package manager and runs install (worktrees lack `node_modules`)
4. **Quality gates** -- Auto-detected lint/test/build checks run
5. **Merge** -- Squash merge back to main if gates pass
6. **Cleanup** -- Worktree removed; branch deleted on success, preserved on failure

#### Automatic Dependency Installation

Worktrees are created from a fresh git checkout and don't inherit `node_modules` from the main project. Tools like biome, eslint, jest, etc. live inside `node_modules/.bin` and will fail if dependencies aren't installed first.

Before running quality gates, Ralph automatically:
1. Checks if `package.json` exists and `node_modules` is missing or empty
2. Detects the package manager from lock files (`pnpm-lock.yaml` -> pnpm, `bun.lockb` -> bun, `yarn.lock` -> yarn, default -> npm)
3. Runs the appropriate install command (e.g., `pnpm install --frozen-lockfile`)

This is a no-op if `node_modules` already exists or if the project isn't Node.js-based.

#### Auto-Detected Quality Gates

| Project Type | Gates |
|---|---|
| Node.js | `lint`, `typecheck`, `test`, `build` from `package.json` |
| Python | `ruff check .`, `pytest` |
| Go | `go vet ./...`, `go test ./...` |
| Rust | `cargo clippy`, `cargo test` |
| Makefile | `make lint`, `make test` |

### Intelligent Exit Detection

Ralph uses a **dual-condition gate** to prevent premature exits:

1. `completion_indicators >= 2` (heuristic detection from output patterns)
2. Agent's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block

Both must be true to exit. This prevents false exits when the agent says "phase complete" but still has more work to do.

### Circuit Breaker

Prevents runaway loops by detecting stagnation:

- Opens after 3 loops with no file changes
- Opens after 5 loops with the same repeated error
- Auto-recovers after a cooldown period (default: 30 minutes)

---

## System Requirements

| Dependency | Required | Notes |
|---|---|---|
| Bash 4.0+ | Yes | Script execution |
| jq | Yes | JSON processing |
| Git | Yes | Version control |
| GNU coreutils | Yes | `timeout` command (`brew install coreutils` on macOS) |
| tmux | Recommended | Integrated monitoring (`brew install tmux`) |
| Claude Code CLI | For Claude engine | `npm install -g @anthropic-ai/claude-code` |
| Devin CLI | For Devin engine | `pip install devin-cli` or `brew tap revanthpobala/tap && brew install devin-cli` |
| Codex CLI | For Codex engine | See https://docs.codex.ai/ |

---

## Uninstalling

```bash
# Uninstall individual engines
./devin/uninstall_devin.sh       # Remove Devin only
./codex/uninstall_codex.sh       # Remove Codex only
./uninstall.sh                   # Remove base Ralph (Claude)

# Or via aliases
rpd.uninstall
rpx.uninstall
rpc.uninstall
```

Uninstalling one engine does not affect the others.

---

## Project Status

**Upstream Base**: [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) v0.11.5 | **Fork Status**: Active Development | **Tests**: 602 tests, 100% pass rate

### What's Working Now

- **Multi-engine autonomous loop** -- Devin CLI, Claude Code, and Codex CLI under one unified interface
- **Git worktree isolation** -- each loop iteration runs on a dedicated branch; changes merge back only after quality gates pass
- **Automatic PR creation** via `lib/pr_manager.sh` with quality-gate labels
- **Parallel agent spawning** -- iTerm2 tabs, IDE terminals, or background processes (`--parallel N`)
- **Task-specific execution** -- `--task NUM` (ordinal) or `--task R05` (bold markdown ID)
- **Change detection with execution summary** -- files changed, lines added/removed; no-change early exit reverts task marker for retry
- **Non-interactive directive injection** -- prevents "Shall I proceed?" stalls in headless mode
- **Automatic dependency installation** in worktrees -- detects package manager, installs before quality gates
- **Interactive TUI mode** for Devin and Codex (`--no-devin-auto-exit` / `--no-codex-auto-exit`)
- **Planning mode** (`ralph-plan`) with PM-OS / DoE-OS auto-detection and multi-engine support
- **Ad-hoc task mode** (`ralph-plan --adhoc`) for quick bug/task entry into `fix_plan.md` via AI
- **Fix plan compression** (`ralph-plan --compress`) to reduce token consumption while preserving progress
- **File-based planning** (`ralph-plan --file`) for generating fix_plan from any MD, JSON, or text file
- **150+ shell aliases** across three engines (`rpc.*`, `rpd.*`, `rpx.*`)
- **Intelligent exit detection** -- dual-condition gate requiring BOTH completion indicators AND explicit EXIT_SIGNAL
- **Circuit breaker** with cooldown timer, auto-recovery, and configurable thresholds
- **Session continuity** with `--continue` / `--resume` and 24-hour expiration
- **Rate limiting** with hourly reset (100 calls/hour, configurable)
- **JSON output format** with automatic fallback to text parsing
- **File protection** -- multi-layered strategy to prevent accidental deletion of `.ralph/` config
- **`.gitignore` injection** -- auto-appends Ralph entries instead of overwriting
- **Interactive `ralph-enable` wizard** with auto-detection of project type and framework
- **CI/CD pipeline** with GitHub Actions for automated testing

### Recent Changes

**Fix Plan Compression Mode** (latest)
- `ralph-plan --compress` to compress `fix_plan.md` and reduce token consumption
- Archives current plan before compression (timestamped backup in `.ralph/logs/`)
- AI collapses completed items into summary lines, shortens verbose descriptions
- Preserves all task IDs, checkbox states, and progress tracking
- Works across all 3 engines: `rpc.compress`, `rpd.compress`, `rpx.compress`
- Supports `--yolo` and `--superpowers` flags (Claude only)

**File-based Planning Mode**
- `ralph-plan --file <path>` to generate fix_plan from a specific document
- Accepts Markdown (.md), JSON (.json), YAML (.yaml), or plain text (.txt) files
- AI reads the document, analyzes the codebase, and creates prioritized fix_plan.md
- Works across all 3 engines: `rpc.plan.file`, `rpx.plan.file`, `rpd.plan.file`
- Supports `--yolo` and `--superpowers` flags (Claude only)

**Ad-hoc Task Mode**
- `ralph-plan --adhoc` for quick one-liner bug/task entry into `fix_plan.md`
- Interactive prompt or inline description: `rpc.adhoc "Login broken on iOS"`
- AI analyzes codebase and creates structured `fix_plan.md` entry with subtasks
- Works across all 3 engines: `rpc.adhoc`, `rpx.adhoc`, `rpd.adhoc`
- Supports `--yolo` and `--superpowers` flags (Claude only)

**Task ID Selection**
- Support task ID selection via `--task R05` with bold markdown ID matching
- Case-insensitive matching for task IDs

**Task Selection & Change Detection**
- `--task NUM|ID` flag for executing specific tasks from `fix_plan.md`
- Change detection comparing git state before and after execution
- Execution summary with files changed, lines added/removed
- No-change early exit reverts `[~]` marker back to `[ ]` for retry
- Automatic dependency installation in worktrees (detects package manager from lock files)

**Gitignore Injection**
- Ralph injects `.gitignore` entries instead of copying a template file
- Preserves existing `.gitignore` content

**Fix Plan Status**
- `ralph-plan --status` to show current fix_plan.md progress
- `rpc.plan.s` / `rpd.plan.s` / `rpx.plan.s` aliases

**Quality Gate Mode (`ralph --qg`)**
- Standalone mode to run quality gates and invoke AI to fix failures
- Run with `ralph --qg` (auto-detects gates) or `ralph --qg --quality-gates "cmd1;cmd2"`
- Uses `worktree_build_qg_fix_prompt()` with subagent strategy for parallel fixing
- For Claude: `Task` tool is temporarily enabled during QG fix invocations
- Up to `MAX_QG_RETRIES` (default: 3) fix attempts
- Auto-commits fixes on success
- Main loop always creates PR regardless of gate status (`quality-gates-failed` label on failure)

**PR Creation & Worktree Integration**
- Automatic PR creation after successful quality gates
- Worktree directive separated from loop context for correct branch targeting
- Atomic file locking in `pick_next_task` for parallel safety

**Parallel Agent Spawning**
- iTerm2 tab-based parallel execution
- Background process mode (`--parallel-bg N`)
- Task claiming with in-progress tracking for parallel loop support

**Planning Mode**
- AI-powered `ralph-plan` for building `fix_plan.md` from PRDs
- PM-OS / DoE-OS auto-detection (sibling/cousin directory search)
- Multi-engine support (`--engine devin|codex|claude`)
- `--yolo` and `--superpowers` flags (Claude only)

**Codex CLI Engine**
- Full feature parity with Claude Code engine
- GPT-4, GPT-3.5, and Claude model selection
- Auto-exit and interactive TUI modes

**Devin CLI Engine**
- Cloud session polling with ACU limits
- Opus, Sonnet, SWE, and GPT model selection
- Permission modes (auto, dangerous)

### In Progress

- Fix plan status reporting improvements
- Expanded test coverage for new engines
- Log rotation functionality
- Dry-run mode
- Desktop notifications
- Metrics and analytics tracking

### Upstream Features (inherited from frankbria/ralph-claude-code v0.11.5)

- Autonomous development loops with intelligent exit detection
- Rate limiting with hourly reset (100 calls/hour, configurable)
- Circuit breaker with advanced error detection and auto-recovery
- Response analyzer with semantic understanding and two-stage error filtering
- JSON output format support with automatic fallback to text parsing
- Session continuity with context preservation and 24-hour expiration
- Modern CLI flags: `--output-format`, `--allowed-tools`, `--no-continue`
- Interactive project enablement with `ralph-enable` wizard
- `.ralphrc` configuration file for project settings
- Live streaming output with `--live` flag
- Multi-line error matching for accurate stuck loop detection
- 5-hour API limit handling with three-layer detection
- tmux integration for live monitoring
- PRD import functionality
- CI/CD pipeline with GitHub Actions

---

## Acknowledgments

- [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley
- [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) -- the upstream project this is forked from
- [Claude Code](https://claude.ai/code) by Anthropic
- [Devin](https://devin.ai) by Cognition
