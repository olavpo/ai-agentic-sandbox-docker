#!/bin/bash
# Entrypoint: installs agents on first run, sets up git auth.

AGENT_HOME="/home/agent"

# Disable SSH agent forwarding (HTTPS-only git access)
unset SSH_AUTH_SOCK
export SSH_AUTH_SOCK=""

# Install agents on first run (skips if already present).
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

# Configure git to use GITHUB_TOKEN for HTTPS auth
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=$GITHUB_TOKEN"; }; f'
fi

# cd into the project directory (named after the project, not /workspace)
if [[ -n "${PROJECT_NAME:-}" && -d "/$PROJECT_NAME" ]]; then
    cd "/$PROJECT_NAME"
fi

exec "$@"
