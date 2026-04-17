# ============================================================================
# Ralph for Claude Code (rpc) - Bash Aliases
# ============================================================================
# Add these to your ~/.bashrc, ~/.zshrc, or ~/.bash_aliases
# Then run: source ~/.bashrc (or equivalent)

# Basic execution
alias rpc='ralph'
alias rpc.live='ralph --live'
alias rpc.monitor='ralph --monitor'
alias rpc.verbose='ralph --verbose'
alias rpc.hitl='ralph --live --monitor'

# Session management
alias rpc.continue='ralph --continue'
alias rpc.reset='ralph --reset-session'
alias rpc.status='ralph --status'

# Circuit breaker
alias rpc.cb.reset='ralph --reset-circuit'
alias rpc.cb.status='ralph --circuit-status'
alias rpc.cb.auto='ralph --auto-reset-circuit'

# Configuration variants
alias rpc.fast='ralph --calls 200'
alias rpc.slow='ralph --calls 50'
alias rpc.test='ralph --max-loops 1'
alias rpc.5='ralph --max-loops 5'
alias rpc.10='ralph --max-loops 10'

# Model selection
alias rpc.opus='ralph --model opus'
alias rpc.sonnet='ralph --model sonnet'

# Output formats
alias rpc.json='ralph --output-format json'
alias rpc.text='ralph --output-format text'

# Worktree management
alias rpc.nowt='ralph --no-worktree'
alias rpc.wt.squash='ralph --merge-strategy squash'
alias rpc.wt.merge='ralph --merge-strategy merge'
alias rpc.wt.rebase='ralph --merge-strategy rebase'
alias rpc.wt.nogate='ralph --quality-gates none'
alias rpc.wt.full='ralph --live --monitor --merge-strategy squash --quality-gates auto'

# Quality gate fix mode (retry loop to fix failing gates)
alias rpc.qg='ralph --qg'

# Interactive mode
alias rpc.int='ralph --live --monitor'

# Parallel non-interactive (spawns N agents: iTerm2 tabs or IDE terminal tabs)
# Usage: rpc.p 3  -> spawns 3 parallel ralph agents (no live/monitor)
rpc.p() { ralph --parallel "${1:?Usage: rpc.p <number>}"; }

# Parallel live-only (streams Claude output in each tab, no tmux split / monitor)
# Usage: rpc.live.p 3  -> spawns 3 parallel ralph agents with streaming output only
rpc.live.p() { ralph --live --parallel "${1:?Usage: rpc.live.p <number>}"; }

# Parallel interactive (spawns N agents with --live --monitor in new tabs)
# Note: this creates a 3-pane tmux split (loop + log + monitor) in each tab.
# Prefer rpc.live.p for a single-pane streaming view.
# Usage: rpc.int.p 3  -> spawns 3 parallel ralph agents in interactive mode
rpc.int.p() { ralph --live --monitor --parallel "${1:?Usage: rpc.int.p <number>}"; }

# Parallel background mode (spawns N agents as background processes in any terminal)
# Usage: rpc.p.b 3       -> 3 parallel agents (quiet, no streaming)
# Usage: rpc.live.p.b 3  -> 3 parallel agents with streaming output (background)
# Usage: rpc.int.p.b 3   -> 3 parallel agents with --live --monitor (background)
rpc.p.b() { ralph --parallel-bg "${1:?Usage: rpc.p.b <number>}"; }
rpc.live.p.b() { ralph --live --parallel-bg "${1:?Usage: rpc.live.p.b <number>}"; }
rpc.int.p.b() { ralph --live --monitor --parallel-bg "${1:?Usage: rpc.int.p.b <number>}"; }

# Combined common workflows
alias rpc.dev='ralph --live --monitor --verbose'
alias rpc.prod='ralph --calls 50 --auto-reset-circuit'
alias rpc.debug='ralph --live --verbose --max-loops 1'

# Setup & Management
alias rpc.monitor='ralph-monitor'
alias rpc.install='(cd ~/Projects/Tools-Utilities/ai-ralph && ./install.sh)'
alias rpc.uninstall='(cd ~/Projects/Tools-Utilities/ai-ralph && ./uninstall.sh)'

# Planning mode (AI-powered, always uses claude engine)
alias rpc.plan='ralph-plan'
alias rpc.plan.sup='ralph-plan --yolo --superpowers'
# Fix plan status (note: rpc.status is agent session status; rpc.plan.s is fix plan status)
alias rpc.plan.s='ralph-plan --status'

# Ad-hoc task mode (interactive one-liner to fix_plan entry)
# Usage: rpc.adhoc                        -> prompts for task description
# Usage: rpc.adhoc "Login broken on iOS"  -> inline description
alias rpc.adhoc='ralph-plan --adhoc'

# Compress fix plan (reduce token consumption, archive original)
alias rpc.compress='ralph-plan --compress'

# File-based planning (pass a specific MD, JSON, or text file)
# Usage: rpc.plan.file ./docs/requirements.md   -> plan from a specific file
# Usage: rpc.plan.file ./tasks.json             -> plan from a JSON task list
rpc.plan.file() { ralph-plan --file "${1:?Usage: rpc.plan.file <file_path>}"; }

# Task-specific execution (pass fix_plan.md task number)
# Usage: rpc.task 3        -> execute task #3
# Usage: rpc.task.int 3    -> interactive (live + monitor) for task #3
rpc.task() { ralph --task "${1:?Usage: rpc.task <task_number>}"; }
rpc.task.int() { ralph --live --monitor --task "${1:?Usage: rpc.task.int <task_number>}"; }

# Shared commands (work for all engines)
alias ralph.setup='ralph-setup'
alias ralph.enable='ralph-enable'
alias ralph.enable.ci='ralph-enable-ci'
alias ralph.migrate='ralph-migrate'
alias ralph.import='ralph-import'
alias ralph.check.beads='ralph-check-beads'
alias ralph.plan='ralph-plan'

alias rp.install="rpc.install;rpd.install;rpx.install"
