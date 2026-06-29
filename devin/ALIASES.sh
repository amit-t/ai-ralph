# shellcheck shell=bash
# ============================================================================
# Ralph for Devin (rpd) - Bash/Zsh Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)
#
# Command-name prefix support
# ---------------------------
# This file honors RALPH_CMD_PREFIX (default: empty). When set — e.g. the
# personal fork exports RALPH_CMD_PREFIX=per. — every alias name AND the target
# binary are prefixed, so they coexist with the stock devkit:
#     rpd            -> per.rpd            (runs `per.ralph-devin`)
#     rpd.plan       -> per.rpd.plan       (runs `per.ralph-plan --engine devin`)
# Leave RALPH_CMD_PREFIX unset for the stock `rpd` / `ralph-devin` names.

: "${RALPH_CMD_PREFIX:=}"
__rp="${RALPH_CMD_PREFIX}"               # alias-name prefix
__R="${RALPH_CMD_PREFIX}ralph-devin"     # target binary

# Basic execution
alias "${__rp}rpd=$__R"
alias "${__rp}rpd.live=$__R --live"
alias "${__rp}rpd.monitor=$__R --monitor"
alias "${__rp}rpd.verbose=$__R --verbose"
alias "${__rp}rpd.hitl=$__R --live --monitor"

# Session management
alias "${__rp}rpd.continue=$__R --continue"
alias "${__rp}rpd.reset=$__R --reset-session"
alias "${__rp}rpd.status=$__R --status"

# Circuit breaker
alias "${__rp}rpd.cb.reset=$__R --reset-circuit"
alias "${__rp}rpd.cb.status=$__R --circuit-status"
alias "${__rp}rpd.cb.auto=$__R --auto-reset-circuit"

# Configuration variants
alias "${__rp}rpd.fast=$__R --calls 200"
alias "${__rp}rpd.slow=$__R --calls 50"

# Model selection (Devin loop defaults to swe-1.6 when no --model is given)
alias "${__rp}rpd.sw16=$__R --model swe-1.6"
alias "${__rp}rpd.opus=$__R --model opus"
alias "${__rp}rpd.sonnet=$__R --model sonnet"
alias "${__rp}rpd.swe=$__R --model swe"
alias "${__rp}rpd.gpt=$__R --model gpt"

# Permission modes
alias "${__rp}rpd.safe=$__R --permission-mode auto"
alias "${__rp}rpd.danger=$__R --permission-mode dangerous"

# Worktree management
alias "${__rp}rpd.nowt=$__R --no-worktree"
alias "${__rp}rpd.wt.squash=$__R --merge-strategy squash"
alias "${__rp}rpd.wt.merge=$__R --merge-strategy merge"
alias "${__rp}rpd.wt.rebase=$__R --merge-strategy rebase"
alias "${__rp}rpd.wt.nogate=$__R --quality-gates none"

# Quality gate fix mode (retry loop to fix failing gates)
alias "${__rp}rpd.qg=$__R --qg"

# Interactive (TUI) mode - Devin runs without -p flag, shows its TUI
alias "${__rp}rpd.int=$__R --no-devin-auto-exit"
alias "${__rp}rpd.wt.int=$__R --no-devin-auto-exit --live --monitor"

# Parallel non-interactive (spawns N agents: iTerm2 tabs or IDE terminal tabs)
# Usage: rpd.p 3  -> spawns 3 parallel devin agents (auto-exit)
# rpd.p N        → batch mode (spawn N parallel agents)
# rpd.p N M      → continuous mode (keep N workers saturated until M attempts;
#                                    per-worker terminal tabs when supported)
eval "${__rp}rpd.p() { $__R --parallel \"\${1:?Usage: ${__rp}rpd.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Continuous mode forcing the single-pane orchestrator (no tabs)
eval "${__rp}rpd.p.notabs() { $__R --parallel \"\${1:?Usage: ${__rp}rpd.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpd.p.notabs <N> <M>}\" --no-tabs; }"

# Parallel interactive (spawns N agents in TUI mode)
# Usage: rpd.int.p 3  -> spawns 3 parallel devin agents in interactive mode
eval "${__rp}rpd.int.p() { $__R --no-devin-auto-exit --parallel \"\${1:?Usage: ${__rp}rpd.int.p <number>}\"; }"

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpd.p.b 3  -> spawns 3 parallel devin agents in background
eval "${__rp}rpd.p.b() { $__R --parallel-bg \"\${1:?Usage: ${__rp}rpd.p.b <number>}\"; }"
eval "${__rp}rpd.int.p.b() { $__R --no-devin-auto-exit --parallel-bg \"\${1:?Usage: ${__rp}rpd.int.p.b <number>}\"; }"

# Combined common workflows
alias "${__rp}rpd.dev=$__R --live --monitor --verbose"
alias "${__rp}rpd.prod=$__R --calls 50 --auto-reset-circuit --permission-mode dangerous"
alias "${__rp}rpd.wt.full=$__R --live --monitor --merge-strategy squash --quality-gates auto"

# Setup & Management
alias "${__rp}rpd.monitor=${__rp}ralph-monitor-devin"
alias "${__rp}rpd.install=(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./install_devin.sh)"
alias "${__rp}rpd.uninstall=(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./uninstall_devin.sh)"
alias "${__rp}rpd.enable=${__rp}ralph-devin-enable"

# Planning mode (AI-powered, uses devin engine)
alias "${__rp}rpd.plan=${__rp}ralph-plan --engine devin"
# Fix plan status (note: rpd.status is agent session status; rpd.plan.s is fix plan status)
alias "${__rp}rpd.plan.s=${__rp}ralph-plan --engine devin --status"

# Model overrides for Devin planning (Devin CLI accepts --model swe-1.6|opus|sonnet|...)
alias "${__rp}rpd.plan.sw16=${__rp}ralph-plan --engine devin --model swe-1.6"
alias "${__rp}rpd.plan.opus=${__rp}ralph-plan --engine devin --model opus"
alias "${__rp}rpd.plan.sonnet=${__rp}ralph-plan --engine devin --model sonnet"

# Thinking depth for Devin planning (prompt preamble; Devin has no --effort flag)
alias "${__rp}rpd.plan.hard=${__rp}ralph-plan --engine devin --thinking hard"
alias "${__rp}rpd.plan.ultra=${__rp}ralph-plan --engine devin --thinking ultra"

# Combined: Opus + ultrathink for deepest Devin planning
alias "${__rp}rpd.plan.opus.ultra=${__rp}ralph-plan --engine devin --model opus --thinking ultra"

# Ad-hoc task mode (interactive one-liner to fix_plan entry, uses devin engine)
# Usage: rpd.adhoc                        -> prompts for task description
# Usage: rpd.adhoc "Login broken on iOS"  -> inline description
alias "${__rp}rpd.adhoc=${__rp}ralph-plan --engine devin --adhoc"

# Compress fix plan (reduce token consumption, archive original, uses devin engine)
alias "${__rp}rpd.compress=${__rp}ralph-plan --engine devin --compress"

# File-based planning (pass a specific MD, JSON, or text file, uses devin engine)
# Usage: rpd.plan.file ./docs/requirements.md   -> plan from a specific file
# Usage: rpd.plan.file ./tasks.json             -> plan from a JSON task list
eval "${__rp}rpd.plan.file() { ${__rp}ralph-plan --engine devin --file \"\${1:?Usage: ${__rp}rpd.plan.file <file_path>}\"; }"

# Task-specific execution (pass fix_plan.md task number)
# Usage: rpd.task 3        -> non-interactive, execute task #3
# Usage: rpd.task.int 3    -> interactive TUI, execute task #3
eval "${__rp}rpd.task() { $__R --task \"\${1:?Usage: ${__rp}rpd.task <task_number>}\"; }"
eval "${__rp}rpd.task.int() { $__R --no-devin-auto-exit --task \"\${1:?Usage: ${__rp}rpd.task.int <task_number>}\"; }"

# Workspace mode (multi-repo orchestration)
alias "${__rp}rpd.ws=$__R --workspace"
alias "${__rp}rpd.ws.int=$__R --workspace --live --monitor"
# rpd.ws.p N      → batch workspace (1 batch of N tasks)
# rpd.ws.p N M    → continuous workspace (N concurrent until M attempts; per-worker tabs by default)
eval "${__rp}rpd.ws.p() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpd.ws.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Workspace continuous forcing single-pane (no tabs)
eval "${__rp}rpd.ws.p.notabs() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpd.ws.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpd.ws.p.notabs <N> <M>}\" --no-tabs; }"

unset __rp __R
