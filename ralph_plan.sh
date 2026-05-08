#!/bin/bash

# Ralph Planning Mode - AI-powered PRD-driven fix_plan.md builder
# Uses AI (Claude/Codex/Devin) to analyze PRDs and build fix_plan.md
# Does NOT execute tasks - planning only
#
# Usage: ralph_plan.sh [options]
#   --prd-dir <dir>    Directory containing PRD files (interactive if omitted)
#   --pm-os <dir>      PM OS directory (auto-detected if omitted)
#   --doe-os <dir>     DoE OS directory (auto-detected if omitted)
#   --engine <name>    AI engine: claude (default), codex, devin
#   --help             Show help
#
# Version: 0.4.0

set -e

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
# shellcheck source=lib/workspace_manager.sh
source "$SCRIPT_DIR/lib/workspace_manager.sh"
# shellcheck source=lib/workspace_plan.sh
source "$SCRIPT_DIR/lib/workspace_plan.sh"

# Configuration
RALPH_DIR=".ralph"
CONSTITUTION_FILE="$RALPH_DIR/constitution.md"
FIX_PLAN_FILE="$RALPH_DIR/fix_plan.md"
PROMPT_PLAN_FILE="$RALPH_DIR/PROMPT_PLAN.md"
LOG_DIR="$RALPH_DIR/logs"

# Planning mode settings
PRD_DIR=""
PM_OS_DIR=""
DOE_OS_DIR=""
STATUS_MODE=false
ADHOC_MODE=false
ADHOC_DESCRIPTION=""
COMPRESS_MODE=false
FILE_MODE=false
FILE_PATH=""
WORKSPACE_MODE=false
WORKSPACE_REPOS_FILTER=""
WORKSPACE_DRY_RUN=false
WORKSPACE_PARALLEL_PLAN=""    # raw user-provided value (CLI flag or env var)
WORKSPACE_PARALLEL_PLAN_RESOLVED=""  # validated effective value (post engine-default lookup)

# Engine selection: claude (default), codex, devin
ENGINE="claude"

# Engine CLI commands
CLAUDE_CMD="claude"
CODEX_CMD="codex"
DEVIN_CMD="devin"

# Claude-specific: allowed tools for --allowedTools flag
declare -a CLAUDE_ALLOWED_TOOLS=('Read' 'Write' 'Glob' 'Grep')

# Yolo mode: --dangerously-skip-permissions (bypasses ALL permission checks)
YOLO_MODE=false

# Superpowers plugin: obra/superpowers Claude plugin
SUPERPOWERS=false
SUPERPOWERS_PLUGIN_DIR="${HOME}/.claude/plugins/repos/superpowers"
SUPERPOWERS_REPO="https://github.com/obra/superpowers"

# Model override (Claude + Devin engines; e.g. "opus", "sonnet",
# "claude-opus-4-7[1m]", "claude-sonnet-4"). Passes --model <value> through
# to the engine CLI. Codex is ignored with a WARN. Empty = engine default.
MODEL=""

# Thinking depth for planning prompt. One of:
#   normal - no-op (default)
#   hard   - prepends "Think hard..." preamble; Claude engine also gets --effort high
#   ultra  - prepends "ultrathink" preamble; Claude engine also gets --effort max
# The preamble is prepended to the planning prompt for every engine;
# the --effort flag is Claude-only.
THINKING_LEVEL="normal"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""

    case $level in
        "INFO")    color=$BLUE ;;
        "WARN")    color=$YELLOW ;;
        "ERROR")   color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "PLAN")    color=$PURPLE ;;
    esac

    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_DIR/ralph_plan.log"
}

show_help() {
    cat << 'HELPEOF'
Ralph Planning Mode - AI-powered fix_plan.md builder

Usage: ralph-plan [options]

Options:
    --prd-dir <dir>    Directory containing PRD files
                       (interactive prompt if omitted, remembers in constitution.md)
    --pm-os <dir>      PM OS directory (contains PRDs, analyses, specs in outputs/)
    --doe-os <dir>     DoE OS directory (contains TDDs, tech specs in outputs/)
    --engine <name>    AI engine: claude (default), codex, devin
    --model <name>     Model override for the planning session (Claude + Devin).
                       Passes --model <name> through to the engine CLI.
                       Examples: opus, sonnet, claude-opus-4-7, claude-sonnet-4
                       Codex engine ignores this flag with a WARN.
    --thinking <level> Planning thinking depth. One of:
                         normal (default)
                         hard   - "Think hard" preamble + --effort high (Claude)
                         ultra  - "ultrathink" preamble + --effort max  (Claude)
                       The preamble is prepended to the prompt for every engine;
                       the --effort flag is Claude-only.
    --yolo             Yolo mode: --dangerously-skip-permissions (Claude only)
    --superpowers      Load obra/superpowers plugin (Claude only, auto-cloned)
    --sup              Alias for --superpowers
    --status           Show AI-powered fix plan status and insights (no planning runs)
    --adhoc [desc]     Ad-hoc task mode: describe a bug/task, AI creates fix_plan entry
                       If desc is omitted, prompts interactively
    --compress         Compress fix_plan.md to reduce token consumption
                       Archives current plan, then AI rewrites it compactly
                       Completed items collapsed, descriptions shortened, IDs preserved
    --file <path>      File-based planning: pass a specific MD, JSON, or text file
                       AI reads the document, analyzes the codebase, and generates
                       a prioritized fix_plan.md from the file's content
    --workspace        Multi-repo workspace planning mode.
                       Run from a workspace root (no .git at cwd, one or more
                       child git repos, .ralph/fix_plan.md present).
                       Drives the selected engine per repo, captures task output,
                       and merges into .ralph/fix_plan.md with state preservation
                       for - [~] (in-progress) and - [x] (completed) lines.
    --repos <list>     Comma-separated repo allowlist for --workspace mode.
                       Unlisted repos are untouched. Example: --repos svc-a,svc-b
    --parallel-plan N  --workspace only: run up to N per-repo plan workers
                       concurrently. N=1 ⇒ sequential (V1, default). N>1 fans out
                       engine calls; section ordering in the merged fix_plan.md
                       stays in REPO list order via buffer-then-merge.
                       Engine defaults: claude=4, devin=2, codex=2 (opt-in via
                       RALPH_PLAN_PARALLEL_USE_DEFAULTS=1).
    --dry-run          --workspace only: run the engine per repo but do NOT write
                       .ralph/fix_plan.md. Summary still emitted.
    -h, --help         Show this help

Examples:
    ralph-plan                                  # Interactive PRD directory, Claude engine
    ralph-plan --prd-dir ./docs/prds            # Specify PRD directory
    ralph-plan --engine codex                   # Use Codex for analysis
    ralph-plan --engine devin                   # Use Devin for analysis
    ralph-plan --prd-dir ./specs --engine codex # Codex on specific directory
    ralph-plan --yolo --superpowers             # Claude yolo + superpowers (rpc.plan.sup)
    ralph-plan --model opus                     # Plan with Claude Opus (rpc.plan.opus)
    ralph-plan --thinking ultra                 # ultrathink preamble + --effort max (rpc.plan.ultra)
    ralph-plan --model opus --thinking ultra \
               --yolo --superpowers             # Opus + ultrathink + yolo + superpowers
    ralph-plan --pm-os ../product/my-pm-os --doe-os ../engineering/my-doe-os
    ralph-plan --status                         # AI fix plan status (Claude, default)
    ralph-plan --engine codex --status          # AI fix plan status via Codex
    ralph-plan --adhoc                          # Interactive ad-hoc task (prompts for desc)
    ralph-plan --adhoc "Login broken on mobile" # Ad-hoc with inline description
    ralph-plan --engine devin --adhoc           # Ad-hoc via Devin engine
    ralph-plan --compress                       # Compress fix plan (Claude, default)
    ralph-plan --engine codex --compress        # Compress fix plan via Codex
    ralph-plan --file ./docs/requirements.md    # Plan from a specific markdown file
    ralph-plan --file ./tasks.json              # Plan from a JSON task list
    ralph-plan --file ./notes.txt               # Plan from plain text notes
    ralph-plan --engine devin --file spec.md    # File-based planning via Devin
    ralph-plan --workspace                      # Multi-repo plan (default engine)
    ralph-plan --workspace --engine devin       # Workspace plan via Devin
    ralph-plan --workspace --repos svc-a,svc-b  # Plan only two repos
    ralph-plan --workspace --dry-run            # Plan but do not write fix_plan.md

PM-OS / DoE-OS Auto-Detection:
    When Ralph is not enabled in the current directory (no .ralph/ folder),
    ralph-plan will search for sibling and cousin directories matching
    *-pm-os and *-doe-os naming patterns. If found, it will:

    1. Auto-bootstrap .ralph/ in the current (app) directory
    2. Gather PRDs and outputs from PM OS (outputs/prds/, outputs/analyses/, etc.)
    3. Gather tech specs and TDDs from DoE OS (outputs/tdds/, outputs/specs/, etc.)
    4. Run AI planning to build .ralph/fix_plan.md from all sources

    Expected directory layout:
      .
      ├── engineering/
      │   ├── myapp/              ← Run ralph-plan here
      │   └── myapp-doe-os/      ← Auto-detected DoE OS
      └── product/
          └── myapp-pm-os/       ← Auto-detected PM OS

What it does:
    1. Detects PM-OS and DoE-OS directories (or asks for PRD directory)
    2. Sends PRDs + tech specs to the AI engine for deep analysis
    3. AI reads all source files and extracts requirements
    4. AI builds/updates .ralph/fix_plan.md with prioritized tasks
    5. AI updates .ralph/constitution.md with project context

Planning mode does NOT execute tasks - it only builds the plan.

HELPEOF
}

# =============================================================================
# CONSTITUTION MANAGEMENT
# =============================================================================

# Read PRD directory from constitution.md if it exists
read_constitution_prd_dir() {
    if [[ ! -f "$CONSTITUTION_FILE" ]]; then
        echo ""
        return
    fi

    # Extract PRD directory from constitution
    local prd_dir
    prd_dir=$(grep -E '^\- \*\*PRD Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null \
        | sed 's/.*: //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Filter out template placeholders
    if [[ "$prd_dir" == *"configured by"* ]] || [[ "$prd_dir" == *"[configured"* ]] || [[ -z "$prd_dir" ]]; then
        echo ""
        return
    fi

    echo "$prd_dir"
}

# Update constitution.md with PRD directory and planning results
update_constitution() {
    local prd_dir=$1
    local prd_files_found=$2
    local beads_count=$3
    local json_count=$4
    local tasks_generated=$5
    local timestamp
    timestamp=$(get_iso_timestamp)

    # Create constitution from template if it doesn't exist
    if [[ ! -f "$CONSTITUTION_FILE" ]]; then
        local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
        if [[ -f "$ralph_home/templates/constitution.md" ]]; then
            cp "$ralph_home/templates/constitution.md" "$CONSTITUTION_FILE"
        elif [[ -f "$SCRIPT_DIR/templates/constitution.md" ]]; then
            cp "$SCRIPT_DIR/templates/constitution.md" "$CONSTITUTION_FILE"
        else
            # Inline minimal template
            cat > "$CONSTITUTION_FILE" << 'CONSTEOF'
# Ralph Project Constitution

> This file is Ralph's project memory. Updated by Planning Mode.

## Project Identity
- **Project Name**: unknown
- **Project Type**: unknown
- **Created**: unknown
- **Last Planned**: never

## PRD Configuration
- **PRD Directory**: not configured
- **PM-OS Directory**: not configured
- **DoE-OS Directory**: not configured
- **PRD Files Found**: none

## Architecture Decisions

## Technology Stack

## Constraints & Non-Functional Requirements

## Conventions

## Planning History
| Date | PRDs Scanned | Beads Found | Tasks Generated | Notes |
|------|-------------|-------------|-----------------|-------|
CONSTEOF
        fi
    fi

    # Update PRD Directory
    if grep -q '^\- \*\*PRD Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*PRD Directory\*\*:.*|- **PRD Directory**: $prd_dir|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update PM-OS Directory
    if [[ -n "$PM_OS_DIR" ]] && grep -q '^\- \*\*PM-OS Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*PM-OS Directory\*\*:.*|- **PM-OS Directory**: $PM_OS_DIR|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update DoE-OS Directory
    if [[ -n "$DOE_OS_DIR" ]] && grep -q '^\- \*\*DoE-OS Directory\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*DoE-OS Directory\*\*:.*|- **DoE-OS Directory**: $DOE_OS_DIR|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update PRD Files Found
    if grep -q '^\- \*\*PRD Files Found\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*PRD Files Found\*\*:.*|- **PRD Files Found**: $prd_files_found|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Update Last Planned timestamp
    if grep -q '^\- \*\*Last Planned\*\*:' "$CONSTITUTION_FILE" 2>/dev/null; then
        sed -i.bak "s|^\- \*\*Last Planned\*\*:.*|- **Last Planned**: $timestamp|" "$CONSTITUTION_FILE"
        rm -f "$CONSTITUTION_FILE.bak"
    fi

    # Append to planning history table
    local history_line="| $timestamp | $prd_files_found | $beads_count | $tasks_generated | Planning mode run |"
    echo "$history_line" >> "$CONSTITUTION_FILE"

    log "SUCCESS" "Updated constitution.md"
}

# =============================================================================
# PM-OS / DOE-OS AUTO-DETECTION
# =============================================================================

# Search for directories matching a glob pattern in siblings and cousins
# Usage: find_os_dir <pattern>
# Searches: siblings (../*pattern), cousins (../../*/*pattern)
find_os_dir() {
    local pattern=$1
    local found=""

    # Search siblings first (same parent directory)
    for dir in ../*${pattern}; do
        if [[ -d "$dir" ]]; then
            found="$(cd "$dir" && pwd)"
            echo "$found"
            return 0
        fi
    done

    # Search cousins (parent's siblings' children)
    for dir in ../../*/*${pattern}; do
        if [[ -d "$dir" ]]; then
            found="$(cd "$dir" && pwd)"
            echo "$found"
            return 0
        fi
    done

    return 1
}

# Detect pm-os and doe-os directories automatically
# Sets PM_OS_DIR and DOE_OS_DIR if found
detect_pm_doe_dirs() {
    log "INFO" "Searching for PM-OS and DoE-OS directories..."

    if [[ -z "$PM_OS_DIR" ]]; then
        PM_OS_DIR=$(find_os_dir "-pm-os" 2>/dev/null || true)
    fi

    if [[ -z "$DOE_OS_DIR" ]]; then
        DOE_OS_DIR=$(find_os_dir "-doe-os" 2>/dev/null || true)
    fi

    if [[ -n "$PM_OS_DIR" ]]; then
        log "SUCCESS" "Found PM-OS: $PM_OS_DIR"
    else
        log "WARN" "No *-pm-os directory found"
    fi

    if [[ -n "$DOE_OS_DIR" ]]; then
        log "SUCCESS" "Found DoE-OS: $DOE_OS_DIR"
    else
        log "WARN" "No *-doe-os directory found"
    fi

    # Return success if at least one was found
    [[ -n "$PM_OS_DIR" ]] || [[ -n "$DOE_OS_DIR" ]]
}

# Collect all relevant source files from PM-OS and DoE-OS directories
# Outputs newline-separated list of absolute file paths
collect_pm_doe_sources() {
    local sources=""

    # PM-OS sources: PRDs, analyses, specs, decisions
    if [[ -n "$PM_OS_DIR" ]]; then
        local pm_dirs=("outputs/prds" "outputs/analyses" "outputs/specs" "outputs/decisions" "outputs/roadmaps" "outputs/research-synthesis")
        for subdir in "${pm_dirs[@]}"; do
            if [[ -d "$PM_OS_DIR/$subdir" ]]; then
                local files
                files=$(find "$PM_OS_DIR/$subdir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null || true)
                if [[ -n "$files" ]]; then
                    sources+="$files"$'\n'
                fi
            fi
        done
    fi

    # DoE-OS sources: TDDs, specs, PRDs (solution reviews), decisions, analyses
    if [[ -n "$DOE_OS_DIR" ]]; then
        local doe_dirs=("outputs/tdds" "outputs/specs" "outputs/prds" "outputs/decisions" "outputs/analyses" "outputs/technical-research" "outputs/reviews")
        for subdir in "${doe_dirs[@]}"; do
            if [[ -d "$DOE_OS_DIR/$subdir" ]]; then
                local files
                files=$(find "$DOE_OS_DIR/$subdir" -maxdepth 2 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null || true)
                if [[ -n "$files" ]]; then
                    sources+="$files"$'\n'
                fi
            fi
        done
    fi

    # Remove trailing newlines and empty lines
    echo "$sources" | sed '/^$/d' | sort -u
}

# =============================================================================
# INTERACTIVE PRD DIRECTORY SELECTION
# =============================================================================

prompt_prd_directory() {
    echo ""
    echo -e "${PURPLE}=== Ralph Planning Mode ===${NC}"
    echo ""

    # Check if we have a remembered directory
    local remembered_dir
    remembered_dir=$(read_constitution_prd_dir)

    if [[ -n "$remembered_dir" ]] && [[ -d "$remembered_dir" ]]; then
        echo -e "Previously configured PRD directory: ${CYAN}$remembered_dir${NC}"
        echo -n "Use this directory? [Y/n]: "
        read -r use_prev
        if [[ -z "$use_prev" ]] || [[ "$use_prev" =~ ^[Yy] ]]; then
            PRD_DIR="$remembered_dir"
            return
        fi
    fi

    # Scan for likely PRD directories
    echo "Scanning project for directories that may contain PRDs..."
    echo ""

    local candidates=()
    local candidate_names=()

    # Check common PRD directory names
    local common_dirs=("docs" "prds" "specs" "requirements" "docs/prds" "docs/specs" "docs/requirements" ".ralph/specs")
    for dir in "${common_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local md_count
            md_count=$(find "$dir" -maxdepth 2 -name "*.md" -o -name "*.txt" -o -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
            if [[ $md_count -gt 0 ]]; then
                candidates+=("$dir")
                candidate_names+=("$dir ($md_count files)")
            fi
        fi
    done

    # Also check for any .md files in project root
    local root_md_count
    root_md_count=$(find . -maxdepth 1 -name "*.md" -not -name "README.md" -not -name "CHANGELOG.md" -not -name "CONTRIBUTING.md" -not -name "LICENSE*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ $root_md_count -gt 0 ]]; then
        candidates+=(".")
        candidate_names+=("Project root ($root_md_count .md files)")
    fi

    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "Found potential PRD directories:"
        echo ""
        for i in "${!candidate_names[@]}"; do
            echo -e "  ${GREEN}$((i + 1)))${NC} ${candidate_names[$i]}"
        done
        echo -e "  ${GREEN}$((${#candidates[@]} + 1)))${NC} Enter custom path"
        echo ""
        echo -n "Select directory [1-$((${#candidates[@]} + 1))]: "
        read -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#candidates[@]} ]]; then
            PRD_DIR="${candidates[$((selection - 1))]}"
        else
            echo -n "Enter PRD directory path: "
            read -r custom_dir
            PRD_DIR="$custom_dir"
        fi
    else
        echo "No common PRD directories found."
        echo -n "Enter PRD directory path: "
        read -r custom_dir
        PRD_DIR="$custom_dir"
    fi

    # Validate
    if [[ ! -d "$PRD_DIR" ]]; then
        log "ERROR" "Directory does not exist: $PRD_DIR"
        exit 1
    fi

    echo ""
    log "INFO" "Using PRD directory: $PRD_DIR"
}

# =============================================================================
# SUPERPOWERS PLUGIN MANAGEMENT
# =============================================================================

# Ensure the superpowers plugin is cloned locally
# Uses shallow clone for speed; cached for subsequent runs
ensure_superpowers_plugin() {
    if [[ -d "$SUPERPOWERS_PLUGIN_DIR" ]]; then
        log "INFO" "Superpowers plugin found: $SUPERPOWERS_PLUGIN_DIR"
        return 0
    fi

    log "INFO" "Cloning superpowers plugin (one-time)..."
    mkdir -p "$(dirname "$SUPERPOWERS_PLUGIN_DIR")"
    if git clone --depth 1 "$SUPERPOWERS_REPO" "$SUPERPOWERS_PLUGIN_DIR" 2>/dev/null; then
        log "SUCCESS" "Superpowers plugin cloned to $SUPERPOWERS_PLUGIN_DIR"
        return 0
    else
        log "ERROR" "Failed to clone superpowers plugin from $SUPERPOWERS_REPO"
        return 1
    fi
}

# =============================================================================
# AI PLANNING
# =============================================================================

run_ai_planning() {
    local prd_dir=$1

    # Determine CLI command based on engine
    local cli_cmd=""
    case "$ENGINE" in
        claude) cli_cmd="$CLAUDE_CMD" ;;
        codex)  cli_cmd="$CODEX_CMD" ;;
        devin)  cli_cmd="$DEVIN_CMD" ;;
        *)
            log "ERROR" "Unknown engine: $ENGINE (expected: claude, codex, devin)"
            return 1
            ;;
    esac

    if ! command -v "$cli_cmd" &>/dev/null 2>&1; then
        log "ERROR" "$ENGINE CLI ('$cli_cmd') not found. Install it first."
        return 1
    fi

    log "PLAN" "Running AI planning with $ENGINE ($cli_cmd)..."

    # Ensure planning prompt exists
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local prompt_source=""
    if [[ -f "$PROMPT_PLAN_FILE" ]]; then
        prompt_source="$PROMPT_PLAN_FILE"
    elif [[ -f "$ralph_home/templates/PROMPT_PLAN.md" ]]; then
        prompt_source="$ralph_home/templates/PROMPT_PLAN.md"
        cp "$prompt_source" "$PROMPT_PLAN_FILE"
    elif [[ -f "$SCRIPT_DIR/templates/PROMPT_PLAN.md" ]]; then
        prompt_source="$SCRIPT_DIR/templates/PROMPT_PLAN.md"
        cp "$prompt_source" "$PROMPT_PLAN_FILE"
    fi

    if [[ -z "$prompt_source" ]] && [[ ! -f "$PROMPT_PLAN_FILE" ]]; then
        log "ERROR" "Planning prompt template not found (PROMPT_PLAN.md). Run install.sh first."
        return 1
    fi

    # Build context
    local context="Project Root: $(pwd)"

    if [[ -n "$prd_dir" ]]; then
        context+="\nPRD Directory: $prd_dir"
        local prd_list
        prd_list=$(find "$prd_dir" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | sort)
        if [[ -n "$prd_list" ]]; then
            context+="\n\nPRD Files Found:\n$prd_list"
        fi
    fi

    # PM-OS / DoE-OS sources
    if [[ -n "$PM_OS_DIR" ]] || [[ -n "$DOE_OS_DIR" ]]; then
        local pm_doe_sources
        pm_doe_sources=$(collect_pm_doe_sources)
        local source_count
        source_count=$(echo "$pm_doe_sources" | grep -c '.' 2>/dev/null || echo "0")

        if [[ -n "$PM_OS_DIR" ]]; then
            context+="\n\nPM-OS Directory: $PM_OS_DIR"
        fi
        if [[ -n "$DOE_OS_DIR" ]]; then
            context+="\nDoE-OS Directory: $DOE_OS_DIR"
        fi
        if [[ -n "$pm_doe_sources" ]]; then
            context+="\n\nPM-OS / DoE-OS Source Files ($source_count files):\n$pm_doe_sources"
        fi
    fi

    # Check for beads if available
    if [[ -d ".beads" ]] && command -v bd &>/dev/null; then
        local beads_count
        beads_count=$(bd list --json --status open 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        context+="\n\nBeads: $beads_count open tasks in .beads/"
    fi

    # Build prompt file
    local prompt_file="$RALPH_DIR/.plan_prompt_input.md"
    {
        case "$THINKING_LEVEL" in
            hard)
                echo "Think hard about every decision below before acting. Prefer correctness and specificity over speed."
                echo ""
                ;;
            ultra)
                echo "ultrathink"
                echo ""
                echo "Ultra-plan every decision below. Be exhaustive and precise. Prefer correctness over brevity."
                echo ""
                ;;
        esac
        cat "$PROMPT_PLAN_FILE"
        echo ""
        echo "---"
        echo ""
        echo "## Planning Context"
        echo -e "$context"
        echo ""
        echo "## Instructions"
        if [[ -n "$PM_OS_DIR" ]] || [[ -n "$DOE_OS_DIR" ]]; then
            echo "Analyze ALL source files listed above from PM-OS and DoE-OS directories."
            echo "Read each PRD, tech spec, TDD, analysis, and decision document."
            echo "Cross-reference product requirements (PM-OS) with technical specifications (DoE-OS)."
            echo "Extract actionable engineering tasks and generate a comprehensive fix_plan.md."
        else
            echo "Analyze the PRD files listed above. Read each one, extract requirements, and generate the fix_plan.md content."
        fi
        echo "Write directly to .ralph/fix_plan.md and .ralph/constitution.md."
    } > "$prompt_file"

    local cli_exit_code=0
    local prompt_content
    prompt_content=$(cat "$prompt_file")

    log "PLAN" "Prompt: $(wc -c < "$prompt_file" | tr -d ' ') bytes"

    # Interactive invocation with bypass permissions — no --print/-p, no stdout redirect
    # AI runs in full TUI mode so user can watch it work
    case "$ENGINE" in
        claude)
            # Build Claude-specific flags based on mode
            local -a claude_flags=()

            if [[ "$YOLO_MODE" == true ]]; then
                claude_flags+=("--dangerously-skip-permissions")
                log "PLAN" "Yolo mode: --dangerously-skip-permissions"
            else
                claude_flags+=("--permission-mode" "bypassPermissions")
                claude_flags+=("--allowedTools" "${CLAUDE_ALLOWED_TOOLS[@]}")
            fi

            if [[ "$SUPERPOWERS" == true ]]; then
                if ! ensure_superpowers_plugin; then
                    log "ERROR" "Cannot proceed without superpowers plugin"
                    return 1
                fi
                claude_flags+=("--plugin-dir" "$SUPERPOWERS_PLUGIN_DIR")
                log "PLAN" "Superpowers plugin: $SUPERPOWERS_PLUGIN_DIR"
            fi

            if [[ -n "$MODEL" ]]; then
                claude_flags+=("--model" "$MODEL")
                log "PLAN" "Model override: $MODEL"
            fi

            case "$THINKING_LEVEL" in
                hard)
                    claude_flags+=("--effort" "high")
                    log "PLAN" "Thinking level: hard (--effort high)"
                    ;;
                ultra)
                    claude_flags+=("--effort" "max")
                    log "PLAN" "Thinking level: ultra (--effort max + ultrathink preamble)"
                    ;;
            esac

            log "PLAN" "Launching: $cli_cmd (interactive) ${claude_flags[*]}"
            if "$cli_cmd" "${claude_flags[@]}" "$prompt_content"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        codex)
            if [[ -n "$MODEL" ]]; then
                log "WARN" "--model is Claude+Devin only for ralph-plan; ignored for codex engine"
            fi
            local -a codex_flags=(
                "--dangerously-bypass-approvals-and-sandbox"
                "--"
            )
            log "PLAN" "Launching: $cli_cmd (interactive) --dangerously-bypass-approvals-and-sandbox"
            if "$cli_cmd" "${codex_flags[@]}" "$prompt_content"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
        devin)
            local -a devin_flags=("--permission-mode" "dangerous")
            if [[ -n "$MODEL" ]]; then
                devin_flags+=("--model" "$MODEL")
                log "PLAN" "Model override: $MODEL"
            fi
            devin_flags+=("--prompt-file" "$prompt_file")
            log "PLAN" "Launching: $cli_cmd (interactive) ${devin_flags[*]}"
            if "$cli_cmd" "${devin_flags[@]}"; then
                cli_exit_code=0
            else
                cli_exit_code=$?
            fi
            ;;
    esac

    log "PLAN" "$ENGINE CLI exited with code: $cli_exit_code"

    # Clean up prompt input
    rm -f "$prompt_file"

    # Check if the AI wrote fix_plan.md
    if [[ $cli_exit_code -eq 0 ]] && [[ -f "$FIX_PLAN_FILE" ]]; then
        log "SUCCESS" "AI planning completed - fix_plan.md updated"
        return 0
    fi

    log "ERROR" "AI planning failed (exit code: $cli_exit_code). Check $ENGINE CLI output above."
    return 1
}

# =============================================================================
# WORKSPACE PLANNING (--workspace)
# =============================================================================

# Resolve --parallel-plan N. Resolution order:
#   1. CLI flag (already in $WORKSPACE_PARALLEL_PLAN if set)
#   2. Env var RALPH_PLAN_PARALLEL
#   3. Per-engine default (only when RALPH_PLAN_PARALLEL_USE_DEFAULTS=1)
#   4. Hard fallback: 1 (sequential, V1)
# Caps at $repo_count.
# Sets WORKSPACE_PARALLEL_PLAN_RESOLVED.
_resolve_parallel_plan() {
    local repo_count="$1"
    local engine="$2"
    local n=""

    if [[ -n "$WORKSPACE_PARALLEL_PLAN" ]]; then
        n="$WORKSPACE_PARALLEL_PLAN"
    elif [[ -n "${RALPH_PLAN_PARALLEL:-}" ]]; then
        if ! [[ "$RALPH_PLAN_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$RALPH_PLAN_PARALLEL" -lt 1 ]]; then
            log "ERROR" "RALPH_PLAN_PARALLEL must be a positive integer (got: $RALPH_PLAN_PARALLEL)"
            return 1
        fi
        n="$RALPH_PLAN_PARALLEL"
    elif [[ "${RALPH_PLAN_PARALLEL_USE_DEFAULTS:-0}" == "1" ]]; then
        case "$engine" in
            claude) n=4 ;;
            devin)  n=2 ;;
            codex)  n=2 ;;
            *)      n=1 ;;
        esac
    else
        n=1
    fi

    # Cap at repo_count
    if [[ "$n" -gt "$repo_count" ]]; then
        n="$repo_count"
    fi
    if [[ "$n" -lt 1 ]]; then
        n=1
    fi
    WORKSPACE_PARALLEL_PLAN_RESOLVED="$n"
    return 0
}

# _workspace_plan_orphan_cleanup — sweep .plan-tmp/<token>/ dirs whose owning
# PID is not alive. Token format: "<pid>_<epoch_ms>". Silent.
_workspace_plan_orphan_cleanup() {
    local tmp_root="$1"
    [[ -d "$tmp_root" ]] || return 0
    local entry pid_part
    for entry in "$tmp_root"/*/; do
        [[ -d "$entry" ]] || continue
        pid_part="$(basename "$entry")"
        pid_part="${pid_part%%_*}"
        [[ "$pid_part" =~ ^[0-9]+$ ]] || continue
        if ! kill -0 "$pid_part" 2>/dev/null; then
            rm -rf "$entry" 2>/dev/null || true
        fi
    done
}

# _workspace_plan_step_a — Run Step A (context+prompt+engine+parse) for one repo.
# Output: $work_dir/<repo>.{context,prompt,out,parsed,tasks,ambig,cross}.md/txt
# Returns 0 on success, 1 on failure (engine error or no context). When the repo
# has no ai/ or .ralph/specs/ context, returns 2 (skipped) so callers can
# distinguish skip-vs-fail.
_workspace_plan_step_a() {
    local repo_name="$1"
    local ws="$2"
    local work_dir="$3"

    local repo_path="$ws/$repo_name"
    if [[ ! -d "$repo_path/.git" ]]; then
        log "WARN" "Skipping $repo_name: not a git repo"
        return 1
    fi

    local context_file="$work_dir/${repo_name}.context.md"
    if ! workspace_plan_collect_repo_context "$repo_path" > "$context_file"; then
        log "WARN" "[$repo_name] no ai/ or .ralph/specs/ context — skipping"
        rm -f "$context_file"
        return 2
    fi
    local context
    context=$(cat "$context_file")

    local prompt_file="$work_dir/${repo_name}.prompt.md"
    local output_file
    output_file="$(cd "$work_dir" && pwd)/${repo_name}.out.md"
    local repo_path_abs
    repo_path_abs="$(cd "$repo_path" && pwd)"

    workspace_plan_build_prompt "$prompt_file" "$repo_name" "$repo_path_abs" "$output_file" "$THINKING_LEVEL" "$context"

    log "PLAN" "[$repo_name] invoking $ENGINE..."
    if ! workspace_plan_run_engine "$ENGINE" "$MODEL" "$THINKING_LEVEL" \
        "$repo_name" "$repo_path_abs" "$output_file" "$prompt_file" "$YOLO_MODE"; then
        log "ERROR" "[$repo_name] engine failed — skipping merge"
        return 1
    fi

    local parsed_file="$work_dir/${repo_name}.parsed.txt"
    workspace_plan_parse_output "$output_file" > "$parsed_file"

    local tasks_file="$work_dir/${repo_name}.tasks.txt"
    local ambig_file="$work_dir/${repo_name}.ambig.txt"
    local cross_file="$work_dir/${repo_name}.cross.txt"
    grep '^TASK|'  "$parsed_file" 2>/dev/null | sed 's/^TASK|//'  > "$tasks_file" || true
    grep '^AMBIG|' "$parsed_file" 2>/dev/null | sed 's/^AMBIG|//' > "$ambig_file" || true
    grep '^CROSS|' "$parsed_file" 2>/dev/null | sed 's/^CROSS|//' > "$cross_file" || true
    return 0
}

run_workspace_plan() {
    local ws="."

    # Preflight
    if ! workspace_plan_preflight "$ws"; then
        exit 1
    fi

    # Engine availability check (skipped when using mock hook for tests)
    if [[ -z "${RALPH_PLAN_WS_MOCK_DIR:-}" ]]; then
        local cli_cmd=""
        case "$ENGINE" in
            claude) cli_cmd="$CLAUDE_CMD" ;;
            codex)  cli_cmd="$CODEX_CMD" ;;
            devin)  cli_cmd="$DEVIN_CMD" ;;
            *)
                log "ERROR" "Unknown engine: $ENGINE (expected: claude, codex, devin)"
                return 1
                ;;
        esac
        if ! command -v "$cli_cmd" &>/dev/null; then
            log "ERROR" "$ENGINE CLI ('$cli_cmd') not found. Install it first."
            return 1
        fi
    fi

    local fix_plan="$ws/.ralph/fix_plan.md"
    local work_dir="$ws/.ralph/.workspace_plan"
    mkdir -p "$work_dir"

    # Discover + filter repos
    local all_repos
    if ! all_repos=$(discover_workspace_repos "$ws"); then
        log "ERROR" "No git repos found in workspace"
        return 1
    fi

    local repos
    repos=$(workspace_plan_filter_repos "$all_repos" "$WORKSPACE_REPOS_FILTER")
    if [[ -z "$repos" ]]; then
        log "ERROR" "No repos to plan (check --repos filter)"
        return 1
    fi

    local repo_count
    repo_count=$(echo "$repos" | grep -c .)
    log "PLAN" "Workspace plan: $repo_count repo(s)"

    # Resolve parallelism (CLI > env > engine-default-opt-in > 1)
    if ! _resolve_parallel_plan "$repo_count" "$ENGINE"; then
        return 1
    fi
    local par_n="$WORKSPACE_PARALLEL_PLAN_RESOLVED"

    # Per-run isolation under .plan-tmp/<token>/. Sequential N=1 keeps the V1
    # flat $work_dir layout (byte-identical output guarantee). Parallel N>1
    # gets a token-scoped subdir so concurrent ralph-plan invocations cannot
    # collide. On startup we also sweep orphans from prior crashed runs.
    local plan_tmp_root="$ws/.ralph/.plan-tmp"
    _workspace_plan_orphan_cleanup "$plan_tmp_root"
    local run_token=""
    if [[ "$par_n" -gt 1 ]]; then
        local epoch_ms
        epoch_ms="$(date +%s%N 2>/dev/null || date +%s)000000000"
        epoch_ms="${epoch_ms:0:13}"
        run_token="$$_${epoch_ms}"
        work_dir="$plan_tmp_root/$run_token"
        mkdir -p "$work_dir"
        log "PLAN" "[parallel-plan N=$par_n] token=$run_token tmp=$work_dir"
    fi

    local start_ts
    start_ts=$(date +%s)

    # Per-repo accumulators
    local total_new=0
    local total_preserved=0
    local total_inprog=0
    local total_completed=0
    local total_cross=0
    local total_ambig=0
    local -a planned_repos=()
    local -a ambig_lines=()
    local -a skipped_no_context=()
    # Tracks the result of Step A per repo as newline-separated "repo|status"
    # pairs (bash 3.2 has no associative arrays).
    local step_a_status=""

    local cross_all_file="$work_dir/_cross_all.txt"
    : > "$cross_all_file"

    # Helper to record Step A status for one repo.
    _record_step_a() {
        local _r="$1"; local _rc="$2"
        case "$_rc" in
            0) step_a_status="${step_a_status}${_r}|ok"$'\n' ;;
            2) step_a_status="${step_a_status}${_r}|skip"$'\n'; skipped_no_context+=("$_r") ;;
            *) step_a_status="${step_a_status}${_r}|fail"$'\n' ;;
        esac
    }

    # ── Step A: per-repo engine + parse ──────────────────────────────
    if [[ "$par_n" -le 1 ]]; then
        # Sequential path — unchanged from V1 (byte-identical when no flag).
        while IFS= read -r repo_name; do
            [[ -z "$repo_name" ]] && continue
            local rc=0
            _workspace_plan_step_a "$repo_name" "$ws" "$work_dir" || rc=$?
            _record_step_a "$repo_name" "$rc"
        done <<< "$repos"
    else
        # Parallel path — bounded worker pool of size par_n. Bash 3.2 has no
        # associative arrays, so we use parallel index arrays for pid↔repo.
        local -a active_pids=()
        local -a active_repos=()
        local repo_name rc_file
        while IFS= read -r repo_name; do
            [[ -z "$repo_name" ]] && continue
            # Throttle: wait until pool has capacity
            while [[ "${#active_pids[@]}" -ge "$par_n" ]]; do
                local -a still_pids=()
                local -a still_repos=()
                local i
                for i in "${!active_pids[@]}"; do
                    local pid="${active_pids[$i]}"
                    local r="${active_repos[$i]}"
                    if kill -0 "$pid" 2>/dev/null; then
                        still_pids+=("$pid")
                        still_repos+=("$r")
                    else
                        wait "$pid" 2>/dev/null || true
                        local st_rc
                        st_rc=$(cat "$work_dir/${r}.rc" 2>/dev/null || echo 1)
                        _record_step_a "$r" "$st_rc"
                    fi
                done
                active_pids=("${still_pids[@]}")
                active_repos=("${still_repos[@]}")
                [[ "${#active_pids[@]}" -ge "$par_n" ]] && sleep 1
            done
            rc_file="$work_dir/${repo_name}.rc"
            (
                _workspace_plan_step_a "$repo_name" "$ws" "$work_dir"
                echo "$?" > "$rc_file"
            ) &
            active_pids+=("$!")
            active_repos+=("$repo_name")
        done <<< "$repos"

        # Drain remaining workers
        local i
        for i in "${!active_pids[@]}"; do
            local pid="${active_pids[$i]}"
            local r="${active_repos[$i]}"
            wait "$pid" 2>/dev/null || true
            local st_rc
            st_rc=$(cat "$work_dir/${r}.rc" 2>/dev/null || echo 1)
            _record_step_a "$r" "$st_rc"
        done
    fi

    # ── Step B: merge in REPO list order (serial, with advisory lock when parallel) ──
    # Use flock(1) when present (Linux), fall back to mkdir-as-lock on macOS.
    local lock_file="$ws/.ralph/.plan.lock"
    local lock_dir="$ws/.ralph/.plan.lock.d"
    local lock_held=false
    local lock_kind=""
    if [[ "$par_n" -gt 1 && "$WORKSPACE_DRY_RUN" != true ]]; then
        if command -v flock >/dev/null 2>&1; then
            exec 200>"$lock_file"
            if ! flock -w 30 200; then
                log "ERROR" "another ralph-plan is already merging fix_plan.md, try again in a moment"
                exec 200>&-
                return 1
            fi
            lock_held=true
            lock_kind="flock"
        else
            local _waited=0
            while ! mkdir "$lock_dir" 2>/dev/null; do
                _waited=$((_waited + 1))
                if [[ $_waited -gt 30 ]]; then
                    log "ERROR" "another ralph-plan is already merging fix_plan.md, try again in a moment"
                    return 1
                fi
                sleep 1
            done
            lock_held=true
            lock_kind="mkdir"
        fi
    fi

    # Step A status lookup (newline-separated "repo|status" pairs).
    _step_a_status_for() {
        local _r="$1"
        local line
        line=$(echo "$step_a_status" | grep "^${_r}|" | head -1)
        if [[ -z "$line" ]]; then
            echo "fail"
            return
        fi
        echo "${line#*|}"
    }

    local merge_failed=false
    while IFS= read -r repo_name; do
        [[ -z "$repo_name" ]] && continue
        local status
        status=$(_step_a_status_for "$repo_name")
        case "$status" in
            skip|fail) continue ;;
        esac

        local tasks_file="$work_dir/${repo_name}.tasks.txt"
        local ambig_file="$work_dir/${repo_name}.ambig.txt"
        local cross_file="$work_dir/${repo_name}.cross.txt"

        local merge_stats=""
        if [[ "$WORKSPACE_DRY_RUN" == true ]]; then
            local dry_new
            dry_new=$(wc -l < "$tasks_file" | tr -d ' ')
            merge_stats="$dry_new 0 0 0"
        else
            if ! merge_stats=$(workspace_plan_merge_repo_section "$fix_plan" "$repo_name" "$tasks_file"); then
                log "ERROR" "[$repo_name] merge failed"
                merge_failed=true
                continue
            fi
        fi

        local r_new r_preserved r_inprog r_completed
        read -r r_new r_preserved r_inprog r_completed <<< "$merge_stats"
        total_new=$((total_new + r_new))
        total_preserved=$((total_preserved + r_preserved))
        total_inprog=$((total_inprog + r_inprog))
        total_completed=$((total_completed + r_completed))

        # Collect ambiguities for summary
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            ambig_lines+=("$repo_name: $a")
            total_ambig=$((total_ambig + 1))
        done < "$ambig_file"

        if [[ -s "$cross_file" ]]; then
            cat "$cross_file" >> "$cross_all_file"
        fi

        planned_repos+=("$repo_name")
        log "SUCCESS" "[$repo_name] merged: ${r_new} new, ${r_preserved} preserved"
    done <<< "$repos"

    # Release lock if acquired
    if [[ "$lock_held" == true ]]; then
        case "$lock_kind" in
            flock)
                flock -u 200 2>/dev/null || true
                exec 200>&-
                ;;
            mkdir)
                rmdir "$lock_dir" 2>/dev/null || true
                ;;
        esac
    fi

    # Merge cross-repo tasks (unless dry-run)
    if [[ -s "$cross_all_file" ]]; then
        if [[ "$WORKSPACE_DRY_RUN" == true ]]; then
            total_cross=$(wc -l < "$cross_all_file" | tr -d ' ')
        else
            total_cross=$(workspace_plan_append_cross_repo "$fix_plan" "$cross_all_file")
        fi
    fi

    local end_ts
    end_ts=$(date +%s)
    local elapsed=$((end_ts - start_ts))
    local elapsed_min=$((elapsed / 60))
    local elapsed_sec=$((elapsed % 60))

    # Summary
    echo ""
    echo "Workspace Plan Summary"
    echo ""
    local repos_joined
    repos_joined=$(printf '%s, ' "${planned_repos[@]}" | sed 's/, $//')
    echo "Repos planned:       ${#planned_repos[@]} (${repos_joined})"
    echo "New tasks:           ${total_new}"
    echo "Preserved tasks:     ${total_preserved} (${total_inprog} in-progress, ${total_completed} completed)"
    echo "Cross-repo tasks:    ${total_cross}"
    echo "Ambiguities flagged: ${total_ambig}"
    if [[ ${total_ambig} -gt 0 ]]; then
        local a
        for a in "${ambig_lines[@]}"; do
            echo "  - $a"
        done
    fi
    if [[ ${#skipped_no_context[@]} -gt 0 ]]; then
        echo "Skipped (no context): ${#skipped_no_context[@]} (${skipped_no_context[*]})"
    fi
    echo "Engine:              ${ENGINE}"
    echo "Elapsed:             ${elapsed_min}m ${elapsed_sec}s"
    if [[ "$WORKSPACE_DRY_RUN" == true ]]; then
        echo "Mode:                DRY-RUN (no fix_plan.md writes)"
    fi
    if [[ "$par_n" -gt 1 ]]; then
        echo "Parallel-plan:       ${par_n} workers"
    fi
    echo ""

    # Cleanup parallel-mode token dir on success. On failure preserve for
    # debugging.
    local _worker_failed=false
    if echo "$step_a_status" | grep -q '|fail$'; then
        _worker_failed=true
    fi
    if [[ -n "$run_token" && "$merge_failed" == false ]]; then
        if [[ "$_worker_failed" == false ]]; then
            rm -rf "$plan_tmp_root/$run_token" 2>/dev/null || true
        else
            log "WARN" "[parallel-plan] tmp preserved for debug: $plan_tmp_root/$run_token"
        fi
    fi

    # Exit non-zero if any worker failed (matches doc §4 contract).
    if [[ "$_worker_failed" == true || "$merge_failed" == true ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prd-dir)
                PRD_DIR="$2"
                shift 2
                ;;
            --pm-os)
                PM_OS_DIR="$2"
                shift 2
                ;;
            --doe-os)
                DOE_OS_DIR="$2"
                shift 2
                ;;
            --engine)
                ENGINE="$2"
                shift 2
                ;;
            --model)
                MODEL="$2"
                shift 2
                ;;
            --thinking)
                THINKING_LEVEL="$2"
                case "$THINKING_LEVEL" in
                    normal|hard|ultra) ;;
                    *)
                        log "ERROR" "Invalid --thinking value: $THINKING_LEVEL (expected: normal, hard, ultra)"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --status)
                STATUS_MODE=true
                shift
                ;;
            --adhoc)
                ADHOC_MODE=true
                # Optional inline description: consume next arg if it doesn't look like a flag
                if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                    ADHOC_DESCRIPTION="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --compress)
                COMPRESS_MODE=true
                shift
                ;;
            --file)
                FILE_MODE=true
                if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                    FILE_PATH="$2"
                    shift 2
                else
                    log "ERROR" "--file requires a file path argument"
                    show_help
                    exit 1
                fi
                ;;
            --workspace)
                WORKSPACE_MODE=true
                shift
                ;;
            --repos)
                WORKSPACE_REPOS_FILTER="$2"
                shift 2
                ;;
            --parallel-plan)
                if [[ -z "$2" ]]; then
                    log "ERROR" "--parallel-plan requires a positive integer"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log "ERROR" "--parallel-plan must be a positive integer"
                    exit 1
                fi
                if [[ "$2" -lt 1 ]]; then
                    log "ERROR" "--parallel-plan must be >= 1"
                    exit 1
                fi
                WORKSPACE_PARALLEL_PLAN="$2"
                shift 2
                ;;
            --dry-run)
                WORKSPACE_DRY_RUN=true
                shift
                ;;
            --yolo)
                YOLO_MODE=true
                shift
                ;;
            --superpowers|--sup)
                SUPERPOWERS=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    # --parallel-plan is workspace-only; reject outside --workspace.
    if [[ -n "$WORKSPACE_PARALLEL_PLAN" && "$WORKSPACE_MODE" != true ]]; then
        log "ERROR" "--parallel-plan only applies to --workspace mode"
        exit 1
    fi

    # Status mode: AI-powered fix plan analysis -- exits before any planning
    # Note: ralph_plan.sh has `set -e`. Using `|| exit $?` disarms set -e for this
    # line so we can capture the exit code explicitly rather than relying on set -e
    # to exit on non-zero (which would work but is fragile if set -e is ever changed).
    if [[ "$STATUS_MODE" == true ]]; then
        source "$SCRIPT_DIR/lib/fix_plan_status.sh"
        show_fix_plan_status "$ENGINE" || exit $?
        exit 0
    fi

    # Ad-hoc mode: interactive one-liner to fix_plan entry -- exits before any planning
    if [[ "$ADHOC_MODE" == true ]]; then
        source "$SCRIPT_DIR/lib/adhoc_task.sh"
        run_adhoc_task "$ENGINE" "$ADHOC_DESCRIPTION" "$YOLO_MODE" "$SUPERPOWERS" "$SUPERPOWERS_PLUGIN_DIR" || exit $?
        exit 0
    fi

    # Compress mode: shrink fix_plan.md to reduce token consumption -- exits before any planning
    if [[ "$COMPRESS_MODE" == true ]]; then
        source "$SCRIPT_DIR/lib/compress_plan.sh"
        run_compress_plan "$ENGINE" "$YOLO_MODE" "$SUPERPOWERS" "$SUPERPOWERS_PLUGIN_DIR" || exit $?
        exit 0
    fi

    # File mode: plan from a specific MD, JSON, or text file -- exits before any planning
    if [[ "$FILE_MODE" == true ]]; then
        source "$SCRIPT_DIR/lib/file_plan.sh"
        run_file_plan "$ENGINE" "$FILE_PATH" "$YOLO_MODE" "$SUPERPOWERS" "$SUPERPOWERS_PLUGIN_DIR" || exit $?
        exit 0
    fi

    # Workspace mode: multi-repo planning -- exits before any single-repo planning
    if [[ "$WORKSPACE_MODE" == true ]]; then
        run_workspace_plan || exit $?
        exit 0
    fi

    echo ""
    echo -e "${PURPLE}Ralph Planning Mode${NC}"
    echo -e "${PURPLE}===================${NC}"
    echo ""

    local ralph_was_enabled=true
    local use_pm_doe=false

    # Validate explicit pm-os/doe-os paths if provided
    if [[ -n "$PM_OS_DIR" ]] && [[ ! -d "$PM_OS_DIR" ]]; then
        log "ERROR" "PM-OS directory does not exist: $PM_OS_DIR"
        exit 1
    fi
    if [[ -n "$DOE_OS_DIR" ]] && [[ ! -d "$DOE_OS_DIR" ]]; then
        log "ERROR" "DoE-OS directory does not exist: $DOE_OS_DIR"
        exit 1
    fi

    # Check if Ralph is already enabled in this directory
    if [[ ! -d "$RALPH_DIR" ]]; then
        ralph_was_enabled=false
        log "INFO" "Ralph not enabled in current directory (no .ralph/ folder)"

        # If pm-os/doe-os explicitly provided or auto-detectable, use that flow
        if [[ -n "$PM_OS_DIR" ]] || [[ -n "$DOE_OS_DIR" ]]; then
            use_pm_doe=true
        elif [[ -z "$PRD_DIR" ]] && detect_pm_doe_dirs; then
            use_pm_doe=true
        fi

        if [[ "$use_pm_doe" == true ]]; then
            log "INFO" "Auto-bootstrapping .ralph/ in $(pwd)"
            mkdir -p "$RALPH_DIR" "$LOG_DIR"
        fi
    else
        # Ralph is enabled — still use pm-os/doe-os if explicitly provided or detectable
        if [[ -n "$PM_OS_DIR" ]] || [[ -n "$DOE_OS_DIR" ]]; then
            use_pm_doe=true
        elif [[ -z "$PRD_DIR" ]] && detect_pm_doe_dirs; then
            use_pm_doe=true
        fi
    fi

    # Ensure .ralph directory exists (for all flows)
    mkdir -p "$RALPH_DIR" "$LOG_DIR"

    if [[ "$use_pm_doe" == true ]]; then
        # PM-OS / DoE-OS flow: AI-only planning from external sources
        local source_files
        source_files=$(collect_pm_doe_sources)
        local source_count
        source_count=$(echo "$source_files" | grep -c '.' 2>/dev/null || echo "0")

        echo ""
        log "PLAN" "Planning from PM-OS / DoE-OS sources ($source_count files)"
        [[ -n "$PM_OS_DIR" ]] && log "INFO" "  PM-OS:  $PM_OS_DIR"
        [[ -n "$DOE_OS_DIR" ]] && log "INFO" "  DoE-OS: $DOE_OS_DIR"
        echo ""

        if [[ "$source_count" -eq 0 ]]; then
            log "ERROR" "No source files found in PM-OS/DoE-OS directories"
            exit 1
        fi

        # Run AI planning (prd_dir can be empty for pm-os/doe-os flow)
        if run_ai_planning "${PRD_DIR:-}"; then
            local prd_label="pm-os/doe-os"
            update_constitution "${PM_OS_DIR:-}+${DOE_OS_DIR:-}" "$source_count files" "0" "0" "AI-generated from PM-OS/DoE-OS"
            echo ""
            log "SUCCESS" "Planning complete!"
            echo ""
            echo "Next steps:"
            echo "  1. Review .ralph/fix_plan.md"
            echo "  2. Review .ralph/constitution.md"
            echo "  3. Run 'ralph --monitor' to start execution"
            echo ""
            echo "Re-run planning anytime with: ralph-plan"
        else
            log "ERROR" "AI planning failed. Ensure your $ENGINE CLI is installed and authenticated."
            exit 1
        fi
    else
        # Standard flow: PRD directory based planning
        if [[ -z "$PRD_DIR" ]]; then
            prompt_prd_directory
        else
            if [[ ! -d "$PRD_DIR" ]]; then
                log "ERROR" "PRD directory does not exist: $PRD_DIR"
                exit 1
            fi
            log "INFO" "Using PRD directory: $PRD_DIR"
        fi

        if run_ai_planning "$PRD_DIR"; then
            local prd_count
            prd_count=$(find "$PRD_DIR" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | wc -l | tr -d ' ')
            update_constitution "$PRD_DIR" "$prd_count files" "0" "0" "AI-generated"
            echo ""
            log "SUCCESS" "Planning complete!"
            echo ""
            echo "Next steps:"
            echo "  1. Review .ralph/fix_plan.md"
            echo "  2. Review .ralph/constitution.md"
            echo "  3. Run 'ralph --monitor' to start execution"
            echo ""
            echo "Re-run planning anytime with: ralph-plan"
        else
            log "ERROR" "AI planning failed. Ensure your $ENGINE CLI is installed and authenticated."
            exit 1
        fi
    fi
}

main "$@"
