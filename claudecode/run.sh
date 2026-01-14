#!/bin/bash
# shellcheck shell=bash

# ==============================================================================
# Claude Code Home Assistant Add-on
# Starts ttyd with Claude Code configured for Home Assistant
# ==============================================================================

set -e

# -----------------------------------------------------------------------------
# Configuration Loading
# -----------------------------------------------------------------------------

CONFIG_PATH="/data/options.json"

# Read configuration values using jq
ENABLE_MCP=$(jq -r '.enable_mcp // true' "$CONFIG_PATH")
TERMINAL_FONT_SIZE=$(jq -r '.terminal_font_size // 14' "$CONFIG_PATH")
TERMINAL_THEME=$(jq -r '.terminal_theme // "dark"' "$CONFIG_PATH")
WORKING_DIR=$(jq -r '.working_directory // "/homeassistant"' "$CONFIG_PATH")
SESSION_PERSISTENCE=$(jq -r '.session_persistence // true' "$CONFIG_PATH")

# -----------------------------------------------------------------------------
# Logging Helper
# -----------------------------------------------------------------------------

log_info() {
    echo "[INFO] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

# Verify working directory exists
if [[ ! -d "${WORKING_DIR}" ]]; then
    log_warning "Working directory ${WORKING_DIR} does not exist."
    log_warning "Falling back to /homeassistant"
    WORKING_DIR="/homeassistant"
fi

# Verify supervisor token for hass-mcp
if [[ "${ENABLE_MCP}" == "true" ]] && [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log_warning "Supervisor token not available. hass-mcp may not function correctly."
fi

# -----------------------------------------------------------------------------
# Environment Setup
# -----------------------------------------------------------------------------

export HOME=/root
export TERM=xterm-256color
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Supervisor token for hass-mcp (automatically provided by HA)
export SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN:-}"
export HASS_SERVER="http://supervisor/core"
export HASS_TOKEN="${SUPERVISOR_TOKEN}"

# -----------------------------------------------------------------------------
# MCP Configuration
# -----------------------------------------------------------------------------

setup_mcp_config() {
    log_info "Configuring Claude Code MCP servers..."

    mkdir -p /root/.claude

    if [[ "${ENABLE_MCP}" == "true" ]]; then
        cat > /root/.claude/settings.json << EOF
{
  "mcpServers": {
    "homeassistant": {
      "command": "hass-mcp",
      "env": {
        "HASS_TOKEN": "${SUPERVISOR_TOKEN}",
        "HASS_HOST": "http://supervisor/core"
      }
    }
  }
}
EOF
        log_info "Home Assistant MCP server configured"
    else
        echo '{}' > /root/.claude/settings.json
        log_info "MCP servers disabled"
    fi
}

# -----------------------------------------------------------------------------
# Terminal Theme Configuration
# -----------------------------------------------------------------------------

get_ttyd_theme() {
    if [[ "${TERMINAL_THEME}" == "dark" ]]; then
        echo "background=#1e1e2e,foreground=#cdd6f4,cursor=#f5e0dc"
    else
        echo "background=#eff1f5,foreground=#4c4f69,cursor=#dc8a78"
    fi
}

# -----------------------------------------------------------------------------
# Session Shell Setup
# -----------------------------------------------------------------------------

setup_shell_profile() {
    cat > /root/.bashrc << 'BASHRC'
# Claude Code Home Assistant Add-on Shell

export TERM=xterm-256color
export LANG=C.UTF-8

# Colorful prompt
PS1='\[\033[1;36m\]claude-code\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Helpful aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# Claude Code shortcuts
alias c='claude'
alias cc='claude --continue'

# Home Assistant helpers
alias ha-config='cd /homeassistant'
alias ha-logs='cat /homeassistant/home-assistant.log 2>/dev/null || echo "Log not found"'

BASHRC

    cat > /root/.profile << EOF
# Source bashrc
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Welcome message
clear
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Claude Code for Home Assistant                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Working directory: ${WORKING_DIR}"
EOF

    if [[ "${ENABLE_MCP}" == "true" ]]; then
        cat >> /root/.profile << 'EOF'
echo "  Home Assistant MCP: enabled"
EOF
    fi

    cat >> /root/.profile << 'EOF'
echo ""
echo "  Quick start:"
echo "    claude              - Start interactive session (login on first use)"
echo "    claude "<prompt>"   - Run a single command"
echo "    claude --continue   - Continue last conversation"
echo ""
echo "  Shortcuts:"
echo "    c    = claude"
echo "    cc   = claude --continue"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
EOF
}

# -----------------------------------------------------------------------------
# Main Startup
# -----------------------------------------------------------------------------

main() {
    log_info "========================================"
    log_info "  Claude Code Add-on Starting"
    log_info "========================================"
    log_info ""
    log_info "Configuration:"
    log_info "  MCP enabled: ${ENABLE_MCP}"
    log_info "  Working directory: ${WORKING_DIR}"
    log_info "  Terminal theme: ${TERMINAL_THEME}"
    log_info "  Font size: ${TERMINAL_FONT_SIZE}"
    log_info "  Session persistence: ${SESSION_PERSISTENCE}"
    log_info ""
    log_info "Note: Claude Code will prompt for authentication on first use."
    log_info "Your credentials are stored securely by Claude Code itself."
    log_info ""

    # Setup configurations
    setup_mcp_config
    setup_shell_profile

    # Change to working directory
    cd "${WORKING_DIR}" || cd /homeassistant

    # Build ttyd command
    TTYD_THEME=$(get_ttyd_theme)

    log_info "Starting ttyd web terminal..."

    # Determine shell command based on session persistence
    if [[ "${SESSION_PERSISTENCE}" == "true" ]]; then
        # Use tmux for session persistence
        SHELL_CMD="tmux new-session -A -s claude"
    else
        SHELL_CMD="bash --login"
    fi

    # Start ttyd with configured options
    exec ttyd \
        --port 7681 \
        --writable \
        --ping-interval 30 \
        --max-clients 5 \
        -t "fontSize=${TERMINAL_FONT_SIZE}" \
        -t "fontFamily=Monaco,Consolas,monospace" \
        -t "theme=${TTYD_THEME}" \
        ${SHELL_CMD}
}

# Run main function
main "$@"
