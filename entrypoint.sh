#!/bin/bash
# Entrypoint: applies egress firewall, installs agents, sets up git auth,
# surfaces SANDBOX_HOST_PORT to the agent.

AGENT_HOME="/home/agent"

# Disable SSH agent forwarding (HTTPS-only git access)
unset SSH_AUTH_SOCK
export SSH_AUTH_SOCK=""

# --- Egress firewall ---
# Run unless the user explicitly opted into host networking via
# SANDBOX_SKIP_FIREWALL=1 (set by `agent-sandbox start --host-network`).
# Requires NET_ADMIN + NET_RAW caps on the container; skips cleanly if
# they're missing so the container still boots.
if [[ "${SANDBOX_SKIP_FIREWALL:-}" != "1" ]]; then
    # DHIS2_BROKER_URL and ADB_SERVER_SOCKET are forwarded explicitly because
    # sudo resets the environment; the firewall opens egress to just those
    # host:ports.
    if sudo -n env DHIS2_BROKER_URL="${DHIS2_BROKER_URL:-}" \
            ADB_SERVER_SOCKET="${ADB_SERVER_SOCKET:-}" \
            /usr/local/bin/init-firewall.sh; then
        # Keep up with CDN edge IP rotation. Hosts behind CloudFront (e.g.
        # docs.dhis2.org) return different edge IPs over time; the IPs we
        # resolved at boot age out of the allowed-domains ipset, and after
        # a while connections to those hosts start failing with "No route
        # to host". The background loop re-resolves DOMAINS into the
        # existing ipset (no rule flush, no in-flight disruption).
        REFRESH_INTERVAL="${SANDBOX_FIREWALL_REFRESH_INTERVAL:-300}"
        (
            while true; do
                sleep "$REFRESH_INTERVAL"
                sudo -n /usr/local/bin/init-firewall.sh --refresh-only \
                    >/tmp/firewall-refresh.log 2>&1 || true
            done
        ) &
        disown
    else
        echo "[entrypoint] WARNING: firewall init failed. Container may have unrestricted egress."
        echo "[entrypoint]   To run without firewall on purpose, pass --host-network to agent-sandbox start."
    fi
else
    echo "[entrypoint] SANDBOX_SKIP_FIREWALL=1 — running with unrestricted network."
fi

# --- Surface host-visible ports to the agent (container-local channels) ---
# agent-sandbox.sh pre-allocates unused host ports and publishes them both ways
# (-p PORT:PORT), then passes them via the env. Each sandbox gets its own
# ports, so the actual VALUES are kept container-local:
#   - $SANDBOX_HOST_PORT (+ $SANDBOX_HOST_PORT_2) env vars (set by docker run)
#   - /etc/sandbox-info (plain-text dump for tools that don't read env)
# SANDBOX_HOST_PORT_2 is optional so this stays correct against an older
# agent-sandbox.sh that only publishes one port.
if [[ -n "${SANDBOX_HOST_PORT:-}" ]]; then
    {
        echo "SANDBOX_HOST_PORT=$SANDBOX_HOST_PORT"
        [[ -n "${SANDBOX_HOST_PORT_2:-}" ]] && echo "SANDBOX_HOST_PORT_2=$SANDBOX_HOST_PORT_2"
    } | sudo tee /etc/sandbox-info >/dev/null
fi

# --- Generic sandbox brief in ~/.claude/CLAUDE.md ---
# This is the same content for every sandbox (no per-container values), so
# it's safe to write into the shared `agentic-sandbox-claude` volume. The
# block is delimited and rewritten on every start, so updates to this
# entrypoint propagate to all sandboxes the next time they boot. Any
# user content OUTSIDE the markers is preserved.
mkdir -p "$AGENT_HOME/.claude"
claude_md="$AGENT_HOME/.claude/CLAUDE.md"
start_marker="<!-- BEGIN agent-sandbox -->"
end_marker="<!-- END agent-sandbox -->"

if [[ -f "$claude_md" ]]; then
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip       { print }
    ' "$claude_md" > "$claude_md.tmp" && mv "$claude_md.tmp" "$claude_md"
fi

cat >> "$claude_md" <<'EOF'
<!-- BEGIN agent-sandbox -->
## Sandbox environment

You're running inside the **agentic-sandbox** Docker container, not directly on the user's machine. A few things to know:

### Network is restricted

Outbound traffic is filtered by an iptables egress firewall. Allowed by default: Anthropic, GitHub, npm/yarn registry, pypi, dhis2.org, plus a small set of dev CDNs (Playwright, VS Code marketplace, NodeSource, Debian). Anything else is dropped — `curl https://example.com` will fail. If you need a new host, ask the user to add it to `init-firewall.sh` and rebuild.

You're on the **`dev-net`** Docker network by default. Sibling dev containers (e.g. a DHIS2 instance named `dhis2`, a database named `dhis2-db`, an MCP server wrapped as a container) are reachable by container name: `curl http://dhis2:8080/api/me`. Use `ip route` to see what subnets are attached.

`localhost:<port>` inside the sandbox is the sandbox itself — ports that other containers publish "to localhost" are published to the **host**, not to you. Prefer container names on `dev-net`. If a container isn't on dev-net but does publish a host port, that port is usually reachable on the bridge gateway IP (`ip route | awk '/default/ {print $3}'`).

Services running on the user's host machine are **not** reachable from inside the sandbox, with two exceptions when configured: the DHIS2 instance broker and the host's adb server (Android emulator), both below. For anything else on the host, ask the user to either run it as a sibling container on `dev-net` or to install/run the equivalent inside the sandbox.

### DHIS2 test instances (d2-broker)

If the `DHIS2_BROKER_URL` and `DHIS2_BROKER_TOKEN` environment variables are set, the host runs **d2-broker** — an HTTP API through which you can create, reset, start/stop and delete disposable DHIS2 instances for testing. You may only manage instances named `agent-*`, and only seed them from the curated list at `GET /seeds` (or create them empty). All mutating calls return a job to poll. Quick check:

```bash
curl -s -H "Authorization: Bearer $DHIS2_BROKER_TOKEN" "$DHIS2_BROKER_URL/instances"
```

Created instances are reachable on dev-net at `http://dhis2-<name>:8080` (credentials usually `admin`/`district`). See the `dhis2-instances` skill for the full API. If the env vars are unset, this capability is unavailable — don't probe for it.

### Android emulator (adb)

If the `ADB_SERVER_SOCKET` environment variable is set, the host runs an adb server (usually with an Android emulator attached) and the `adb` client in this sandbox already points at it — `adb devices` just works. You can:

- install APKs: `adb install /path/to/app.apk`
- see the screen: `adb exec-out screencap -p > /tmp/screen.png` (then read the PNG)
- inspect the UI: `adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml`
- interact: `adb shell input tap X Y`, `input swipe ...`, `input text '...'`, `input keyevent ...`
- read logs: `adb logcat -d`

**Never run `adb kill-server`** — the server belongs to the host; killing it breaks the connection for everyone and you cannot restart it from in here.

The emulator runs on the **host**, not on dev-net. Inside an app on the emulator, the host's loopback is `10.0.2.2` — so to point an Android app (e.g. the DHIS2 Capture app) at a broker-created DHIS2 instance, use `http://10.0.2.2:<http_port>`, where `http_port` comes from `GET $DHIS2_BROKER_URL/instances`. The dev-net URL (`http://dhis2-<name>:8080`) does NOT resolve on the emulator.

See the `dhis2-android-testing` skill for the full workflow. If `ADB_SERVER_SOCKET` is unset, there is no emulator wiring — don't probe for it.

### Host-visible ports: `$SANDBOX_HOST_PORT` (+ `$SANDBOX_HOST_PORT_2`)

The sandbox pre-publishes two ports to the user's host. Their values are in the `$SANDBOX_HOST_PORT` and `$SANDBOX_HOST_PORT_2` environment variables and in `/etc/sandbox-info`.

**When you start a server the user should view in their browser** (visual companion, dev preview, Playwright report, etc.), bind it to `$SANDBOX_HOST_PORT`. The user opens `http://localhost:$SANDBOX_HOST_PORT` on their host. Use `$SANDBOX_HOST_PORT_2` for a second host-visible service — e.g. an App Platform dev server on one and its proxy on the other.

Examples:
- `python -m http.server "$SANDBOX_HOST_PORT"`
- For skills/tools with a `--port` flag: pass `"$SANDBOX_HOST_PORT"`.
- For `vite` / `webpack-dev-server`: configure via `--port "$SANDBOX_HOST_PORT"` or the relevant config field.

Two host-visible ports are auto-published per session (`$SANDBOX_HOST_PORT` and `$SANDBOX_HOST_PORT_2`). If you need a third, ask the user to start the sandbox with extra `-p` flags: `agent-sandbox start -p 5173:5173`.

**Running a DHIS2 app for the user**: the dev server with hot reload (`d2 app:scripts start` / `yarn start`) is the default way to serve an app, both while developing and for manual testing — bind it to `$SANDBOX_HOST_PORT`. Installing the built zip (`POST /api/apps`) is a *verification* step for reviews/releases, not the serving mechanism. Mechanics live in the `dhis2-app-development` and `dhis2-app-review` skills.

### Git

HTTPS only (SSH is not installed). `GITHUB_TOKEN` is set if the user provided one. The token **may be read-only** — `git commit`, `git branch`, `git diff`, `git fetch`, `git clone` work as normal, but `git push` will be rejected by the server. Don't try to work around this; if push needs to happen, the user does it from the host.

### Filesystem

- Your project is mounted at `/<project-name>` (whatever directory you start in).
- Skills live under `~/.claude/skills/`. If a skill is missing, ask the user to run `agent-sandbox sync-skills push` outside the container. **Edits you make to a skill *inside* the sandbox don't persist** — `~/.claude/skills/` is synced from the host. Apply skill changes host-side (the masters), or they're lost on the next sync.
- You can write freely under `/<project-name>`, `/tmp`, and `~/`. The host filesystem outside the project mount is not accessible.

### Permissions

You run as the `agent` user with passwordless `sudo` for system changes inside the container. Sudo doesn't reach the user's host. Resource limits: 8 GB RAM, 4 CPUs.
<!-- END agent-sandbox -->
EOF

# --- Install the chosen agent(s) on first run ---
# agent-sandbox.sh sets AGENT_CHOICE to one of: claude (default), copilot,
# vibe, all. The matching named volume is also mounted at /home/agent/.<agent>
# so installs persist across container recreations.
AGENT_CHOICE="${AGENT_CHOICE:-claude}"

case "$AGENT_CHOICE" in
    claude|all)
        if ! command -v claude &>/dev/null; then
            echo "[entrypoint] Installing Claude Code..."
            if ! curl -fsSL https://claude.ai/install.sh | bash; then
                echo "[entrypoint] Native installer failed, trying npm fallback..."
                sudo npm install -g @anthropic-ai/claude-code \
                    || echo "[entrypoint] WARNING: Claude Code install failed."
            fi
        fi
        ;;
esac

case "$AGENT_CHOICE" in
    copilot|all)
        if ! command -v copilot &>/dev/null && command -v npm &>/dev/null; then
            echo "[entrypoint] Installing GitHub Copilot CLI..."
            sudo npm install -g @github/copilot
        fi
        ;;
esac

case "$AGENT_CHOICE" in
    vibe|all)
        if ! command -v vibe &>/dev/null && command -v uv &>/dev/null; then
            echo "[entrypoint] Installing Mistral Vibe..."
            uv tool install mistral-vibe
        fi
        ;;
esac

# --- Claude Code plugins ---
# Install marketplace plugins natively in the container (skills come from the
# plugin, namespaced e.g. superpowers:brainstorming, and auto-update) rather
# than syncing the host's materialized skill copies. The marketplace is a
# public GitHub repo (GitHub is allowlisted in the firewall), so this works
# from inside the sandbox. Both commands are idempotent, so it's safe to run
# on every boot. Plugin state lives in the persistent ~/.claude volume.
#
# SANDBOX_CLAUDE_PLUGINS is a space-separated list of plugin@marketplace ids;
# SANDBOX_CLAUDE_MARKETPLACES is the matching list of marketplace sources to
# register first. Defaults install the superpowers skill set. Set either to
# an empty string to skip.
if [[ "$AGENT_CHOICE" == "claude" || "$AGENT_CHOICE" == "all" ]] \
        && command -v claude &>/dev/null; then
    marketplaces="${SANDBOX_CLAUDE_MARKETPLACES-anthropics/claude-plugins-official}"
    plugins="${SANDBOX_CLAUDE_PLUGINS-superpowers@claude-plugins-official}"
    for mkt in $marketplaces; do
        claude plugin marketplace add "$mkt" 2>/dev/null \
            || echo "[entrypoint] note: marketplace add '$mkt' failed (already added, or offline)"
    done
    for plg in $plugins; do
        if claude plugin list 2>/dev/null | grep -q "${plg%@*}"; then
            continue   # already installed
        fi
        echo "[entrypoint] Installing Claude plugin: $plg"
        claude plugin install "$plg" --scope user 2>/dev/null \
            || echo "[entrypoint] WARNING: plugin install '$plg' failed."
    done
fi

# --- Git HTTPS auth ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=$GITHUB_TOKEN"; }; f'
fi

# --- Git identity ---
# Without this, the first commit fails with "Please tell me who you are".
# Overridable via GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL; otherwise a generic
# sandbox identity so commits don't hard-fail. The user pushes from the host,
# where their real identity applies.
git config --global --get user.email >/dev/null 2>&1 || \
    git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@agentic-sandbox.local}"
git config --global --get user.name >/dev/null 2>&1 || \
    git config --global user.name "${GIT_AUTHOR_NAME:-Agent Sandbox}"

# --- Ignore host-OS litter globally (macOS bind mounts drop .DS_Store etc.) ---
if [[ ! -f "$AGENT_HOME/.gitignore_global" ]]; then
    printf '.DS_Store\n._*\nThumbs.db\n' > "$AGENT_HOME/.gitignore_global"
fi
git config --global core.excludesfile "$AGENT_HOME/.gitignore_global"

# --- cd into the project ---
# PROJECT_DIR is the full-host-path mount; /$PROJECT_NAME is the legacy
# basename mount for containers created before PROJECT_DIR existed.
if [[ -n "${PROJECT_DIR:-}" && -d "$PROJECT_DIR" ]]; then
    cd "$PROJECT_DIR"
elif [[ -n "${PROJECT_NAME:-}" && -d "/$PROJECT_NAME" ]]; then
    cd "/$PROJECT_NAME"
fi

exec "$@"
