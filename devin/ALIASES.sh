# ============================================================================
# Ralph for Devin (rpd) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpd='ralph-devin'
alias rpd.live='ralph-devin --live'
alias rpd.monitor='ralph-devin --monitor'
alias rpd.verbose='ralph-devin --verbose'
alias rpd.hitl='ralph-devin --live --monitor'

# Session management
alias rpd.continue='ralph-devin --continue'
alias rpd.reset='ralph-devin --reset-session'
alias rpd.status='ralph-devin --status'

# Circuit breaker
alias rpd.cb.reset='ralph-devin --reset-circuit'
alias rpd.cb.status='ralph-devin --circuit-status'
alias rpd.cb.auto='ralph-devin --auto-reset-circuit'

# Configuration variants
alias rpd.fast='ralph-devin --calls 200'
alias rpd.slow='ralph-devin --calls 50'

# Model selection
alias rpd.opus='ralph-devin --model opus'
alias rpd.sonnet='ralph-devin --model sonnet'
alias rpd.swe='ralph-devin --model swe'
alias rpd.gpt='ralph-devin --model gpt'

# Permission modes
alias rpd.safe='ralph-devin --permission-mode auto'
alias rpd.danger='ralph-devin --permission-mode dangerous'

# Worktree management
alias rpd.nowt='ralph-devin --no-worktree'
alias rpd.wt.squash='ralph-devin --merge-strategy squash'
alias rpd.wt.merge='ralph-devin --merge-strategy merge'
alias rpd.wt.rebase='ralph-devin --merge-strategy rebase'
alias rpd.wt.nogate='ralph-devin --quality-gates none'

# Quality gate fix mode (retry loop to fix failing gates)
alias rpd.qg='ralph-devin --qg'

# Interactive (TUI) mode - Devin runs without -p flag, shows its TUI
alias rpd.int='ralph-devin --no-devin-auto-exit'
alias rpd.wt.int='ralph-devin --no-devin-auto-exit --live --monitor'

# Parallel non-interactive (spawns N agents: iTerm2 tabs or IDE terminal tabs)
# Usage: rpd.p 3  -> spawns 3 parallel devin agents (auto-exit)
rpd.p() { ralph-devin --parallel "${1:?Usage: rpd.p <number>}"; }

# Parallel interactive (spawns N agents in TUI mode)
# Usage: rpd.int.p 3  -> spawns 3 parallel devin agents in interactive mode
rpd.int.p() { ralph-devin --no-devin-auto-exit --parallel "${1:?Usage: rpd.int.p <number>}"; }

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpd.p.b 3  -> spawns 3 parallel devin agents in background
rpd.p.b() { ralph-devin --parallel-bg "${1:?Usage: rpd.p.b <number>}"; }
rpd.int.p.b() { ralph-devin --no-devin-auto-exit --parallel-bg "${1:?Usage: rpd.int.p.b <number>}"; }

# Combined common workflows
alias rpd.dev='ralph-devin --live --monitor --verbose'
alias rpd.prod='ralph-devin --calls 50 --auto-reset-circuit --permission-mode dangerous'
alias rpd.wt.full='ralph-devin --live --monitor --merge-strategy squash --quality-gates auto'

# Setup & Management
alias rpd.monitor='ralph-monitor-devin'
alias rpd.install='(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./install_devin.sh)'
alias rpd.uninstall='(cd ~/Projects/Tools-Utilities/ai-ralph/devin && ./uninstall_devin.sh)'
alias rpd.enable='ralph-devin-enable'

# Planning mode (AI-powered, uses devin engine)
alias rpd.plan='ralph-plan --engine devin'
# Fix plan status (note: rpd.status is agent session status; rpd.plan.s is fix plan status)
alias rpd.plan.s='ralph-plan --engine devin --status'

# Ad-hoc task mode (interactive one-liner to fix_plan entry, uses devin engine)
# Usage: rpd.adhoc                        -> prompts for task description
# Usage: rpd.adhoc "Login broken on iOS"  -> inline description
alias rpd.adhoc='ralph-plan --engine devin --adhoc'

# Compress fix plan (reduce token consumption, archive original, uses devin engine)
alias rpd.compress='ralph-plan --engine devin --compress'

# File-based planning (pass a specific MD, JSON, or text file, uses devin engine)
# Usage: rpd.file ./docs/requirements.md   -> plan from a specific file
# Usage: rpd.file ./tasks.json             -> plan from a JSON task list
rpd.file() { ralph-plan --engine devin --file "${1:?Usage: rpd.file <file_path>}"; }

# Task-specific execution (pass fix_plan.md task number)
# Usage: rpd.task 3        -> non-interactive, execute task #3
# Usage: rpd.task.int 3    -> interactive TUI, execute task #3
rpd.task() { ralph-devin --task "${1:?Usage: rpd.task <task_number>}"; }
rpd.task.int() { ralph-devin --no-devin-auto-exit --task "${1:?Usage: rpd.task.int <task_number>}"; }
