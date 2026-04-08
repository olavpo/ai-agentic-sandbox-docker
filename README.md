# Agentic Sandbox

A containerized environment for running AI coding agents (Claude Code, GitHub Copilot, Mistral Vibe) in isolated Docker containers. Agents get a full development environment without touching your host system.

## Features

- Isolated Docker containers with resource limits (8 GB RAM, 4 CPUs)
- Pre-installed runtimes: Python 3 (with `uv`), Node.js 22 LTS, npm/pnpm/yarn
- Optional language extensions: Go, Java, Rust
- Supports multiple AI providers: Anthropic, OpenAI, Mistral, GitHub
- Non-root `agent` user with sudo access
- Named Docker volumes for persistent, isolated agent config
- Bidirectional skill sync between host and container (`sync-skills`)
- HTTPS-only git access (SSH disabled for security)
- VS Code Dev Container support via `.devcontainer/devcontainer.json`

## Requirements

- Docker and Docker Compose
- API keys for the agents you want to use

## Quick Start

```bash
# 1. Copy and fill in your API keys
cp .env.example .env

# 2. Build the sandbox image
agent-sandbox build

# 3. Start a sandbox with your project directory
agent-sandbox start /path/to/your/project

# 4. Open an interactive shell inside the sandbox
agent-sandbox shell

# 5. Log in to your agents (first time only)
claude login
gh auth login
```

## Usage

```
agent-sandbox.sh <command> [options]

Commands:
  start <project-dir>       Launch a new sandbox for the given project
  shell [container]         Open an interactive shell in a running sandbox
  stop [container]          Stop a running sandbox container
  list                      List all running sandboxes
  build                     Build (or rebuild) the sandbox image
  extend <dockerfile>       Build an extended image from a language Dockerfile
  sync-skills [container]   Sync ~/.claude/skills between container and host

Options:
  -n, --name <name>         Custom container name
  -e, --env <VAR=value>     Pass extra environment variables
  --no-config               Skip mounting agent config volumes
```

## Git Identity

Set these environment variables on your host before starting the container:

```bash
export GIT_AUTHOR_NAME="Your Name"
export GIT_AUTHOR_EMAIL="you@example.com"
export GIT_COMMITTER_NAME="Your Name"
export GIT_COMMITTER_EMAIL="you@example.com"
```

Add them to your shell profile (`~/.bashrc`, `~/.zshrc`) to persist across sessions. Alternatively, your `~/.gitconfig` is mounted read-only into the container.

## Agent Authentication

All three coding agents (Claude Code, GitHub Copilot, Mistral Vibe) are installed on first container startup and store their config in shared named Docker volumes. Log in once from any sandbox and it persists across all sandboxes.

| Agent | Login command | Config volume |
|---|---|---|
| Claude Code | `claude login` | `agentic-sandbox-claude` |
| GitHub Copilot | `gh auth login` | `agentic-sandbox-copilot` |
| Mistral Vibe | Set `MISTRAL_API_KEY` in `.env` | `agentic-sandbox-vibe` |

```bash
# From inside any sandbox:
claude login          # one-time
gh auth login         # one-time
gh auth setup-git     # enables HTTPS git push/pull
```

This container uses HTTPS exclusively for git operations. SSH is not installed. If `GITHUB_TOKEN` (or `SANDBOX_GITHUB_TOKEN`) is set in your `.env`, it is used automatically for git credential auth.

## Skill Sync

Claude Code skills (slash commands) live in `~/.claude/skills/` on both host and container. Since skills on the host may be symlinks to other repos, they are resolved and copied (not mounted) using `sync-skills`:

```bash
# Interactive: shows what differs, lets you choose direction
agent-sandbox sync-skills

# Push all host skills into the container (resolves symlinks)
agent-sandbox sync-skills my-sandbox push

# Pull new container-only skills back to the host
agent-sandbox sync-skills my-sandbox pull
```

After starting a new sandbox, run `agent-sandbox sync-skills push` to populate it with your host skills.

## VS Code Dev Container

Open this project in VS Code with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) to use the sandbox as a devcontainer:

1. Open the project folder in VS Code
2. Click "Reopen in Container" when prompted (or run `Dev Containers: Reopen in Container` from the command palette)

The devcontainer configuration:
- Installs the Claude Code VS Code extension
- Enables `bypassPermissions` mode for Claude Code
- Passes git identity from host environment variables
- Disables SSH agent forwarding
- Uses named volumes for persistent config

## Language Extensions

Build on top of the base image to add more runtimes:

```bash
# Go
agent-sandbox extend extensions/go.Dockerfile

# Java (OpenJDK 21 + Maven + Gradle)
agent-sandbox extend extensions/java.Dockerfile

# Rust
agent-sandbox extend extensions/rust.Dockerfile
```

## Configuration

### API Keys

Copy `.env.example` to `.env` and fill in the keys for the services you use:

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
MISTRAL_API_KEY=...
GITHUB_TOKEN=ghp_...
```

The `.env` file is never committed to git.

### Read-only Git Access

To prevent agents from pushing to or merging into your repositories, use a read-only GitHub token. The agent can still clone, fetch, commit locally, and create branches — but pushes are rejected server-side, which no amount of sudo or hook bypassing can circumvent.

> **Important:** You need a **fine-grained** personal access token, not a classic token. Classic tokens (`ghp_...`) have coarse scopes — the `repo` scope grants both read and write, with no way to restrict to read-only. Fine-grained tokens (`github_pat_...`) allow per-repository, per-permission control.

1. Go to **GitHub Settings > Developer settings > Personal access tokens > Fine-grained tokens**
2. Create a new token with:
   - **Repository access**: **All repositories** (or select specific repos if you prefer)
   - **Contents**: **Read-only** (allows clone/fetch, denies push)
   - **Pull requests**: **Read-only** (optional, if the agent needs to read PRs)
3. Set this token as `SANDBOX_GITHUB_TOKEN` in your `.env`

The sandbox uses `SANDBOX_GITHUB_TOKEN` if set, falling back to `GITHUB_TOKEN`. This way your host keeps using your normal (read-write) token while the sandbox gets the restricted one.

The agent will have full local git capabilities (commit, branch, diff, log) but cannot modify any remote repository.

## Project Structure

```
.
├── .devcontainer/
│   └── devcontainer.json   # VS Code Dev Container config
├── Dockerfile              # Main sandbox image (Ubuntu 24.04)
├── docker-compose.yml      # Container orchestration with named volumes
├── entrypoint.sh           # Startup script (agent install, git auth)
├── agent-sandbox.sh            # CLI for managing sandboxes
├── .env.example            # API key template
└── extensions/
    ├── go.Dockerfile
    ├── java.Dockerfile
    └── rust.Dockerfile
```

## Security

- Containers run as a non-root `agent` user with passwordless sudo
- Agent config is stored in named Docker volumes, isolated from the host filesystem
- Host skills are copied via `sync-skills`, not mounted
- SSH is disabled (`openssh-client` not installed, `SSH_AUTH_SOCK` cleared)
- All git operations use HTTPS via `GITHUB_TOKEN` or `gh auth`
- Resource limits prevent runaway agent processes
- API keys are injected at runtime and never baked into images
- Agents are installed at first startup, not baked into the image (always latest version)

### Unpinned images

The base image (`ubuntu:24.04`) uses a mutable tag. To pin to a specific digest for reproducible builds:

```bash
docker pull ubuntu:24.04
docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04
```

Then update the Dockerfile:

```dockerfile
FROM ubuntu:24.04@sha256:<digest>
```

### Claude Code

When using the VS Code devcontainer, Claude Code runs with `bypassPermissions` mode and `allowDangerouslySkipPermissions` enabled. This means it can execute any command — including `sudo` — without user confirmation. Do not mount sensitive host directories or credentials into this container.
