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
    if sudo -n /usr/local/bin/init-firewall.sh; then
        :
    else
        echo "[entrypoint] WARNING: firewall init failed. Container may have unrestricted egress."
        echo "[entrypoint]   To run without firewall on purpose, pass --host-network to agent-sandbox start."
    fi
else
    echo "[entrypoint] SANDBOX_SKIP_FIREWALL=1 — running with unrestricted network."
fi

# --- Surface SANDBOX_HOST_PORT to the agent (container-local channels) ---
# agent-sandbox.sh pre-allocates an unused port on the host and publishes it
# both ways (-p PORT:PORT), then passes it via the env. Each sandbox gets
# its own port, so the actual VALUE is kept container-local:
#   - $SANDBOX_HOST_PORT env var (set by docker run)
#   - /etc/sandbox-info (plain-text dump for tools that don't read env)
if [[ -n "${SANDBOX_HOST_PORT:-}" ]]; then
    echo "SANDBOX_HOST_PORT=$SANDBOX_HOST_PORT" | sudo tee /etc/sandbox-info >/dev/null
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

Services running on the user's host machine are **not** reachable from inside the sandbox by default. If you need to talk to something on the host, ask the user to either run it as a sibling container on `dev-net` or to install/run the equivalent inside the sandbox.

### Host-visible port: `$SANDBOX_HOST_PORT`

The sandbox pre-publishes one port to the user's host. Its value is in the `$SANDBOX_HOST_PORT` environment variable and in `/etc/sandbox-info`.

**When you start a server the user should view in their browser** (visual companion, dev preview, Playwright report, etc.), bind it to `$SANDBOX_HOST_PORT`. The user opens `http://localhost:$SANDBOX_HOST_PORT` on their host.

Examples:
- `python -m http.server "$SANDBOX_HOST_PORT"`
- For skills/tools with a `--port` flag: pass `"$SANDBOX_HOST_PORT"`.
- For `vite` / `webpack-dev-server`: configure via `--port "$SANDBOX_HOST_PORT"` or the relevant config field.

Only one host-visible port is auto-published per session. If you need another, ask the user to start the sandbox with `agent-sandbox start -p HOST:CONTAINER`.

### Git

HTTPS only (SSH is not installed). `GITHUB_TOKEN` is set if the user provided one. The token **may be read-only** — `git commit`, `git branch`, `git diff`, `git fetch`, `git clone` work as normal, but `git push` will be rejected by the server. Don't try to work around this; if push needs to happen, the user does it from the host.

### Filesystem

- Your project is mounted at `/<project-name>` (whatever directory you start in).
- Skills live under `~/.claude/skills/`. If a skill is missing, ask the user to run `agent-sandbox sync-skills push` outside the container.
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

# --- Git HTTPS auth ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=$GITHUB_TOKEN"; }; f'
fi

# --- cd into the project ---
if [[ -n "${PROJECT_NAME:-}" && -d "/$PROJECT_NAME" ]]; then
    cd "/$PROJECT_NAME"
fi

exec "$@"
