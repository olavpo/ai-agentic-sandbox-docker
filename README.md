# Agentic Sandbox

A Docker-based sandbox for running AI coding agents (Claude Code, GitHub Copilot, Mistral Vibe) in isolated containers. Agents get a full dev environment without touching your host.

## Status

This repo currently uses the **Docker setup at the root** as the active path. A lighter `sandbox-runtime`-based alternative is parked under `sandbox-runtime/` and will be promoted to the active path once [upstream issue #76](https://github.com/anthropic-experimental/sandbox-runtime/issues/76) (TTY passthrough on macOS) is resolved. See `sandbox-runtime/KNOWN-ISSUES.md` for the details.

## Features

- Isolated Docker containers with resource limits (8 GB RAM, 4 CPUs)
- **Egress firewall** dropping outbound traffic to anything outside an allowlist (Anthropic, GitHub, npm, pypi, dhis2.org, dev CDNs)
- Pre-installed runtimes: Python 3 (with `uv`), Node.js 22 LTS, npm/pnpm/yarn
- Pre-installed Playwright + chromium with all Ubuntu 24.04 system deps
- Optional language extensions: Go, Java, Rust
- Multiple AI providers: Anthropic, OpenAI, Mistral, GitHub
- Non-root `agent` user with passwordless sudo
- Named Docker volumes for persistent, isolated agent config
- Bidirectional skill sync between host and container (`sync-skills`)
- HTTPS-only git access (SSH disabled for security)
- VS Code Dev Container support via `.devcontainer/devcontainer.json`
- Pre-published host port (`SANDBOX_HOST_PORT`) for agent-started servers the user wants to open in their browser
- Joinable to user-defined Docker networks for reaching dev containers (DHIS2, etc.) by name

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

The `/usr/local/bin/agent-sandbox` symlink points to `agent-sandbox.sh` in this directory.

## Usage

```
agent-sandbox.sh <command> [options]

Commands:
  start <project-dir>       Launch a new sandbox for the given project
  shell [container]         Open an interactive shell in a running sandbox
  stop [container]          Stop a running sandbox (preserves container)
  remove <container>        Remove a sandbox container (preserves volumes)
  list                      List all sandboxes
  build                     Build (or rebuild) the sandbox image
  extend <dockerfile>       Build an extended image from a language Dockerfile
  sync-skills [push|pull]   Sync ~/.claude/skills between container and host
  reset-config              Wipe all agent config volumes (with confirmation)

Options (for `start`):
  -n, --name <name>         Custom container name
  -e, --env <VAR=value>     Pass extra environment variables
  --network <name>          Attach to a Docker network (repeatable)
  -p, --port HOST:CONT      Publish an additional port (repeatable)
  --host-network            Opt out of bridge+firewall (legacy mode)
  --no-config               Skip mounting agent config volumes
```

## Networking and host-visible ports

By default the sandbox uses **bridge networking with an egress firewall** that drops outbound traffic to anything not on the allowlist. The container starts an iptables firewall at boot (verified by trying to reach `example.com`, which must fail, and `api.anthropic.com`, which must succeed).

To make a server the agent starts visible in your host browser, `agent-sandbox start` pre-publishes a random port from `49200–49300` and exposes it as `SANDBOX_HOST_PORT` inside the container. The entrypoint also writes a snippet to `~/.claude/CLAUDE.md` telling Claude to use that port for any browser-facing service:

```bash
# Inside the sandbox:
python -m http.server "$SANDBOX_HOST_PORT"
# Then on the host: open http://localhost:<that-port>
```

To join another Docker network (so the sandbox can reach e.g. a DHIS2 dev container by name):

```bash
docker network create dev-net   # one time
docker run -d --name dhis2 --network dev-net dhis2/core:...
agent-sandbox start ~/Repos/dhis2-app --network dev-net
# Inside: curl http://dhis2:8080/api/me   (resolves via Docker DNS)
```

See `dev-net.md` for the full design including DHIS2 docker-compose patterns and CORS/auth notes.

If you need a specific extra port forwarded:

```bash
agent-sandbox start ~/Repos/my-app -p 5173:5173
```

To bypass the firewall entirely (e.g. for debugging, or when you need broad network access):

```bash
agent-sandbox start ~/Repos/my-app --host-network
# This re-enables --network=host and disables the firewall.
# SANDBOX_HOST_PORT is not set in this mode (no port forwarding needed).
```

## Agent Authentication

All three agents store auth in shared named Docker volumes. Log in once from any sandbox and it persists across all subsequent sandboxes.

| Agent | Login command | Config volume |
|---|---|---|
| Claude Code | `claude login` | `agentic-sandbox-claude` |
| GitHub Copilot | `gh auth login` | `agentic-sandbox-copilot` |
| Mistral Vibe | `MISTRAL_API_KEY` in `.env` | `agentic-sandbox-vibe` |

## GitHub Token

The container uses HTTPS for git operations (SSH is not installed).

Set either `GITHUB_TOKEN` or `SANDBOX_GITHUB_TOKEN` in your `.env`. If both are set, `SANDBOX_GITHUB_TOKEN` wins inside the container. This lets you keep a read-write `GITHUB_TOKEN` for your host and a read-only `SANDBOX_GITHUB_TOKEN` for the agent.

### Read-only token (recommended)

To prevent the agent from pushing or merging, use a **fine-grained** GitHub PAT:

1. GitHub Settings → Developer settings → **Fine-grained tokens**
2. **Repository access**: All repositories
3. **Permissions → Contents**: **Read-only**
4. Set as `SANDBOX_GITHUB_TOKEN` in your `.env`

Local git ops (commit, branch, diff, log) and clone/fetch/pull still work — only remote pushes are blocked, enforced server-side.

## Skill Sync

Claude Code skills (slash commands) live in `~/.claude/skills/` on host and container. Host skills are often symlinks to other repos, so they're resolved and copied via `sync-skills` rather than mounted:

```bash
agent-sandbox sync-skills              # interactive: shows diff, choose direction
agent-sandbox sync-skills push         # push host skills into running sandbox
agent-sandbox sync-skills pull         # pull container skills back to host
```

After starting a new sandbox, run `agent-sandbox sync-skills push` to populate it.

## VS Code Dev Container

Open this project in VS Code with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers):

1. Open the folder in VS Code
2. Click **Reopen in Container** when prompted

The devcontainer config:
- Installs the Claude Code VS Code extension
- Enables `bypassPermissions` mode
- Passes git identity from host env vars
- Disables SSH agent forwarding
- Uses named volumes for persistent config

## Language Extensions

```bash
agent-sandbox extend extensions/go.Dockerfile
agent-sandbox extend extensions/java.Dockerfile
agent-sandbox extend extensions/rust.Dockerfile
```

## Configuration

### API Keys

Copy `.env.example` to `.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
MISTRAL_API_KEY=...
SANDBOX_GITHUB_TOKEN=github_pat_...
```

## Project Structure

```
.
├── agent-sandbox.sh        # CLI for managing sandboxes
├── Dockerfile              # Main sandbox image (Ubuntu 24.04)
├── docker-compose.yml      # Compose with named volumes
├── entrypoint.sh           # Startup: installs agents, sets up git auth
├── .devcontainer/          # VS Code Dev Container config
├── .env.example            # API key template
├── extensions/             # Optional language Dockerfiles
└── sandbox-runtime/        # PARKED: lighter sandbox-runtime alternative
    ├── KNOWN-ISSUES.md     #   reason it's not active (upstream TUI bug)
    └── ...
```

## Security

- Containers run as non-root `agent` user with passwordless sudo
- Agent config in named Docker volumes, isolated from host filesystem
- Host skills copied via `sync-skills`, not mounted
- SSH disabled (no `openssh-client`, `SSH_AUTH_SOCK` cleared)
- All git via HTTPS using `GITHUB_TOKEN`
- Resource limits prevent runaway agent processes
- API keys injected at runtime, never baked into images
- **Egress firewall on by default**: outbound traffic restricted to an explicit allowlist (Anthropic, GitHub, npm, pypi, dhis2.org, dev CDNs). Adapted from [Anthropic's reference dev container](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh) with extensions for our domain list and Docker-network handling. Verified at every container start. Bypass with `--host-network` if needed.

### Read-only base image

To pin `ubuntu:24.04` to a specific digest for reproducible builds:

```bash
docker pull ubuntu:24.04
docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04
# Then edit Dockerfile: FROM ubuntu:24.04@sha256:<digest>
```

## Comparison with Anthropic's reference dev container

Anthropic publishes a reference dev container at [anthropics/claude-code/.devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer). The main differences:

| | This setup | Anthropic reference |
|---|---|---|
| Base image | `ubuntu:24.04` | `node:20` |
| Agents | Claude + Copilot + Vibe | Claude only |
| Toolchain | Python, Node, uv, Playwright + chromium, language extensions available | Node + general dev tools |
| Network | bridge + iptables egress firewall | bridge + iptables egress firewall |
| Egress allowlist | Anthropic + GitHub + npm + pypi + dhis2 + dev CDNs | Anthropic + GitHub + npm + sentry + vscode marketplace |
| Volume isolation | Shared across all sandboxes (log in once) | Per-`${devcontainerId}` (re-login per project) |
| Project mount | `/<project-name>` | `/workspace` |
| Skills sync | Bidirectional `sync-skills` command | n/a (Claude-only image) |
| Host-visible port | Random `SANDBOX_HOST_PORT` from 49200-49300, auto-published | Manual port forwarding via VS Code |
| Joinable to user networks | `--network dev-net` flag | n/a |
| INPUT chain | ACCEPT (port forwarding from host works) | DROP (no port forwarding needed) |

**Differences worth noting:**
- We keep INPUT ACCEPT because the user often wants to reach a sandbox-started server from their host browser; Anthropic's setup uses VS Code's remote-container protocol and doesn't need it.
- Our allowlist includes pypi (for Python agents) and dhis2 (the user's primary domain).
- Shared auth volume + multi-agent + Ubuntu base are deliberate differences from Anthropic's minimal-Claude-only design.

## License

BSD 3-Clause. See `LICENSE`.
