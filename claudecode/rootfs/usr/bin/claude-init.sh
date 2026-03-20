#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Claude Code Add-on: Initialization
# Runs once at startup as root. Sets up persistence, MCP, environment.
# ==============================================================================

bashio::log.info "Initializing Claude Code add-on..."

# --- Export HA environment ---
export HA_TOKEN="${SUPERVISOR_TOKEN:-}"
export HA_URL="http://supervisor/core"

# Write env vars so the ttyd service (and its children) can access them
printf '%s' "${SUPERVISOR_TOKEN:-}" > /var/run/s6/container_environment/HA_TOKEN
printf '%s' "http://supervisor/core" > /var/run/s6/container_environment/HA_URL

# --- Persistence setup ---
PERSIST_DIR=/homeassistant/.claudecode
mkdir -p "${PERSIST_DIR}/config"
mkdir -p /home/claude/.config

# Write CLAUDE.md instructions
cat > "${PERSIST_DIR}/CLAUDE.md" << 'CLAUDEMD'
# Claude Code - Home Assistant Add-on

## Path Mapping

In this add-on container, paths are mapped differently than HA Core:
- `/homeassistant` = HA config directory (equivalent to `/config` in HA Core)
- `/config` does NOT exist - always use `/homeassistant`

When users mention `/config/...`, translate to `/homeassistant/...`

## Available Paths

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media files | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

## Home Assistant Integration

Use the `homeassistant` MCP server to query entities and call services.

## Reading Home Assistant Logs

**Log levels (from most to least verbose):**
- `debug` - Only shown if explicitly enabled in configuration.yaml
- `info` - General information, shown by default
- `warning` - Warnings, always shown
- `error` - Errors, always shown

**Commands to read logs:**
```bash
# View recent logs (ha CLI)
ha core logs 2>&1 | tail -100

# Filter by keyword
ha core logs 2>&1 | grep -i keyword

# Filter errors only
ha core logs 2>&1 | grep -iE "(error|exception)"

# Alternative: read log file directly
tail -100 /homeassistant/home-assistant.log
```

**To enable debug logging for an integration**, add to `configuration.yaml`:
```yaml
logger:
  default: info
  logs:
    custom_components.YOUR_INTEGRATION: debug
```

**Key insight:** `_LOGGER.debug()` calls are invisible unless the logger level is set to debug. Use `_LOGGER.info()` or `_LOGGER.warning()` for logs that should always appear.
CLAUDEMD

# --- Create symlinks (from claude user home to persist dir) ---
if [ ! -L /home/claude/.claude ]; then
    rm -rf /home/claude/.claude
    ln -s "${PERSIST_DIR}" /home/claude/.claude
fi
if [ ! -L /home/claude/.config/claude-code ]; then
    rm -rf /home/claude/.config/claude-code
    ln -s "${PERSIST_DIR}/config" /home/claude/.config/claude-code
fi
if [ ! -L /home/claude/.claude.json ]; then
    touch "${PERSIST_DIR}/.claude.json"
    rm -f /home/claude/.claude.json
    ln -s "${PERSIST_DIR}/.claude.json" /home/claude/.claude.json
fi

# --- Read add-on options ---
FONT_SIZE=$(bashio::config 'terminal_font_size')
THEME=$(bashio::config 'terminal_theme')
SESSION_PERSIST=$(bashio::config 'session_persistence')
ENABLE_MCP=$(bashio::config 'enable_mcp')
ENABLE_PLAYWRIGHT=$(bashio::config 'enable_playwright_mcp')
PLAYWRIGHT_HOST=$(bashio::config 'playwright_cdp_host')

# --- Write options as env vars for ttyd service ---
printf '%s' "${FONT_SIZE}" > /var/run/s6/container_environment/CLAUDE_FONT_SIZE
printf '%s' "${THEME}" > /var/run/s6/container_environment/CLAUDE_THEME
printf '%s' "${SESSION_PERSIST}" > /var/run/s6/container_environment/CLAUDE_SESSION_PERSIST

# --- Auto-detect Playwright hostname ---
if [ -z "${PLAYWRIGHT_HOST}" ] && [ "${ENABLE_PLAYWRIGHT}" = "true" ]; then
    bashio::log.info "Auto-detecting Playwright Browser hostname..."
    PLAYWRIGHT_HOST=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        http://supervisor/addons | \
        jq -r '.data.addons[] | select(.slug | endswith("playwright-browser") or endswith("_playwright-browser")) | .hostname' | \
        head -1)
    if [ -n "${PLAYWRIGHT_HOST}" ] && [ "${PLAYWRIGHT_HOST}" != "null" ]; then
        bashio::log.info "Found Playwright Browser: ${PLAYWRIGHT_HOST}"
    else
        bashio::log.warning "Playwright Browser add-on not found, using default hostname"
        PLAYWRIGHT_HOST="playwright-browser"
    fi
fi

# --- Auto-update Claude Code ---
AUTO_UPDATE=$(bashio::config 'auto_update_claude')
if [ "${AUTO_UPDATE}" = "true" ]; then
    bashio::log.info "Checking for Claude Code updates..."
    if [ -f /home/claude/.local/bin/claude ]; then
        # Native install: re-run installer with HOME=/home/claude so paths stay consistent
        HOME=/home/claude curl -fsSL https://claude.ai/install.sh | HOME=/home/claude bash 2>/dev/null \
            && chown claude:claude /home/claude/.local/bin/claude \
            || bashio::log.warning "Update check failed, continuing..."
    else
        # npm install: use npm update
        npm update -g @anthropic-ai/claude-code 2>/dev/null || \
            bashio::log.warning "Update check failed, continuing..."
    fi
fi

# --- Docker socket access ---
if [ -S /var/run/docker.sock ]; then
    addgroup claude docker 2>/dev/null || true
    chgrp docker /var/run/docker.sock 2>/dev/null || true
    chmod g+rw /var/run/docker.sock 2>/dev/null || true
fi

# --- Configure MCP servers (as claude user, since settings are in claude's home) ---
s6-setuidgid claude claude mcp remove homeassistant -s user 2>/dev/null || true
s6-setuidgid claude claude mcp remove playwright -s user 2>/dev/null || true

if [ "${ENABLE_MCP}" = "true" ]; then
    s6-setuidgid claude claude mcp add-json homeassistant '{"command":"hass-mcp"}' -s user
    SETTINGS_FILE=/home/claude/.claude/settings.json
    ALLOWED_TOOLS='["mcp__homeassistant__get_version","mcp__homeassistant__get_entity","mcp__homeassistant__list_entities","mcp__homeassistant__search_entities_tool","mcp__homeassistant__domain_summary_tool","mcp__homeassistant__list_automations","mcp__homeassistant__get_history","mcp__homeassistant__get_error_log","Read(/homeassistant/**)","Read(/config/**)","Read(/share/**)","Read(/media/**)","Glob(/homeassistant/**)","Glob(/config/**)","Grep(/homeassistant/**)","Grep(/config/**)"]'
    jq --argjson tools "${ALLOWED_TOOLS}" \
        '.permissions.allow = ($tools + (.permissions.allow // []) | unique)' \
        "${SETTINGS_FILE}" > /tmp/settings.tmp && [ -s /tmp/settings.tmp ] && mv /tmp/settings.tmp "${SETTINGS_FILE}"
    bashio::log.info "MCP configured with Home Assistant integration"
    bashio::log.info "Pre-authorized read-only MCP tools"
else
    bashio::log.info "MCP disabled"
fi

if [ "${ENABLE_PLAYWRIGHT}" = "true" ]; then
    s6-setuidgid claude claude mcp add-json playwright \
        "{\"command\":\"npx\",\"args\":[\"-y\",\"@playwright/mcp\",\"--cdp-endpoint\",\"http://${PLAYWRIGHT_HOST}:9222\"]}" \
        -s user
    bashio::log.info "Playwright MCP enabled (CDP: http://${PLAYWRIGHT_HOST}:9222)"
    bashio::log.info "Make sure the Playwright Browser add-on is installed and running"
else
    bashio::log.info "Playwright MCP disabled"
fi

# --- Custom bash aliases ---
ALIAS_COUNT=$(bashio::config 'bash_aliases|length')
if [ "${ALIAS_COUNT}" -gt 0 ]; then
    # Remove previous custom aliases block if present
    sed -i '/^# --- Custom aliases ---$/,/^# --- End custom aliases ---$/d' /home/claude/.bashrc
    {
        echo '# --- Custom aliases ---'
        for i in $(seq 0 $((ALIAS_COUNT - 1))); do
            ALIAS_LINE=$(bashio::config "bash_aliases[${i}]")
            echo "alias ${ALIAS_LINE}"
        done
        echo '# --- End custom aliases ---'
    } >> /home/claude/.bashrc
    bashio::log.info "Added ${ALIAS_COUNT} custom bash alias(es)"
fi

# --- SSH server setup ---
ENABLE_SSH=$(bashio::config 'enable_ssh')
if [ "${ENABLE_SSH}" = "true" ]; then
    # Generate host keys if missing (persist across restarts)
    SSH_DIR="${PERSIST_DIR}/ssh"
    mkdir -p "${SSH_DIR}"
    for keytype in rsa ecdsa ed25519; do
        if [ ! -f "${SSH_DIR}/ssh_host_${keytype}_key" ]; then
            ssh-keygen -t "${keytype}" -f "${SSH_DIR}/ssh_host_${keytype}_key" -N "" -q
        fi
    done

    # Write sshd config
    mkdir -p /etc/ssh
    cat > /etc/ssh/sshd_config << SSHEOF
Port 22
HostKey ${SSH_DIR}/ssh_host_rsa_key
HostKey ${SSH_DIR}/ssh_host_ecdsa_key
HostKey ${SSH_DIR}/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers claude
PrintMotd no
AcceptEnv LANG LC_*
PermitUserEnvironment SUPERVISOR_TOKEN,HA_TOKEN
Subsystem sftp /usr/lib/ssh/sftp-server
SSHEOF

    # Write authorized_keys from config
    mkdir -p /home/claude/.ssh
    : > /home/claude/.ssh/authorized_keys
    KEY_COUNT=$(bashio::config 'authorized_keys|length')
    for i in $(seq 0 $((KEY_COUNT - 1))); do
        KEY=$(bashio::config "authorized_keys[${i}]")
        echo "${KEY}" >> /home/claude/.ssh/authorized_keys
    done

    # Write SSH environment file so SUPERVISOR_TOKEN is available in SSH sessions
    cat > /home/claude/.ssh/environment << ENVEOF
SUPERVISOR_TOKEN=${SUPERVISOR_TOKEN:-}
HA_TOKEN=${SUPERVISOR_TOKEN:-}
HA_URL=http://supervisor/core
ENVEOF

    chmod 700 /home/claude/.ssh
    chmod 600 /home/claude/.ssh/authorized_keys
    chmod 600 /home/claude/.ssh/environment
    chown -R claude:claude /home/claude/.ssh

    # Ensure SSH login shells attach to the shared tmux session (same as web terminal)
    # This makes SSH and web terminal share the exact same session
    if ! grep -q 'SSH tmux attach' /home/claude/.bashrc; then
        cat >> /home/claude/.bashrc << 'TMUXEOF'

# --- SSH tmux attach ---
# If logging in via SSH (not already in tmux), attach to the shared session
if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
    tmux new-session -A -s claude && exit
fi
# --- End SSH tmux attach ---
TMUXEOF
    fi

    # Write env vars for sshd service
    printf 'true' > /var/run/s6/container_environment/CLAUDE_SSH_ENABLED

    if [ "${KEY_COUNT}" -gt 0 ]; then
        bashio::log.info "SSH enabled with ${KEY_COUNT} authorized key(s)"
    else
        bashio::log.warning "SSH enabled but no authorized_keys configured — add your public key in the add-on config"
    fi
else
    printf 'false' > /var/run/s6/container_environment/CLAUDE_SSH_ENABLED
    bashio::log.info "SSH disabled"
fi

# --- Ownership: give claude user access to all necessary dirs ---
chown -R claude:claude "${PERSIST_DIR}"
chown -R claude:claude /home/claude

# Give claude user access to mapped volumes
chown -R claude:claude /homeassistant 2>/dev/null || true
chown -R claude:claude /share 2>/dev/null || true
chown -R claude:claude /media 2>/dev/null || true
chown -R claude:claude /addon_configs 2>/dev/null || true
chown -R claude:claude /data 2>/dev/null || true

# Ensure /tmp/claude is owned by claude user (Claude Code uses /tmp/claude/ for sandbox tasks)
mkdir -p /tmp/claude
chown -R claude:claude /tmp/claude
chmod 1777 /tmp 2>/dev/null || true

bashio::log.info "Claude Code initialization complete"
