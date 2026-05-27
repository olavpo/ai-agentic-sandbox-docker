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
# through three channels:
#   1) the env var itself (already set)
#   2) /etc/sandbox-info (for tools that don't read env)
#   3) a delimited snippet in ~/.claude/CLAUDE.md so Claude reliably learns
#      about it on each start
if [[ -n "${SANDBOX_HOST_PORT:-}" ]]; then
    echo "SANDBOX_HOST_PORT=$SANDBOX_HOST_PORT" | sudo tee /etc/sandbox-info >/dev/null

    mkdir -p "$AGENT_HOME/.claude"
    claude_md="$AGENT_HOME/.claude/CLAUDE.md"
    start_marker="<!-- BEGIN agent-sandbox -->"
    end_marker="<!-- END agent-sandbox -->"

    # Strip any previous block, then append the fresh one.
    if [[ -f "$claude_md" ]]; then
        # sed -i in-place; use a tmp file for portability.
        awk -v start="$start_marker" -v end="$end_marker" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "$claude_md" > "$claude_md.tmp" && mv "$claude_md.tmp" "$claude_md"
    fi

    cat >> "$claude_md" <<EOF
$start_marker
## Running services for the user's browser

The sandbox pre-published one port to the host: \`$SANDBOX_HOST_PORT\` (also available as \`\$SANDBOX_HOST_PORT\` env var, and in \`/etc/sandbox-info\`).

If you need to start a server, dev preview, or visual companion that the user should open in their browser, **bind to port \`$SANDBOX_HOST_PORT\`**. The user can then open <http://localhost:$SANDBOX_HOST_PORT> on their host.

Examples:
- \`python -m http.server \$SANDBOX_HOST_PORT\`
- For skills that take a \`--port\` flag, pass \`\$SANDBOX_HOST_PORT\`.
- For \`vite\`, \`webpack-dev-server\`, etc., configure the port in the project's config or via \`--port \$SANDBOX_HOST_PORT\`.

Only one host-visible port is published per sandbox session. If you need another, start a fresh sandbox or ask the user to publish more ports explicitly via \`agent-sandbox start -p HOST:CONTAINER\`.
$end_marker
EOF
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
