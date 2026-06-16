# shellcheck shell=bash
# ============================================================================
# Ralph for Claude Code (rpc) - Bash/Zsh Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)
#
# Command-name prefix support
# ---------------------------
# This file honors RALPH_CMD_PREFIX (default: empty). When set — e.g. the
# personal fork exports RALPH_CMD_PREFIX=per. — every alias name AND the target
# binary are prefixed, so they coexist with the stock devkit:
#     rpc            -> per.rpc            (runs `per.ralph`)
#     ralph.setup    -> per.ralph.setup    (runs `per.ralph-setup`)
# Leave RALPH_CMD_PREFIX unset for the stock `rpc` / `ralph` names.

: "${RALPH_CMD_PREFIX:=}"
__rp="${RALPH_CMD_PREFIX}"          # alias-name prefix
__R="${RALPH_CMD_PREFIX}ralph"      # target binary

# Basic execution
alias "${__rp}rpc=$__R"
alias "${__rp}rpc.live=$__R --live"
alias "${__rp}rpc.monitor=$__R --monitor"
alias "${__rp}rpc.verbose=$__R --verbose"
alias "${__rp}rpc.hitl=$__R --live --monitor"

# Session management
alias "${__rp}rpc.continue=$__R --continue"
alias "${__rp}rpc.reset=$__R --reset-session"
alias "${__rp}rpc.status=$__R --status"

# Circuit breaker
alias "${__rp}rpc.cb.reset=$__R --reset-circuit"
alias "${__rp}rpc.cb.status=$__R --circuit-status"
alias "${__rp}rpc.cb.auto=$__R --auto-reset-circuit"

# Configuration variants
alias "${__rp}rpc.fast=$__R --calls 200"
alias "${__rp}rpc.slow=$__R --calls 50"
alias "${__rp}rpc.test=$__R --max-loops 1"
alias "${__rp}rpc.5=$__R --max-loops 5"
alias "${__rp}rpc.10=$__R --max-loops 10"

# Model selection
alias "${__rp}rpc.opus=$__R --model opus"
alias "${__rp}rpc.sonnet=$__R --model sonnet"

# Output formats
alias "${__rp}rpc.json=$__R --output-format json"
alias "${__rp}rpc.text=$__R --output-format text"

# Worktree management
alias "${__rp}rpc.nowt=$__R --no-worktree"
alias "${__rp}rpc.wt.squash=$__R --merge-strategy squash"
alias "${__rp}rpc.wt.merge=$__R --merge-strategy merge"
alias "${__rp}rpc.wt.rebase=$__R --merge-strategy rebase"
alias "${__rp}rpc.wt.nogate=$__R --quality-gates none"
alias "${__rp}rpc.wt.full=$__R --live --monitor --merge-strategy squash --quality-gates auto"

# Quality gate fix mode (retry loop to fix failing gates)
alias "${__rp}rpc.qg=$__R --qg"

# Interactive mode
alias "${__rp}rpc.int=$__R --live --monitor"

# Parallel non-interactive (spawns N agents: iTerm2 tabs or IDE terminal tabs)
# Mirrors rpd.p — plain ralph runs per agent, no --live/--monitor overhead.
# --live + --monitor wraps execution in a tmux pane and a stream-json
# tee/FIFO whose file descriptors leak into the post-loop quality-gate
# capture and can hang `worktree_run_quality_gates` indefinitely.
# Use rpc.live.p for streaming output in a single pane, or rpc.int.p for
# the full tmux dashboard.
# Usage: rpc.p 3  -> spawns 3 parallel ralph agents (auto-exit)
# rpc.p N        → batch mode (spawn N parallel agents)
# rpc.p N M      → continuous mode (keep N workers saturated until M attempts;
#                                    per-worker terminal tabs when supported)
eval "${__rp}rpc.p() { $__R --parallel \"\${1:?Usage: ${__rp}rpc.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Continuous mode forcing the single-pane orchestrator (no tabs)
# Usage: rpc.p.notabs N M  -> single-pane continuous mode, N workers, M attempts
eval "${__rp}rpc.p.notabs() { $__R --parallel \"\${1:?Usage: ${__rp}rpc.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpc.p.notabs <N> <M>}\" --no-tabs; }"

# Parallel live-only (streams Claude output in each tab, no tmux split / monitor)
# Usage: rpc.live.p 3  -> spawns 3 parallel ralph agents with streaming output only
eval "${__rp}rpc.live.p() { $__R --live --parallel \"\${1:?Usage: ${__rp}rpc.live.p <number>}\"; }"

# Parallel interactive (spawns N agents in live + tmux monitor mode)
# Note: this creates a 3-pane tmux split (loop + log + monitor) in each tab.
# Prefer rpc.live.p for a single-pane streaming view.
# Usage: rpc.int.p 3  -> spawns 3 parallel ralph agents with live monitor
eval "${__rp}rpc.int.p() { $__R --live --monitor --parallel \"\${1:?Usage: ${__rp}rpc.int.p <number>}\"; }"

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpc.p.b 3       -> 3 parallel agents (quiet, no streaming, auto-exit)
# Usage: rpc.live.p.b 3  -> 3 parallel agents with streaming output (background)
# Usage: rpc.int.p.b 3   -> 3 parallel agents with --live --monitor (background)
eval "${__rp}rpc.p.b() { $__R --parallel-bg \"\${1:?Usage: ${__rp}rpc.p.b <number>}\"; }"
eval "${__rp}rpc.live.p.b() { $__R --live --parallel-bg \"\${1:?Usage: ${__rp}rpc.live.p.b <number>}\"; }"
eval "${__rp}rpc.int.p.b() { $__R --live --monitor --parallel-bg \"\${1:?Usage: ${__rp}rpc.int.p.b <number>}\"; }"

# Combined common workflows
alias "${__rp}rpc.dev=$__R --live --monitor --verbose"
alias "${__rp}rpc.prod=$__R --calls 50 --auto-reset-circuit"
alias "${__rp}rpc.debug=$__R --live --verbose --max-loops 1"

# Setup & Management
alias "${__rp}rpc.monitor=${__R}-monitor"
alias "${__rp}rpc.install=(cd ~/Projects/Tools-Utilities/ai-ralph && ./install.sh)"
alias "${__rp}rpc.uninstall=(cd ~/Projects/Tools-Utilities/ai-ralph && ./uninstall.sh)"

# Planning mode (AI-powered, always uses claude engine)
alias "${__rp}rpc.plan=${__R}-plan"
alias "${__rp}rpc.plan.sup=${__R}-plan --yolo --superpowers"
# Fix plan status (note: rpc.status is agent session status; rpc.plan.s is fix plan status)
alias "${__rp}rpc.plan.s=${__R}-plan --status"

# Model overrides for planning (Claude engine only)
alias "${__rp}rpc.plan.opus=${__R}-plan --model opus"
alias "${__rp}rpc.plan.sonnet=${__R}-plan --model sonnet"

# Thinking depth for planning (prompt preamble + Claude --effort)
alias "${__rp}rpc.plan.hard=${__R}-plan --thinking hard"
alias "${__rp}rpc.plan.ultra=${__R}-plan --thinking ultra"

# Combined: Opus + ultrathink + yolo + superpowers (max-depth planning)
alias "${__rp}rpc.plan.opus.ultra=${__R}-plan --model opus --thinking ultra"
alias "${__rp}rpc.plan.max=${__R}-plan --model opus --thinking ultra --yolo --superpowers"

# Ad-hoc task mode (interactive one-liner to fix_plan entry)
# Usage: rpc.adhoc                        -> prompts for task description
# Usage: rpc.adhoc "Login broken on iOS"  -> inline description
alias "${__rp}rpc.adhoc=${__R}-plan --adhoc"

# Compress fix plan (reduce token consumption, archive original)
alias "${__rp}rpc.compress=${__R}-plan --compress"

# File-based planning (pass a specific MD, JSON, or text file)
# Usage: rpc.plan.file ./docs/requirements.md   -> plan from a specific file
# Usage: rpc.plan.file ./tasks.json             -> plan from a JSON task list
eval "${__rp}rpc.plan.file() { ${__R}-plan --file \"\${1:?Usage: ${__rp}rpc.plan.file <file_path>}\"; }"

# Task-specific execution (pass fix_plan.md task number)
# Usage: rpc.task 3        -> execute task #3
# Usage: rpc.task.int 3    -> interactive (live + monitor) for task #3
eval "${__rp}rpc.task() { $__R --task \"\${1:?Usage: ${__rp}rpc.task <task_number>}\"; }"
eval "${__rp}rpc.task.int() { $__R --live --monitor --task \"\${1:?Usage: ${__rp}rpc.task.int <task_number>}\"; }"

# Workspace mode (multi-repo orchestration)
alias "${__rp}rpc.ws=$__R --workspace"
alias "${__rp}rpc.ws.int=$__R --workspace --live --monitor"
# rpc.ws.p N      → batch workspace (1 batch of N tasks)
# rpc.ws.p N M    → continuous workspace (N concurrent until M attempts; per-worker tabs by default)
eval "${__rp}rpc.ws.p() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpc.ws.p <N> [M]}\" \${2:+\"\$2\"}; }"

# Workspace continuous forcing single-pane (no tabs)
# Usage: rpc.ws.p.notabs N M  -> single-pane workspace continuous
eval "${__rp}rpc.ws.p.notabs() { $__R --workspace --parallel \"\${1:?Usage: ${__rp}rpc.ws.p.notabs <N> <M>}\" \"\${2:?Usage: ${__rp}rpc.ws.p.notabs <N> <M>}\" --no-tabs; }"

# Shared commands (work for all engines)
alias "${__rp}ralph.setup=${__R}-setup"
alias "${__rp}ralph.enable=${__R}-enable"
alias "${__rp}ralph.enable.ci=${__R}-enable-ci"
alias "${__rp}ralph.migrate=${__R}-migrate"
alias "${__rp}ralph.import=${__R}-import"
alias "${__rp}ralph.check.beads=${__R}-check-beads"
alias "${__rp}ralph.plan=${__R}-plan"

alias "${__rp}rp.install=${__rp}rpc.install;${__rp}rpd.install;${__rp}rpx.install"

unset __rp __R
