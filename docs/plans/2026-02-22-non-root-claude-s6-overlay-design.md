# Non-root Claude User via s6-overlay Migration

## Problem

Claude Code's `--dangerously-skip-permissions` flag refuses to run as root. The add-on currently runs everything as root, so users cannot use this flag.

## Solution

Migrate from `init: true` (Docker tini + monolithic CMD script) to `init: false` (s6-overlay v3) and create a non-root `claude` user. The container init and ttyd run as root; the user's shell session runs as the `claude` user.

## Architecture

### User Creation (Dockerfile, build time)

Create a `claude` user and group:

```dockerfile
RUN addgroup -S claude && \
    adduser -S -G claude -h /home/claude -s /bin/bash claude
```

Move `.bashrc`, `.tmux.conf`, `.profile` from `/root/` to `/home/claude/`.

### s6-overlay Service Structure

```
claudecode/
  rootfs/
    etc/
      s6-overlay/
        s6-rc.d/
          init-claude/              # oneshot: setup, persistence, MCP config
            type                    # "oneshot"
            dependencies.d/
              base                  # depends on HA base init
            up                      # points to run script
            run                     # init logic
          ttyd/                     # longrun: web terminal (supervised)
            type                    # "longrun"
            dependencies.d/
              init-claude           # depends on init completing
            run                     # starts ttyd
            finish                  # handles exit/restart
          user/
            contents.d/
              init-claude           # empty (registers service)
              ttyd                  # empty (registers service)
    usr/
      bin/
        claude-init.sh              # main init logic
```

### init-claude (oneshot)

Runs once as root at startup. Replaces the current monolithic CMD script. Responsibilities:

- Create persist directory at `/homeassistant/.claudecode`
- Write `CLAUDE.md` instructions file to persist dir
- Create symlinks from `/home/claude/` to persist dir:
  - `/home/claude/.claude` -> `/homeassistant/.claudecode`
  - `/home/claude/.config/claude-code` -> `/homeassistant/.claudecode/config`
  - `/home/claude/.claude.json` -> `/homeassistant/.claudecode/.claude.json`
- Read add-on options from `/data/options.json`
- Auto-detect Playwright Browser hostname if enabled
- Run `npm update -g @anthropic-ai/claude-code` if auto-update enabled
- Configure MCP servers via `claude mcp add-json` (run as claude user via `s6-setuidgid`)
- Pre-authorize MCP tools in settings.json
- Set up Docker socket group permissions
- `chown` persistence dir to `claude` user
- Write runtime environment variables (theme, font size, etc.) to `/var/run/s6/container_environment/` for service access

### ttyd (longrun)

Supervised by s6-overlay. Runs as root, spawns shell as `claude` user:

```bash
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
    -t fontSize=$FONT_SIZE \
    -t fontFamily=Monaco,Consolas,monospace \
    -t scrollback=20000 \
    -t "theme=$COLORS" \
    s6-setuidgid claude $SHELL_CMD
```

Where `$SHELL_CMD` is `tmux new-session -A -s claude` (if session persistence enabled) or `bash --login`.

The `finish` script handles container shutdown when ttyd exits unexpectedly, using `/run/s6/basedir/bin/halt`.

### Config Changes

`config.yaml`:
- `init: false` (was `init: true`)
- Remove `ENTRYPOINT []` and `CMD [...]` from Dockerfile

### Persistence

Unchanged. Uses `/homeassistant/.claudecode` on the `homeassistant_config:rw` volume. Survives add-on reinstalls. Symlinks point from `/home/claude/` instead of `/root/`.

### Docker Socket Access

At init time (as root):

```bash
if [ -S /var/run/docker.sock ]; then
    addgroup claude docker 2>/dev/null || true
    chgrp docker /var/run/docker.sock
    chmod g+rw /var/run/docker.sock
fi
```

### AppArmor

Add to `apparmor.txt`:

```
/home/claude/ r,
/home/claude/** rwk,
/init ixr,
/run/** rwk,
/command/** ixr,
/package/** r,
/etc/s6-overlay/** r,
```

### What Runs as Root

- s6-overlay init (PID 1)
- init-claude oneshot (chown, Docker socket, npm update, setup)
- ttyd process itself

### What Runs as Non-root (`claude` user)

- bash/tmux shell session (user-facing)
- Claude Code CLI
- git, npm, and other tools invoked from the shell

## Trade-offs

**Gains:** Non-root shell (enables `--dangerously-skip-permissions`), proper process supervision (auto-restart on crash), clean shutdown handling, follows HA add-on conventions.

**Costs:** More files to maintain (rootfs structure vs single CMD), s6-overlay learning curve, slightly harder startup debugging.

**No functionality lost.** All features (ttyd, tmux, MCP, Playwright, Docker, persistence) work identically.

## References

- [S6-Overlay v3 migration](https://developers.home-assistant.io/blog/2022/05/12/s6-overlay-base-images/)
- [HA community add-on example](https://github.com/hassio-addons/addon-example)
- [s6-overlay GitHub](https://github.com/just-containers/s6-overlay)
