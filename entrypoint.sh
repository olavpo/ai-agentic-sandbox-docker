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

# --- Surface SANDBOX_HOST_PORT to the agent ---
# agent-sandbox.sh pre-allocates an unused port on the host and publishes it
# both ways (-p PORT:PORT), then passes it via the env. Make it discoverable
# through two container-local channels:
#   1) the env var itself (already set by docker run)
#   2) /etc/sandbox-info — a plain-text dump for any tool that doesn't read env
#
# We deliberately do NOT write to ~/.claude/CLAUDE.md: that path is a named
# volume shared across every sandbox on this machine, so writing there from
# one sandbox would corrupt the port for any other running sandbox. The
# user surfaces the port to Claude either by mentioning it in conversation
# ("use $SANDBOX_HOST_PORT for the visual companion") or by adding a hint
# to a project-level CLAUDE.md in their repo if the project regularly needs
# host-visible servers.
if [[ -n "${SANDBOX_HOST_PORT:-}" ]]; then
    echo "SANDBOX_HOST_PORT=$SANDBOX_HOST_PORT" | sudo tee /etc/sandbox-info >/dev/null
fi

# --- Install agents on first run ---
# Installed into the named volume so they persist across container recreations.
if ! command -v claude &>/dev/null; then
    echo "[entrypoint] Installing Claude Code..."
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "[entrypoint] Native installer failed, trying npm fallback..."
        sudo npm install -g @anthropic-ai/claude-code || \
            echo "[entrypoint] WARNING: Claude Code install failed. Run manually: npm install -g @anthropic-ai/claude-code"
    fi
fi

if ! command -v github-copilot &>/dev/null && command -v npm &>/dev/null; then
    echo "[entrypoint] Installing GitHub Copilot CLI..."
    sudo npm install -g @github/copilot
fi

if ! command -v mistral-vibe &>/dev/null && command -v uv &>/dev/null; then
    echo "[entrypoint] Installing Mistral Vibe..."
    uv tool install mistral-vibe
fi

# --- Git HTTPS auth ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=$GITHUB_TOKEN"; }; f'
fi

# --- cd into the project ---
if [[ -n "${PROJECT_NAME:-}" && -d "/$PROJECT_NAME" ]]; then
    cd "/$PROJECT_NAME"
fi

exec "$@"
