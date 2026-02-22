# Non-root Claude User via s6-overlay Migration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate the Claude Code add-on from `init: true` (tini + monolithic CMD) to `init: false` (s6-overlay v3) with a non-root `claude` user so `--dangerously-skip-permissions` works.

**Architecture:** Create a `claude` system user at build time. Use s6-overlay's `s6-rc.d` service structure: a `init-claude` oneshot for all setup (persistence, MCP, env), and a `ttyd` longrun service that uses `s6-setuidgid claude` to drop privileges for the user shell. The current monolithic CMD script is decomposed into these services plus helper scripts in `/usr/bin/`.

**Tech Stack:** s6-overlay v3 (already in HA base image), bashio, Alpine adduser, s6-setuidgid

**Design doc:** `docs/plans/2026-02-22-non-root-claude-s6-overlay-design.md`

**Historical context:** Versions 1.2.2-1.2.8 previously attempted s6-overlay and hit issues (permission denied on `/init`, PID 1 conflicts). The root cause was `init: true` in config.yaml conflicting with s6-overlay v3's PID 1 requirement. This time we set `init: false` and follow the official s6-rc.d pattern from the hassio-addons/addon-example reference.

---

### Task 1: Create the rootfs directory structure (empty skeleton)

**Files:**
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/type`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/up`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/dependencies.d/base`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/type`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/dependencies.d/init-claude`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-claude`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/ttyd`

**Step 1: Create all directories**

```bash
mkdir -p claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/dependencies.d
mkdir -p claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/dependencies.d
mkdir -p claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d
mkdir -p claudecode/rootfs/usr/bin
```

**Step 2: Create s6-rc.d metadata files**

These are tiny files that tell s6-overlay how to handle each service.

`claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/type`:
```
oneshot
```

`claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/up` (tells s6 which script to run):
```
/etc/s6-overlay/s6-rc.d/init-claude/run
```

`claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/type`:
```
longrun
```

**Step 3: Create empty dependency and registration files**

These are **empty files** whose names signal the dependency:

- `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/dependencies.d/base` — empty (init-claude depends on base HA init)
- `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/dependencies.d/init-claude` — empty (ttyd depends on init-claude)
- `claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-claude` — empty (registers init-claude)
- `claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/ttyd` — empty (registers ttyd)

**Step 4: Commit**

```bash
git add claudecode/rootfs/
git commit -m "feat: add s6-overlay v3 service skeleton for ttyd and init"
```

---

### Task 2: Write the init-claude oneshot script

This is the main init logic — extracted from the current monolithic CMD in the Dockerfile. Runs once at startup as root.

**Files:**
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run`
- Create: `claudecode/rootfs/usr/bin/claude-init.sh`

**Step 1: Create `claudecode/rootfs/usr/bin/claude-init.sh`**

This script contains all the init logic from the current CMD, adapted for the `claude` user. Key changes from the current CMD:

- All `/root/` paths become `/home/claude/`
- `s6-setuidgid claude` used for `claude mcp` commands
- Environment variables written to `/var/run/s6/container_environment/` for use by ttyd service
- Docker socket permissions set up for `claude` user

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Claude Code Add-on: Initialization
# Runs once at startup as root. Sets up persistence, MCP, environment.
# ==============================================================================

bashio::log.info "Initializing Claude Code add-on..."

# --- Export HA environment ---
export HA_TOKEN="${SUPERVISOR_TOKEN}"
export HA_URL="http://supervisor/core"

# Write env vars so the ttyd service (and its children) can access them
printf '%s' "${SUPERVISOR_TOKEN}" > /var/run/s6/container_environment/HA_TOKEN
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
    npm update -g @anthropic-ai/claude-code 2>/dev/null || \
        bashio::log.warning "Update check failed, continuing..."
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
        "${SETTINGS_FILE}" > /tmp/settings.tmp && mv /tmp/settings.tmp "${SETTINGS_FILE}"
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

# --- Ownership: give claude user access to all necessary dirs ---
chown -R claude:claude "${PERSIST_DIR}"
chown -R claude:claude /home/claude
# Only chown top-level of mapped volumes (recursive would be slow)
chown claude:claude /homeassistant 2>/dev/null || true
chown claude:claude /share 2>/dev/null || true
chown claude:claude /media 2>/dev/null || true

bashio::log.info "Claude Code initialization complete"
```

**Step 2: Create `claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run`**

This is a thin wrapper that just calls the main script:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Claude Code Add-on: Init oneshot
# ==============================================================================
exec /usr/bin/claude-init.sh
```

**Step 3: Set execute permissions**

```bash
chmod +x claudecode/rootfs/usr/bin/claude-init.sh
chmod +x claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run
```

**Step 4: Commit**

```bash
git add claudecode/rootfs/usr/bin/claude-init.sh
git add claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run
git commit -m "feat: add init-claude oneshot script for persistence, MCP, and env setup"
```

---

### Task 3: Write the ttyd longrun service

**Files:**
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run`
- Create: `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish`

**Step 1: Create `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run`**

This reads environment variables written by init-claude and launches ttyd, dropping to the `claude` user for the shell:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Claude Code Add-on: ttyd web terminal service
# ==============================================================================

# Read config from container environment (set by init-claude)
FONT_SIZE="${CLAUDE_FONT_SIZE:-14}"
THEME="${CLAUDE_THEME:-dark}"
SESSION_PERSIST="${CLAUDE_SESSION_PERSIST:-true}"

# Resolve theme colors
if [ "${THEME}" = "dark" ]; then
    COLORS='background=#1e1e2e,foreground=#cdd6f4,cursor=#f5e0dc'
else
    COLORS='background=#eff1f5,foreground=#4c4f69,cursor=#dc8a78'
fi

# Resolve shell command
if [ "${SESSION_PERSIST}" = "true" ]; then
    SHELL_CMD="tmux new-session -A -s claude"
else
    SHELL_CMD="bash --login"
fi

bashio::log.info "Starting ttyd (font=${FONT_SIZE}, theme=${THEME}, persist=${SESSION_PERSIST})..."

cd /homeassistant || true

# ttyd runs as root, but s6-setuidgid drops to claude user for the shell
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
    -t "fontSize=${FONT_SIZE}" \
    -t "fontFamily=Monaco,Consolas,monospace" \
    -t "scrollback=20000" \
    -t "theme=${COLORS}" \
    s6-setuidgid claude ${SHELL_CMD}
```

**Step 2: Create `claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish`**

Modeled on the official hassio-addons/addon-example finish script:

```bash
#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Claude Code Add-on: ttyd finish script
# ==============================================================================
declare exit_code_container
declare exit_code_service
declare exit_code_signal
readonly exit_code_container=$(</run/s6-linux-init-container-results/exitcode)
readonly exit_code_service="${1}"
readonly exit_code_signal="${2}"
readonly service="ttyd"

bashio::log.info \
    "Service ${service} exited with code ${exit_code_service}" \
    "(by signal ${exit_code_signal})"

if [[ "${exit_code_service}" -eq 256 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo $((128 + exit_code_signal)) > /run/s6-linux-init-container-results/exitcode
    fi
    [[ "${exit_code_signal}" -eq 15 ]] && exec /run/s6/basedir/bin/halt
elif [[ "${exit_code_service}" -ne 0 ]]; then
    if [[ "${exit_code_container}" -eq 0 ]]; then
        echo "${exit_code_service}" > /run/s6-linux-init-container-results/exitcode
    fi
    exec /run/s6/basedir/bin/halt
else
    bashio::log.info "Service ${service} restarting..."
fi
```

**Step 3: Set execute permissions**

```bash
chmod +x claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run
chmod +x claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish
```

**Step 4: Commit**

```bash
git add claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/
git commit -m "feat: add ttyd longrun service with s6-setuidgid for non-root shell"
```

---

### Task 4: Modify the Dockerfile

**Files:**
- Modify: `claudecode/Dockerfile`

The Dockerfile needs these changes:
1. Add `claude` user/group creation
2. Move `.bashrc`, `.tmux.conf`, `.profile` from `/root/` to `/home/claude/`
3. Update PATH from `/root/.local/bin` to `/home/claude/.local/bin`
4. Add `COPY rootfs /` to install the s6-overlay services
5. Remove `ENTRYPOINT []` and the entire monolithic `CMD [...]` block
6. Update directory creation from `/root/` to `/home/claude/`

**Step 1: Rewrite the Dockerfile**

Replace the full Dockerfile with the following. All package installs and binary downloads stay the same. Only the user/config/entrypoint sections change:

```dockerfile
ARG BUILD_FROM
FROM ${BUILD_FROM}

# Labels
LABEL maintainer="Robson Felix"
LABEL org.opencontainers.image.title="Claude Code for Home Assistant"
LABEL org.opencontainers.image.description="Claude Code CLI with web terminal and HA integration"
LABEL org.opencontainers.image.source="https://github.com/robsonfelix/robsonfelix-hass-addons"
LABEL org.opencontainers.image.licenses="MIT"

# Environment setup
ENV \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# Install system dependencies (ttyd installed separately as static binary)
RUN apk add --no-cache \
    bash \
    curl \
    git \
    github-cli \
    jq \
    nodejs \
    npm \
    openssh-client \
    libstdc++ \
    ncurses \
    vim \
    nano \
    tmux \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    ca-certificates \
    openssl \
    ripgrep \
    p7zip \
    socat \
    docker-cli \
    && update-ca-certificates

# Install ttyd static binary (avoids libwebsockets issues)
ARG BUILD_ARCH
RUN case "${BUILD_ARCH}" in \
        amd64) TTYD_ARCH="x86_64" ;; \
        aarch64) TTYD_ARCH="aarch64" ;; \
        armv7|armhf) TTYD_ARCH="armhf" ;; \
        i386) TTYD_ARCH="i686" ;; \
        *) TTYD_ARCH="x86_64" ;; \
    esac && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /usr/bin/ttyd && \
    chmod +x /usr/bin/ttyd

# Install Claude Code via npm
RUN npm install -g @anthropic-ai/claude-code

# Install hass-mcp for Home Assistant integration and pymodbus for Modbus operations
RUN pip3 install --no-cache-dir --break-system-packages hass-mcp pymodbus pyserial

# Install mbpoll (Modbus command line tool) from source
RUN apk add --no-cache --virtual .build-deps \
    build-base \
    cmake \
    libmodbus-dev \
    && git clone https://github.com/epsilonrt/mbpoll.git /tmp/mbpoll \
    && cd /tmp/mbpoll \
    && mkdir build && cd build \
    && cmake .. \
    && make \
    && make install \
    && cd / \
    && rm -rf /tmp/mbpoll \
    && apk del .build-deps \
    && apk add --no-cache libmodbus

# Install Playwright MCP server (official Microsoft package)
RUN npm install -g @playwright/mcp

# Install Home Assistant CLI (ha command)
RUN case "${BUILD_ARCH}" in \
        amd64) HA_ARCH="amd64" ;; \
        aarch64) HA_ARCH="aarch64" ;; \
        armv7|armhf) HA_ARCH="armhf" ;; \
        i386) HA_ARCH="i386" ;; \
        *) HA_ARCH="amd64" ;; \
    esac && \
    curl -fsSL "https://github.com/home-assistant/cli/releases/latest/download/ha_${HA_ARCH}" -o /usr/local/bin/ha && \
    chmod +x /usr/local/bin/ha

# Create non-root claude user
RUN addgroup -S claude && \
    adduser -S -G claude -h /home/claude -s /bin/bash claude

# Create necessary directories
RUN mkdir -p \
    /homeassistant \
    /home/claude/.config \
    /home/claude/.local/bin

# Configure tmux with large scrollback buffer and scroll support
RUN cat > /home/claude/.tmux.conf << 'EOF'
set -g history-limit 20000
# Disable alternate screen buffer to allow terminal scrollback
set -ga terminal-overrides ',xterm*:smcup@:rmcup@'
# Enable mouse support for scrolling (but may affect copy/paste)
set -g mouse on
# Bind mouse wheel to scroll through history in copy mode
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
bind -n WheelDownPane select-pane -t= \; send-keys -M
EOF

# Configure bash with aliases and prompt
RUN cat > /home/claude/.bashrc << 'EOF'
export TERM=xterm-256color
export LANG=C.UTF-8
PS1='\[\033[1;36m\]claude-code\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Function to update MCP token before starting Claude
update_mcp_token() {
  local SETTINGS_FILE=/home/claude/.claude/settings.json
  if [ -f "$SETTINGS_FILE" ] && [ -n "$SUPERVISOR_TOKEN" ]; then
    jq ".mcpServers.homeassistant.env.HASS_TOKEN = \"$SUPERVISOR_TOKEN\"" "$SETTINGS_FILE" > /tmp/settings.tmp 2>/dev/null && mv /tmp/settings.tmp "$SETTINGS_FILE"
  fi
}

# Aliases
alias ll='ls -la'
alias c='update_mcp_token && claude'
alias cc='update_mcp_token && claude --continue'
alias ha-config='cd /homeassistant'
alias ha-logs='cat /homeassistant/home-assistant.log 2>/dev/null || echo "Log not found"'
EOF

# Ensure .bashrc is sourced for login shells too
RUN echo 'source ~/.bashrc' > /home/claude/.profile

# Set ownership of claude home directory
RUN chown -R claude:claude /home/claude

# Set up PATH
ENV PATH="/home/claude/.local/bin:${PATH}"

# Copy rootfs (s6-overlay services and scripts)
COPY rootfs /

# Set working directory
WORKDIR /homeassistant

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:7681/ || exit 1
```

Note: No `ENTRYPOINT` or `CMD` — s6-overlay's `/init` (from the base image) is the entrypoint.

**Step 2: Commit**

```bash
git add claudecode/Dockerfile
git commit -m "feat: rewrite Dockerfile for non-root claude user with s6-overlay"
```

---

### Task 5: Update config.yaml

**Files:**
- Modify: `claudecode/config.yaml` (line 14: `init: true` -> `init: false`, bump version)

**Step 1: Change init and bump version**

In `claudecode/config.yaml`:
- Change line 3: `version: "1.2.62"` -> `version: "1.3.0"` (major feature change)
- Change line 14: `init: true` -> `init: false`

**Step 2: Commit**

```bash
git add claudecode/config.yaml
git commit -m "feat: switch to init: false for s6-overlay v3 and bump version to 1.3.0"
```

---

### Task 6: Update AppArmor profile

**Files:**
- Modify: `claudecode/apparmor.txt`

**Step 1: Add claude user home and s6-overlay paths**

Add after the existing `/root/**` rules:

```
  # Claude non-root user home
  /home/claude/ r,
  /home/claude/** rwk,
```

Add s6-overlay paths (after the Node.js modules section):

```
  # S6-overlay init and services
  /init ixr,
  /run/** rwk,
  /command/** ixr,
  /package/** r,
  /etc/s6-overlay/** r,
```

Keep the existing `/root/` rules (root still runs the init process).

**Step 2: Commit**

```bash
git add claudecode/apparmor.txt
git commit -m "feat: add AppArmor rules for claude user home and s6-overlay paths"
```

---

### Task 7: Update CHANGELOG.md

**Files:**
- Modify: `claudecode/CHANGELOG.md`

**Step 1: Add 1.3.0 entry at the top of the changelog**

Add before the `## [1.2.62]` entry:

```markdown
## [1.3.0] - 2026-02-22

### Changed
- Migrated from Docker tini (`init: true`) to s6-overlay v3 (`init: false`)
- Shell session now runs as non-root `claude` user instead of root
- Claude Code `--dangerously-skip-permissions` flag now works
- ttyd web terminal supervised by s6-overlay (auto-restart on crash)
- Startup logic decomposed into s6-overlay services (init-claude oneshot + ttyd longrun)

### Added
- Non-root `claude` system user for shell sessions
- s6-overlay process supervision for ttyd service
- AppArmor rules for `/home/claude/` and s6-overlay paths

### Note
- All existing features (persistence, MCP, Playwright, Docker, tmux) work identically
- Config persisted at `/homeassistant/.claudecode` is fully compatible (no migration needed)
- Root is still used for container init and ttyd process; only the user shell is non-root
```

**Step 2: Commit**

```bash
git add claudecode/CHANGELOG.md
git commit -m "docs: add CHANGELOG entry for 1.3.0 s6-overlay migration"
```

---

### Task 8: Set file permissions and verify git tracks them

**Files:**
- Verify: all `run` and `finish` scripts are executable in git

**Step 1: Ensure execute permissions are tracked by git**

Git must track the executable bit for s6-overlay scripts. If not set correctly, s6-overlay will fail with permission denied:

```bash
git update-index --chmod=+x claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run
git update-index --chmod=+x claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run
git update-index --chmod=+x claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish
git update-index --chmod=+x claudecode/rootfs/usr/bin/claude-init.sh
```

**Step 2: Verify**

```bash
git ls-files -s claudecode/rootfs/ | grep -E '(run|finish|\.sh)'
```

Expected: all listed files show mode `100755` (not `100644`).

**Step 3: Commit if permissions changed**

```bash
git add claudecode/rootfs/
git diff --cached --stat
# If there are changes:
git commit -m "fix: ensure s6-overlay scripts have execute permissions in git"
```

---

### Task 9: Final review and smoke test checklist

**Step 1: Verify no references to /root/ remain in rootfs scripts**

```bash
grep -r '/root/' claudecode/rootfs/
```

Expected: no matches.

**Step 2: Verify no references to /root/ remain in Dockerfile (except comments)**

```bash
grep '/root/' claudecode/Dockerfile
```

Expected: no matches.

**Step 3: Verify ENTRYPOINT and CMD are not in Dockerfile**

```bash
grep -E '^(ENTRYPOINT|CMD)' claudecode/Dockerfile
```

Expected: no matches.

**Step 4: Verify config.yaml has init: false**

```bash
grep 'init:' claudecode/config.yaml
```

Expected: `init: false`

**Step 5: Verify all s6 service files exist**

```bash
find claudecode/rootfs -type f | sort
```

Expected output (all files present):
```
claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/dependencies.d/base
claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/run
claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/type
claudecode/rootfs/etc/s6-overlay/s6-rc.d/init-claude/up
claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/dependencies.d/init-claude
claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/finish
claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/run
claudecode/rootfs/etc/s6-overlay/s6-rc.d/ttyd/type
claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/init-claude
claudecode/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/ttyd
claudecode/rootfs/usr/bin/claude-init.sh
```

**Step 6: Document testing steps for the user**

After deploying, test:
1. Add-on starts without errors in the HA log
2. Web terminal loads at the ingress URL
3. `whoami` in the terminal shows `claude` (not `root`)
4. `claude --dangerously-skip-permissions` launches without the root error
5. `c` alias works (update MCP token + launch claude)
6. MCP servers are configured (`claude mcp list`)
7. tmux session persists across terminal reconnects
8. Docker commands work (`docker ps`)
9. Files in `/homeassistant/` are readable and writable
10. Persistence survives add-on restart (settings still there after restart)
