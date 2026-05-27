# Agentic Sandbox

A Docker-based sandbox for running AI coding agents (Claude Code, GitHub Copilot, Mistral Vibe) in isolated containers. Agents get a full dev environment without touching your host.

## Status

This repo currently uses the **Docker setup at the root** as the active path. A lighter `sandbox-runtime`-based alternative is parked under `sandbox-runtime/` and will be promoted to the active path once [upstream issue #76](https://github.com/anthropic-experimental/sandbox-runtime/issues/76) (TTY passthrough on macOS) is resolved. See `sandbox-runtime/KNOWN-ISSUES.md` for the details.

## Features

- Isolated Docker containers with resource limits (8 GB RAM, 4 CPUs)
- Pre-installed runtimes: Python 3 (with `uv`), Node.js 22 LTS, npm/pnpm/yarn
- Pre-installed Playwright + chromium with all Ubuntu 24.04 system deps
- Optional language extensions: Go, Java, Rust
- Multiple AI providers: Anthropic, OpenAI, Mistral, GitHub
- Non-root `agent` user with passwordless sudo
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

Options:
  -n, --name <name>         Custom container name
  -e, --env <VAR=value>     Pass extra environment variables
  --no-config               Skip mounting agent config volumes
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

### Known gap: network egress is unrestricted

The container currently uses `--network=host`, so outbound traffic from the agent is not restricted. This is convenient (Playwright UIs accessible on host browser, no port-forwarding) but means a compromised agent could exfiltrate to any host.

Anthropic's reference dev container ships an [iptables-based egress firewall](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh) that drops all outbound except an allowlist. Adopting that would require switching back to bridge networking and adding `NET_ADMIN`/`NET_RAW` capabilities. See the "Comparison with Anthropic's reference" section below.

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
| Network | `--network=host` (open) | bridge + iptables egress firewall |
| Volume isolation | Shared across all sandboxes (log in once) | Per-`${devcontainerId}` (re-login per project) |
| Project mount | `/<project-name>` | `/workspace` |
| Skills sync | Bidirectional `sync-skills` command | n/a (Claude-only image) |
| Firewall verification | n/a | actively verifies at start (curl example.com fails, api.github.com works) |

**Worth adopting from Anthropic:**
- **iptables egress firewall** — biggest security improvement, drops unauthorized outbound traffic. Implementation in their `init-firewall.sh` is solid: dynamic GitHub IP range fetch, explicit allowlist of npmjs/anthropic/sentry/statsig/vscode, DNS + localhost + SSH allowed, default DROP. The trade-off is switching back to bridge networking (loses easy Playwright UI access) and adding `NET_ADMIN`/`NET_RAW` caps.
- **Firewall verification at startup** — runs after every container start, fails fast if rules don't take effect.
- **Per-project volume IDs via `${devcontainerId}`** — stronger isolation if you want it; trade-off is more frequent re-auth.

**Worth keeping different:**
- Ubuntu base over node:20 — supports the multi-language toolchain.
- Shared auth volume — saves re-login across projects.
- Multi-agent support — useful even though Claude is dominant.
- Playwright pre-installed — saves ~2 min of setup on first webapp-testing use.

## License

BSD 3-Clause. See `LICENSE`.
