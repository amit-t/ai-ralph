#!/bin/bash

# Ralph for Claude Code - Global Installation Script
set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Command prefix — lets a fork install side-by-side with the stock devkit.
# Resolution order: RALPH_CMD_PREFIX env > .ralph-prefix file at repo root > "".
# Empty (default) => `ralph`, `~/.ralph`. The personal fork ships
# .ralph-prefix=per. => `per.ralph`, `~/.per.ralph`, so it never collides with
# the company devkit's plain `ralph` install.
if [[ -z "${RALPH_CMD_PREFIX+x}" && -f "$SCRIPT_DIR/.ralph-prefix" ]]; then
    RALPH_CMD_PREFIX="$(tr -d '[:space:]' < "$SCRIPT_DIR/.ralph-prefix")"
fi
RALPH_CMD_PREFIX="${RALPH_CMD_PREFIX:-}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
# Home dir is namespaced by prefix: per. -> ~/.per.ralph ; empty -> ~/.ralph
RALPH_HOME="${RALPH_HOME:-$HOME/.${RALPH_CMD_PREFIX}ralph}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
    esac
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message${NC}"
}

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."

    local missing_deps=()
    local os_type
    os_type=$(uname)

    if ! command -v node &> /dev/null && ! command -v npx &> /dev/null; then
        missing_deps+=("Node.js/npm")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi

    # Check for timeout command (platform-specific)
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS: check for gtimeout from coreutils
        if ! command -v gtimeout &> /dev/null && ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils (for timeout command)")
        fi
    else
        # Linux: check for standard timeout command
        if ! command -v timeout &> /dev/null; then
            missing_deps+=("coreutils")
        fi
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies:"
        echo "  Ubuntu/Debian: sudo apt-get install nodejs npm jq git coreutils"
        echo "  macOS: brew install node jq git coreutils"
        echo "  CentOS/RHEL: sudo yum install nodejs npm jq git coreutils"
        exit 1
    fi

    # Additional macOS-specific warning for coreutils
    if [[ "$os_type" == "Darwin" ]]; then
        if command -v gtimeout &> /dev/null; then
            log "INFO" "GNU coreutils detected (gtimeout available)"
        elif command -v timeout &> /dev/null; then
            log "INFO" "timeout command available"
        fi
    fi

    # Check Claude Code CLI availability
    if command -v claude &>/dev/null; then
        log "INFO" "Claude Code CLI found: $(command -v claude)"
    else
        log "WARN" "Claude Code CLI ('claude') not found in PATH."
        log "INFO" "  Install globally: npm install -g @anthropic-ai/claude-code"
        log "INFO" "  Or use npx: set CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\" in .ralphrc"
    fi

    # Check tmux (optional)
    if ! command -v tmux &> /dev/null; then
        log "WARN" "tmux not found. Install for integrated monitoring: apt-get install tmux / brew install tmux"
    fi

    log "SUCCESS" "Dependencies check completed"
}

# Create installation directory
create_install_dirs() {
    log "INFO" "Creating installation directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$RALPH_HOME"
    mkdir -p "$RALPH_HOME/templates"
    mkdir -p "$RALPH_HOME/lib"

    log "SUCCESS" "Directories created: $INSTALL_DIR, $RALPH_HOME"
}

# Install Ralph scripts
install_scripts() {
    log "INFO" "Installing Ralph scripts..."
    
    # Copy templates to Ralph home (dotglob needed for dotfiles like .gitignore)
    shopt -s dotglob
    cp -r "$SCRIPT_DIR/templates/"* "$RALPH_HOME/templates/"
    shopt -u dotglob

    # Copy lib scripts (response_analyzer.sh, circuit_breaker.sh)
    cp -r "$SCRIPT_DIR/lib/"* "$RALPH_HOME/lib/"

    # Command-name prefix and resolved home baked into each wrapper. Heredocs are
    # unquoted so $P / $RALPH_HOME / $RALPH_CMD_PREFIX expand now (install time);
    # runtime vars ($@, $LIBVC, $RALPH_HOME-in-body) are escaped with \.
    local P="$RALPH_CMD_PREFIX"

    # Create the main ralph command
    cat > "$INSTALL_DIR/${P}ralph" << EOF
#!/bin/bash
# Ralph for Claude Code - Main Command

export RALPH_CMD_PREFIX="$RALPH_CMD_PREFIX"
export RALPH_HOME="$RALPH_HOME"
export RALPH_CLONE="$SCRIPT_DIR"

# ── Version-check preamble ──────────────────────────────────────────────────
LIBVC="\${HOME}/.local/share/wb-versioncheck/version-check.sh"
if [[ -f "\$LIBVC" ]]; then
    # shellcheck disable=SC1090
    . "\$LIBVC"
    _wb_versioncheck ralph || true
fi

# Source the actual ralph loop script with global paths
exec "\$RALPH_HOME/ralph_loop.sh" "\$@"
EOF

    # Create ralph-monitor command
    cat > "$INSTALL_DIR/${P}ralph-monitor" << EOF
#!/bin/bash
# Ralph Monitor - Global Command

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_monitor.sh" "\$@"
EOF

    # Create ralph-setup command
    cat > "$INSTALL_DIR/${P}ralph-setup" << EOF
#!/bin/bash
# Ralph Project Setup - Global Command

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/setup.sh" "\$@"
EOF

    # Create ralph-import command
    cat > "$INSTALL_DIR/${P}ralph-import" << EOF
#!/bin/bash
# Ralph PRD Import - Global Command

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_import.sh" "\$@"
EOF

    # Create ralph-migrate command
    cat > "$INSTALL_DIR/${P}ralph-migrate" << EOF
#!/bin/bash
# Ralph Migration - Global Command
# Migrates existing projects from flat structure to .ralph/ subfolder

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/migrate_to_ralph_folder.sh" "\$@"
EOF

    # Create ralph-enable command (interactive wizard)
    cat > "$INSTALL_DIR/${P}ralph-enable" << EOF
#!/bin/bash
# Ralph Enable - Interactive Wizard for Existing Projects
# Adds Ralph configuration to an existing codebase

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_enable.sh" "\$@"
EOF

    # Create ralph-enable-ci command (non-interactive)
    cat > "$INSTALL_DIR/${P}ralph-enable-ci" << EOF
#!/bin/bash
# Ralph Enable CI - Non-Interactive Version for Automation
# Adds Ralph configuration with sensible defaults

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_enable_ci.sh" "\$@"
EOF

    # Create ralph-plan command (Planning Mode)
    cat > "$INSTALL_DIR/${P}ralph-plan" << EOF
#!/bin/bash
# Ralph Planning Mode - PRD-driven fix_plan.md builder
# Scans PRDs, beads, and JSON specs to build/update fix_plan.md

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_plan.sh" "\$@"
EOF

    # Create ralph-check-beads command
    cat > "$INSTALL_DIR/${P}ralph-check-beads" << EOF
#!/bin/bash
# Ralph Check Beads - Verify beads sync functionality
# Diagnoses beads integration issues in Ralph projects

export RALPH_HOME="$RALPH_HOME"

exec "\$RALPH_HOME/ralph_check_beads.sh" "\$@"
EOF

    # Copy actual script files to Ralph home with modifications for global operation
    cp "$SCRIPT_DIR/ralph_monitor.sh" "$RALPH_HOME/"

    # Copy PRD import script to Ralph home
    cp "$SCRIPT_DIR/ralph_import.sh" "$RALPH_HOME/"

    # Copy migration script to Ralph home
    cp "$SCRIPT_DIR/migrate_to_ralph_folder.sh" "$RALPH_HOME/"

    # Copy enable scripts to Ralph home
    cp "$SCRIPT_DIR/ralph_enable.sh" "$RALPH_HOME/"
    cp "$SCRIPT_DIR/ralph_enable_ci.sh" "$RALPH_HOME/"
    
    # Copy planning mode script to Ralph home
    cp "$SCRIPT_DIR/ralph_plan.sh" "$RALPH_HOME/"

    # Copy diagnostic script to Ralph home
    cp "$SCRIPT_DIR/ralph_check_beads.sh" "$RALPH_HOME/"

    # Make all commands executable
    chmod +x "$INSTALL_DIR/${P}ralph"
    chmod +x "$INSTALL_DIR/${P}ralph-monitor"
    chmod +x "$INSTALL_DIR/${P}ralph-setup"
    chmod +x "$INSTALL_DIR/${P}ralph-import"
    chmod +x "$INSTALL_DIR/${P}ralph-migrate"
    chmod +x "$INSTALL_DIR/${P}ralph-enable"
    chmod +x "$INSTALL_DIR/${P}ralph-enable-ci"
    chmod +x "$INSTALL_DIR/${P}ralph-plan"
    chmod +x "$INSTALL_DIR/${P}ralph-check-beads"
    chmod +x "$RALPH_HOME/ralph_monitor.sh"
    chmod +x "$RALPH_HOME/ralph_import.sh"
    chmod +x "$RALPH_HOME/migrate_to_ralph_folder.sh"
    chmod +x "$RALPH_HOME/ralph_enable.sh"
    chmod +x "$RALPH_HOME/ralph_enable_ci.sh"
    chmod +x "$RALPH_HOME/ralph_plan.sh"
    chmod +x "$RALPH_HOME/ralph_check_beads.sh"
    chmod +x "$RALPH_HOME/lib/"*.sh

    log "SUCCESS" "Ralph scripts installed to $INSTALL_DIR"
}

# Install global ralph_loop.sh
install_ralph_loop() {
    log "INFO" "Installing global ralph_loop.sh..."
    
    # Create modified ralph_loop.sh for global operation
    sed \
        -e "s|RALPH_HOME=\"\$HOME/.ralph\"|RALPH_HOME=\"\$HOME/.ralph\"|g" \
        -e "s|\$script_dir/ralph_monitor.sh|\$RALPH_HOME/ralph_monitor.sh|g" \
        -e "s|\$script_dir/ralph_loop.sh|\$RALPH_HOME/ralph_loop.sh|g" \
        "$SCRIPT_DIR/ralph_loop.sh" > "$RALPH_HOME/ralph_loop.sh"
    
    chmod +x "$RALPH_HOME/ralph_loop.sh"
    
    log "SUCCESS" "Global ralph_loop.sh installed"
}

# Install global setup.sh
install_setup() {
    log "INFO" "Installing global setup script..."

    # Copy the actual setup.sh from ralph-claude-code root directory so setup information will be consistent
    if [[ -f "$SCRIPT_DIR/setup.sh" ]]; then
        cp "$SCRIPT_DIR/setup.sh" "$RALPH_HOME/setup.sh"
        chmod +x "$RALPH_HOME/setup.sh"
        log "SUCCESS" "Global setup script installed (copied from $SCRIPT_DIR/setup.sh)"
    else
        log "ERROR" "setup.sh not found in $SCRIPT_DIR"
        return 1
    fi
}

# Install versioning lib + RALPH_CLONE env + ralph.upgrade wrapper
install_versioning() {
    log "INFO" "Installing versioning system..."

    # ── Versioning lib distribution ─────────────────────────────────────────
    local SHARE_DIR="${HOME}/.local/share/wb-versioncheck"
    mkdir -p "$SHARE_DIR"
    if [[ -f "$SHARE_DIR/version-check.sh" ]]; then
        log "INFO" "$SHARE_DIR/version-check.sh already present; leaving in place"
    else
        cp "$SCRIPT_DIR/lib/version-check.sh"        "$SHARE_DIR/"
        cp "$SCRIPT_DIR/lib/bootstrap-detection.sh"  "$SHARE_DIR/"
        chmod 0644 "$SHARE_DIR/version-check.sh" "$SHARE_DIR/bootstrap-detection.sh"
        log "INFO" "Dropped lib: $SHARE_DIR/version-check.sh"
    fi

    # ── Profile env in ~/.zprofile and ~/.bash_profile ──────────────────────
    # Default (unprefixed) install owns the global RALPH_CLONE pointer. A
    # prefixed fork must NOT write it — that would clobber the stock devkit's
    # pointer. The prefixed upgrade wrapper bakes its own clone instead (below).
    # When prefixed, export RALPH_CMD_PREFIX so new shells + ALIASES.sh inherit it.
    local prof
    for prof in "${HOME}/.zprofile" "${HOME}/.bash_profile"; do
        [[ -f "$prof" ]] || continue
        if ! grep -q "EXTERNAL PROJECT ALIASES" "$prof"; then
            printf "\n# === EXTERNAL PROJECT ALIASES ===\n" >> "$prof"
        fi
        if [[ -z "$RALPH_CMD_PREFIX" ]]; then
            local RALPH_LINE="export RALPH_CLONE=\"$SCRIPT_DIR\""
            if ! grep -qF "$RALPH_LINE" "$prof"; then
                printf "%s\n" "$RALPH_LINE" >> "$prof"
                log "INFO" "Wrote RALPH_CLONE to $prof"
            fi
        else
            local PREFIX_LINE="export RALPH_CMD_PREFIX=\"$RALPH_CMD_PREFIX\""
            if ! grep -qF "$PREFIX_LINE" "$prof"; then
                printf "%s\n" "$PREFIX_LINE" >> "$prof"
                log "INFO" "Wrote RALPH_CMD_PREFIX to $prof"
            fi
            # Namespaced clone pointer (e.g. per. -> PER_RALPH_CLONE) so sibling
            # tooling (ai-devkit/ai-workbench resolvers) can locate this fork's
            # clone without clobbering the stock RALPH_CLONE. Mirrors the
            # devkit's ENV_NS convention.
            local ns_base="${RALPH_CMD_PREFIX%%.*}"
            ns_base="${ns_base//[^A-Za-z0-9]/}"
            local NS_VAR; NS_VAR="$(printf '%s' "$ns_base" | tr '[:lower:]' '[:upper:]')_RALPH_CLONE"
            local CLONE_LINE="export ${NS_VAR}=\"$SCRIPT_DIR\""
            if ! grep -qF "$CLONE_LINE" "$prof"; then
                # strip any stale assignment so relocating the clone doesn't stack
                if grep -q "^export ${NS_VAR}=" "$prof"; then
                    local tmp_p; tmp_p="$(mktemp)"
                    grep -v "^export ${NS_VAR}=" "$prof" > "$tmp_p" && mv "$tmp_p" "$prof"
                fi
                printf "%s\n" "$CLONE_LINE" >> "$prof"
                log "INFO" "Wrote ${NS_VAR} to $prof"
            fi
        fi
    done

    # ── ${P}ralph.upgrade wrapper (NOT a symlink — see SCRIPT_DIR-resolution bug) ──
    # Prefixed wrapper forces RALPH_CLONE to its own clone so it never follows a
    # stale global RALPH_CLONE pointing at the stock devkit.
    local P="$RALPH_CMD_PREFIX"
    if [[ -z "$P" ]]; then
        cat > "$INSTALL_DIR/${P}ralph.upgrade" <<EOF
#!/bin/bash
# Ralph Upgrade - Global Command
exec "$SCRIPT_DIR/ralph-upgrade.sh" "\$@"
EOF
    else
        cat > "$INSTALL_DIR/${P}ralph.upgrade" <<EOF
#!/bin/bash
# Ralph Upgrade - Global Command (prefixed: $P)
exec env RALPH_CLONE="$SCRIPT_DIR" RALPH_CMD_PREFIX="$RALPH_CMD_PREFIX" "$SCRIPT_DIR/ralph-upgrade.sh" "\$@"
EOF
    fi
    chmod +x "$INSTALL_DIR/${P}ralph.upgrade"
    chmod +x "$SCRIPT_DIR/ralph-upgrade.sh"
    log "SUCCESS" "Installed: ${P}ralph.upgrade -> $INSTALL_DIR/${P}ralph.upgrade"
}

# Check PATH
check_path() {
    log "INFO" "Checking PATH configuration..."
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log "WARN" "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add this to your ~/.bashrc, ~/.zshrc, or ~/.profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        echo "Then run: source ~/.bashrc (or restart your terminal)"
        echo ""
    else
        log "SUCCESS" "$INSTALL_DIR is already in PATH"
    fi
}

# Main installation
main() {
    echo "🚀 Installing Ralph for Claude Code globally..."
    echo ""
    
    check_dependencies
    create_install_dirs
    install_scripts
    install_ralph_loop
    install_setup
    install_versioning
    check_path
    
    echo ""
    log "SUCCESS" "🎉 Ralph for Claude Code installed successfully!"
    echo ""
    local P="$RALPH_CMD_PREFIX"
    [[ -n "$P" ]] && echo "Command prefix: '$P' (home: $RALPH_HOME)" && echo ""
    echo "Global commands available:"
    echo "  ${P}ralph --monitor        # Start Ralph with integrated monitoring"
    echo "  ${P}ralph --help           # Show Ralph options"
    echo "  ${P}ralph-setup my-project # Create new Ralph project"
    echo "  ${P}ralph-enable           # Enable Ralph in existing project (interactive)"
    echo "  ${P}ralph-enable-ci        # Enable Ralph in existing project (non-interactive)"
    echo "  ${P}ralph-import prd.md    # Convert PRD to Ralph project"
    echo "  ${P}ralph-migrate          # Migrate existing project to .ralph/ structure"
    echo "  ${P}ralph-monitor          # Manual monitoring dashboard"
    echo "  ${P}ralph-plan             # Planning mode - build fix_plan from PRDs & beads"
    echo "  ${P}ralph-check-beads      # Verify beads integration (diagnostic)"
    echo "  ${P}ralph.upgrade          # Pull latest ai-ralph and reinstall"
    echo ""
    echo "Quick start:"
    echo "  1. ${P}ralph-setup my-awesome-project"
    echo "  2. cd my-awesome-project"
    echo "  3. # Edit .ralph/PROMPT.md with your requirements"
    echo "  4. ${P}ralph --monitor"
    echo ""
    
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "⚠️  Don't forget to add $INSTALL_DIR to your PATH (see above)"
    fi
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "INFO" "Uninstalling Ralph for Claude Code..."
        P="$RALPH_CMD_PREFIX"
        rm -f "$INSTALL_DIR/${P}ralph" "$INSTALL_DIR/${P}ralph-monitor" "$INSTALL_DIR/${P}ralph-setup" "$INSTALL_DIR/${P}ralph-import" "$INSTALL_DIR/${P}ralph-migrate" "$INSTALL_DIR/${P}ralph-enable" "$INSTALL_DIR/${P}ralph-enable-ci" "$INSTALL_DIR/${P}ralph-plan" "$INSTALL_DIR/${P}ralph-check-beads" "$INSTALL_DIR/${P}ralph.upgrade"
        rm -rf "$RALPH_HOME"
        log "SUCCESS" "Ralph for Claude Code uninstalled"
        ;;
    --help|-h)
        echo "Ralph for Claude Code Installation"
        echo ""
        echo "Usage: $0 [install|uninstall]"
        echo ""
        echo "Commands:"
        echo "  install    Install Ralph globally (default)"
        echo "  uninstall  Remove Ralph installation"
        echo "  --help     Show this help"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac