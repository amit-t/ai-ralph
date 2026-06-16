# shellcheck shell=bash
# ============================================================================
# Ralph for Codex (rpx) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)
#
# Command-name prefix support
# ---------------------------
# This file honors RALPH_CMD_PREFIX (default: empty). When set — e.g. the
# personal fork exports RALPH_CMD_PREFIX=per. — every alias name AND the target
# binary are prefixed, so they coexist with the stock devkit:
#     rpx          -> per.rpx          (runs `per.ralph-codex`)
#     rpx.enable   -> per.rpx.enable   (runs `per.ralph-codex-enable`)
# Leave RALPH_CMD_PREFIX unset for the stock `rpx` / `ralph-codex` names.

: "${RALPH_CMD_PREFIX:=}"
__rp="${RALPH_CMD_PREFIX}"              # alias-name prefix
__R="${RALPH_CMD_PREFIX}ralph-codex"   # target binary

# Basic execution
alias "${__rp}rpx=$__R"
alias "${__rp}rpx.live=$__R --live"
alias "${__rp}rpx.monitor=$__R --monitor"
alias "${__rp}rpx.verbose=$__R --verbose"
alias "${__rp}rpx.hitl=$__R --live --monitor"

# Session management
alias "${__rp}rpx.continue=$__R --continue"
alias "${__rp}rpx.reset=$__R --reset-session"
alias "${__rp}rpx.status=$__R --status"

# Circuit breaker
alias "${__rp}rpx.cb.reset=$__R --reset-circuit"
alias "${__rp}rpx.cb.status=$__R --circuit-status"
alias "${__rp}rpx.cb.auto=$__R --auto-reset-circuit"

# Configuration variants
alias "${__rp}rpx.fast=$__R --calls 200"
alias "${__rp}rpx.slow=$__R --calls 50"
alias "${__rp}rpx.test=$__R --max-loops 1"
alias "${__rp}rpx.5=$__R --max-loops 5"
alias "${__rp}rpx.10=$__R --max-loops 10"

# Model selection
alias "${__rp}rpx.gpt4=$__R --model gpt-4"
alias "${__rp}rpx.gpt35=$__R --model gpt-3.5"
alias "${__rp}rpx.claude=$__R --model claude"

# Permission modes
alias "${__rp}rpx.safe=$__R --permission-mode auto"
alias "${__rp}rpx.danger=$__R --permission-mode dangerous"

# Worktree management
alias "${__rp}rpx.nowt=$__R --no-worktree"
alias "${__rp}rpx.wt.squash=$__R --merge-strategy squash"
alias "${__rp}rpx.wt.merge=$__R --merge-strategy merge"
alias "${__rp}rpx.wt.rebase=$__R --merge-strategy rebase"
alias "${__rp}rpx.wt.nogate=$__R --quality-gates none"

# Quality gate fix mode (retry loop to fix failing gates)
alias "${__rp}rpx.qg=$__R --qg"

# Auto-exit control
alias "${__rp}rpx.autoexit=$__R --codex-auto-exit"
alias "${__rp}rpx.int=$__R --no-codex-auto-exit"

# Parallel mode (spawns N agents: iTerm2 tabs from iTerm, IDE terminal tabs from Windsurf/VS Code/Cursor)
# Usage: rpx.p 3      -> spawns 3 parallel codex agents (auto-exit)
# rpx.p N             → batch mode (spawn N parallel agents)
# rpx.p N M           → continuous mode (keep N workers saturated until M attempts;
#                                         per-worker terminal tabs when supported)
eval "${__rp}rpx.p() { $__R --parallel \"\${1:?Usage: ${__rp}rpx.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Continuous mode forcing the single-pane orchestrator (no tabs)
eval "${__rp}rpx.p.notabs() { $__R --parallel \"\${1:?Usage: ${__rp}rpx.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpx.p.notabs <N> <M>}\" --no-tabs; }"

# Usage: rpx.int.p 3  -> spawns 3 parallel codex agents in interactive (no auto-exit) mode
eval "${__rp}rpx.int.p() { $__R --no-codex-auto-exit --parallel \"\${1:?Usage: ${__rp}rpx.int.p <number>}\"; }"

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpx.int.p.b 3  -> spawns 3 parallel codex agents in background
eval "${__rp}rpx.int.p.b() { $__R --no-codex-auto-exit --parallel-bg \"\${1:?Usage: ${__rp}rpx.int.p.b <number>}\"; }"

# Combined common workflows
alias "${__rp}rpx.dev=$__R --live --monitor --verbose"
alias "${__rp}rpx.prod=$__R --calls 50 --auto-reset-circuit --permission-mode dangerous"
alias "${__rp}rpx.debug=$__R --live --verbose --max-loops 1"
alias "${__rp}rpx.wt.full=$__R --live --monitor --merge-strategy squash --quality-gates auto"
alias "${__rp}rpx.wt.int=$__R --no-codex-auto-exit --live --monitor"

# Setup & Management
alias "${__rp}rpx.monitor=${__R}-monitor"
alias "${__rp}rpx.install=(cd ~/Projects/Tools-Utilities/ai-ralph/codex && ./install_codex.sh)"
alias "${__rp}rpx.uninstall=(cd ~/Projects/Tools-Utilities/ai-ralph/codex && ./uninstall_codex.sh)"
alias "${__rp}rpx.enable=${__R}-enable"

# Planning mode (AI-powered, uses codex engine)
alias "${__rp}rpx.plan=${__rp}ralph-plan --engine codex"
# Fix plan status (note: rpx.status is agent session status; rpx.plan.s is fix plan status)
alias "${__rp}rpx.plan.s=${__rp}ralph-plan --engine codex --status"

# Ad-hoc task mode (interactive one-liner to fix_plan entry, uses codex engine)
# Usage: rpx.adhoc                        -> prompts for task description
# Usage: rpx.adhoc "Login broken on iOS"  -> inline description
alias "${__rp}rpx.adhoc=${__rp}ralph-plan --engine codex --adhoc"

# Compress fix plan (reduce token consumption, archive original, uses codex engine)
alias "${__rp}rpx.compress=${__rp}ralph-plan --engine codex --compress"

# File-based planning (pass a specific MD, JSON, or text file, uses codex engine)
# Usage: rpx.plan.file ./docs/requirements.md   -> plan from a specific file
# Usage: rpx.plan.file ./tasks.json             -> plan from a JSON task list
eval "${__rp}rpx.plan.file() { ${__rp}ralph-plan --engine codex --file \"\${1:?Usage: ${__rp}rpx.plan.file <file_path>}\"; }"

# Task-specific execution (pass fix_plan.md task number)
# Usage: rpx.task 3        -> non-interactive, execute task #3
# Usage: rpx.task.int 3    -> interactive TUI, execute task #3
eval "${__rp}rpx.task() { $__R --task \"\${1:?Usage: ${__rp}rpx.task <task_number>}\"; }"
eval "${__rp}rpx.task.int() { $__R --no-codex-auto-exit --task \"\${1:?Usage: ${__rp}rpx.task.int <task_number>}\"; }"

# Workspace mode (multi-repo orchestration)
alias "${__rp}rpx.ws=$__R --workspace"
alias "${__rp}rpx.ws.int=$__R --workspace --live --monitor"
# rpx.ws.p N      → batch workspace (1 batch of N tasks)
# rpx.ws.p N M    → continuous workspace (N concurrent until M attempts; per-worker tabs by default)
eval "${__rp}rpx.ws.p() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpx.ws.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Workspace continuous forcing single-pane (no tabs)
eval "${__rp}rpx.ws.p.notabs() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpx.ws.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpx.ws.p.notabs <N> <M>}\" --no-tabs; }"

unset __rp __R
