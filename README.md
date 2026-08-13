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
- Non-root `agent` user with passwordless sudo, or `--strict-sudo` for a sandbox where the agent cannot remove its own firewall
- Named Docker volumes for persistent, isolated agent config
- Bidirectional skill sync between host and container (`sync-skills`) — pushes only *symlinked* skills (those the ai-skills manager has enabled); marketplace plugins like superpowers are installed natively in the container instead (see "Claude plugins")
- HTTPS-only git access (SSH disabled for security)
- VS Code Dev Container support via `.devcontainer/devcontainer.json`
- Pre-published host port (`SANDBOX_HOST_PORT`) for agent-started servers the user wants to open in their browser
- Joinable to user-defined Docker networks for reaching dev containers (DHIS2, etc.) by name
- Optional DHIS2 instance broker integration: agents can create/reset/delete disposable `agent-*` DHIS2 test instances through a token-scoped HTTP API on the host (see "DHIS2 test instances")
- Optional Android emulator testing: agents drive an emulator on the host through its adb server — install APKs, take screenshots, tap/swipe/type (see `android-testing.md`)

## Requirements

- Docker and Docker Compose
- API keys for the agents you want to use

## Quick Start

```bash
# 1. Copy and fill in your API keys
cp .env.example .env

# 2. Build the sandbox image
agent-sandbox build

# 3. cd to your project and launch — sandbox is created/resumed automatically
cd ~/projects/my-app
sbx

# 4. Log in to your agents (first time only)
claude login
gh auth login
```

Symlinks in `/usr/local/bin` point into this directory:

```bash
ln -sfn ~/Repos/ai-sandbox-docker/agent-sandbox.sh /usr/local/bin/agent-sandbox
ln -sfn ~/Repos/ai-sandbox-docker/sbx /usr/local/bin/sbx
```

## Usage

```
agent-sandbox.sh <command> [options]

Commands:
  start <project-dir>       Launch a new sandbox for the given project
  shell [container]         Open an interactive shell in a running sandbox
  stop [container]          Stop a running sandbox (preserves container)
  remove <container>        Remove a sandbox container (preserves volumes)
  list                      List all sandboxes
  build                     Build (or rebuild) the sandbox image, dropping the
                            image it replaces when nothing still uses it
  extend <dockerfile>       Build an extended image from a language Dockerfile
  sync-skills [push|pull]   Sync ~/.claude/skills between container and host
  reset-config              Wipe all agent config volumes (with confirmation)

Options (for `start`):
  -n, --name <name>         Custom container name
  --agent <name>            claude (default), copilot, vibe, or all
  -e, --env <VAR=value>     Pass extra environment variables
  --network <name>          Attach to a Docker network (repeatable)
  -p, --port HOST:CONT      Publish an additional port (repeatable)
  --host-network            Opt out of bridge+firewall (legacy mode)
  --strict-sudo             No general root for the agent (see "Sudo modes")
  --no-strict-sudo          Keep general sudo (default)
  --no-config               Skip mounting agent config volumes
```

## Sudo modes

By default the agent has passwordless `sudo` inside the container. That is convenient — runtime `apt-get`, system tweaks — but it also means the agent can remove the egress firewall that is meant to contain it:

```bash
sudo iptables -P OUTPUT ACCEPT && sudo iptables -F OUTPUT   # unrestricted internet
sudo ipset add allowed-domains <ip>                         # allowlist any host
```

`--strict-sudo` takes that away per sandbox:

```bash
agent-sandbox start ~/Repos/my-app --strict-sudo
```

Set `SANDBOX_STRICT_SUDO=1` in `.env` to make it the default for every sandbox — including the ones `sbx` creates, since `sbx` goes through `agent-sandbox start` — and use `--no-strict-sudo` for a one-off exception.

| | Default | `--strict-sudo` |
|---|---|---|
| `sudo` for the agent | passwordless, unrestricted | denied |
| Firewall removable by the agent | yes | no |
| Runtime `apt-get` | works | **not available** |
| Runtime `npm install -g` | works | works (agent-writable prefix) |

**The tradeoff is runtime package installs.** A curated sudo allowlist is not a middle ground: `apt-get install` runs maintainer scripts as root, so any package-manager entry is equivalent to full root. In a strict sandbox anything the agent needs has to be in the image already, added via `agent-sandbox extend`, or installed from the host:

```bash
docker exec -u root <container> apt-get update && apt-get install -y <pkg>
```

That path goes through the same egress firewall, which is why the Ubuntu/Debian mirrors stay on the allowlist in `init-firewall.sh`.

The agent is told which mode it is in: the in-container brief has a different Permissions section for each, so a strict sandbox's agent doesn't waste turns on `sudo apt-get` and misread the failures.

### How it works

Privileged boot happens in `sandbox-privileged-boot.sh`, the single command the agent may run as root. It applies the sudo policy, publishes `/etc/sandbox-info` and initialises the firewall — and it takes **no** instructions from its caller. Two things make that necessary:

- Passing the broker/adb host:port config through `sudo env VAR=… init-firewall.sh` would require authorising `env`, which is equivalent to full root.
- Passing it as arguments would be worse: the agent can run the wrapper whenever it likes, so `--broker-url=http://attacker:80` would let it punch its own hole in the firewall.

So the wrapper reads its config from `/proc/1/environ`. PID 1's environment is fixed by `docker run` at container creation and cannot be altered from inside, which is what makes it trustworthy. Reading another user's environ is a ptrace-mode access, so the container is given `SYS_PTRACE`; that grants the agent nothing, since capabilities belong to processes and the agent is either not root (strict) or already root (default).

The mode is re-applied on every boot rather than being a one-way change to the container. That matters: the container filesystem persists across `stop`/`start`, so a sandbox that dropped sudo once and never restored the sudoers entry would fail its next firewall init — and with the firewall failing closed, would never boot again.

## Everyday use: `sbx`

`sbx` is the daily driver: cd to a project, run `sbx`, land in Claude Code.

```bash
cd ~/projects/my-app
sbx                # create-or-resume "sbx-my-app", launch claude
                   #   (--continue when the project has session history)
sbx new            # fresh claude session (no --continue)
sbx shell          # bash shell instead of claude
sbx list           # all sandboxes: name, status, project path
sbx --agent vibe   # another agent (claude is the default)
```

Sandboxes are named after the project directory (`~/projects/my-app` →
`sbx-my-app`); the absolute project path is stored as a Docker label, and a
short path hash is appended if two projects share a basename. When the last
interactive session exits, the sandbox is **stopped automatically** — not
removed, so container state and volumes persist and the next `sbx` resumes
where you left off.

Inside the container the project is mounted at its full host path (e.g.
`/Users/you/projects/my-app`), so Claude's per-project session history —
which is keyed by path in the shared config volume — never collides between
projects, even when two projects share a basename.

Management stays in `agent-sandbox` (`build`, `stop`, `remove`,
`sync-skills`, `reset-config`). To create a sandbox with non-default options
(extra networks, ports), use `agent-sandbox start -n <name>` with the name
`sbx` would derive — `sbx` will then find and reuse it.

## Choosing an agent

`--agent NAME` controls which AI coding agent gets installed and which config volume gets mounted. The image bundles the runtimes for all three (Python+uv, Node.js, npm), but only the chosen agent is actually installed at first container start and only its config volume is mounted.

| Agent | Install | Config volume mounted | Notes |
|---|---|---|---|
| `claude` (default) | `curl https://claude.ai/install.sh \| bash`, npm fallback | `agentic-sandbox-claude` → `~/.claude` | Default; most uses |
| `copilot` | `npm install -g @github/copilot` | `agentic-sandbox-copilot` → `~/.copilot` | GitHub Copilot CLI |
| `vibe` | `uv tool install mistral-vibe` | `agentic-sandbox-vibe` → `~/.vibe` | Mistral Vibe |
| `all` | All three | All three | Backward-compat behavior |

Each agent's auth/state lives in its named volume, so logging in once persists across all `--agent <same>` sandboxes. Switching agents between sessions doesn't lose state for the others — their volumes stay intact, just not mounted.

## Networking and host-visible ports

By default the sandbox uses **bridge networking with an egress firewall** that drops outbound traffic to anything not on the allowlist. The container starts an iptables firewall at boot (verified by trying to reach `example.com`, which must fail, and `api.anthropic.com`, which must succeed).

The firewall **fails closed**: if init fails (no `NET_ADMIN`, a DNS hiccup, an unreachable GitHub API), the container refuses to start rather than coming up with unrestricted egress. Use `--host-network` when you deliberately want no firewall.

The launchers also **wait for the firewall before attaching**. `docker start` returns before the entrypoint has finished configuring iptables, and `docker exec` bypasses the entrypoint's ordering entirely, so without this a session could be live while egress was still open — a 2–4 s window on every start, not just first creation. The entrypoint clears `/tmp/sandbox-firewall-ready` on boot and writes it once egress is filtered; `sbx` and `agent-sandbox` block on that marker (90 s timeout).

**DNS is restricted to the container's own resolver.** A rule matching only on port 53 would let any unprivileged process reach any nameserver on the internet and tunnel data out past the allowlist. On a user-defined network (`dev-net`) the resolver is Docker's embedded one on `127.0.0.11`, reached over loopback; on the default bridge the external resolver from `/etc/resolv.conf` gets an explicit rule. Residual risk worth knowing: that resolver is recursive, so lookups of an attacker-controlled domain are still forwarded upstream. Pinning the destination removes the trivial channel, not DNS tunnelling in general — closing that needs a filtering resolver, not iptables.

To make a server the agent starts visible in your host browser, `agent-sandbox start` pre-publishes a random port from `49200–49300` and exposes it inside the container as:

- the `SANDBOX_HOST_PORT` environment variable
- `/etc/sandbox-info` (a single-line plain-text dump for tools that don't read env)

```bash
# Inside the sandbox:
python -m http.server "$SANDBOX_HOST_PORT"
# Then on the host: open http://localhost:<that-port>
```

The port is **container-scoped**, not written into the shared `~/.claude` volume — each sandbox gets its own random port and won't clobber another sandbox's hint. To tell Claude about the port, either mention it in your prompt ("start the visual companion on `$SANDBOX_HOST_PORT`") or add a hint to a project-level `CLAUDE.md` in repos that regularly need it.

The sandbox is automatically attached to a Docker user-defined network called **`dev-net`** (auto-created on first start). Put any sibling dev containers (DHIS2, dev DBs, MCP servers wrapped in containers) on the same network and the sandbox reaches them by container name:

```bash
docker run -d --name dhis2 --network dev-net dhis2/core:...
agent-sandbox start ~/Repos/dhis2-app
# Inside: curl http://dhis2:8080/api/me   (resolves via Docker DNS)
```

Pass `--no-dev-net` to skip this and use only the default Docker bridge. Pass `--network OTHER` to attach to additional networks on top of dev-net.

See `dev-net.md` for the full design including DHIS2 docker-compose patterns and CORS/auth notes.

### MCP servers

Stdio-type MCP servers configured on the host (e.g. `python -m my_mcp` spawned by Claude) cannot be invoked across the container boundary — the host's paths and binaries aren't visible inside the container.

Two practical patterns inside the sandbox:

- **Install the MCP server inside the container.** Add the pip/npm install to the Dockerfile or run it manually inside the sandbox; configure Claude's `mcpServers` to point at the in-container binary. Auth/state goes in the agent's named volume.
- **Wrap the MCP server as a container on `dev-net`.** Run it once with `--network dev-net --name my-mcp`. Switch it to an HTTP transport and configure Claude to reach `http://my-mcp:PORT`.

See `dev-net.md` for the full discussion.

### Claude plugins

Marketplace plugins (e.g. [superpowers](https://github.com/anthropics/claude-plugins-official)) are installed **natively** in the container, not synced from the host. On first `claude`/`all` start the entrypoint runs `claude plugin marketplace add` + `claude plugin install` for a configurable set; the marketplace is a public GitHub repo, which the egress firewall already allows. Skills then load namespaced (`superpowers:brainstorming`) and update with the plugin. Plugin state persists in the `agentic-sandbox-claude` volume, and the install commands are idempotent so they're cheap to re-run each boot.

Defaults install the superpowers skill set. Override at start:

```bash
# add more plugins / marketplaces (space-separated plugin@marketplace ids)
agent-sandbox start ~/Repos/app -e SANDBOX_CLAUDE_PLUGINS="superpowers@claude-plugins-official other@mkt"
# or disable plugin install entirely
agent-sandbox start ~/Repos/app -e SANDBOX_CLAUDE_PLUGINS=
```

This is why `sync-skills` only pushes *symlinked* skills: the real (non-symlink) directories in `~/.claude/skills` are plugin-materialized copies, and the sandbox gets those from the plugin instead.

### DHIS2 test instances (d2-broker)

If the host runs [`d2-broker`](https://github.com/olavpo/dhis2-docker-tools) (from the dhis2-docker-tools repo), agents in the sandbox can ask the host to create, reset, start/stop and delete **disposable DHIS2 test instances** — without any host shell or Docker access.

Wiring is automatic: when `$DHIS2_BASE/_broker/tokens.json` exists on the host, `agent-sandbox start` passes the **agent-scoped** token into the container (`DHIS2_BROKER_URL` + `DHIS2_BROKER_TOKEN`), and the firewall opens egress to that single `host.docker.internal` port only. Opt out with `--no-dhis2-broker`.

The agent token is restricted by the broker itself: only instances named `agent-*`, only curated seed databases from `$DHIS2_BASE/_seeds/` (never real-data backups, host paths, or URLs), and a cap on concurrent instances. Created instances join `dev-net`, so the agent reaches them at `http://dhis2-<name>:8080`. See section 9 of `dev-net.md` and `broker.md` in dhis2-docker-tools.

One-time host setup:

```bash
d2-broker install    # launchd service on port 9300 + tokens + Claude skill
```

### Android emulator testing (adb)

If an adb server is listening on the host (port 5037), `agent-sandbox start` passes `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037` into the container and the firewall opens egress to that single port. The in-container `adb` client reads the variable natively, so the agent can install APKs on the host's Android emulator, take screenshots, inspect the UI hierarchy and tap/swipe/type — enough to test the DHIS2 Android app against a broker-created DHIS2 instance (which the app reaches at `http://10.0.2.2:<http_port>`). Opt out with `--no-adb`.

Host setup (emulator install, adb launchd service, getting the APK): see `android-testing.md`.

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

Each agent's auth lives in its named Docker volume. Log in once from any sandbox using that agent and it persists across all subsequent sandboxes with the same `--agent` choice.

| Agent | `--agent` | Login command | Config volume |
|---|---|---|---|
| Claude Code | `claude` (default) | `claude login` | `agentic-sandbox-claude` |
| GitHub Copilot | `copilot` | `copilot` then follow prompts | `agentic-sandbox-copilot` |
| Mistral Vibe | `vibe` | `MISTRAL_API_KEY` in `.env` | `agentic-sandbox-vibe` |

## GitHub Token

The container uses HTTPS for git operations (SSH is not installed).

Sandboxes only ever receive the dedicated `SANDBOX_GITHUB_TOKEN` from your `.env`. Your personal `GITHUB_TOKEN` is **never** passed in — if it's set but `SANDBOX_GITHUB_TOKEN` isn't, the launcher prints a note and the sandbox gets no GitHub access. This guarantees agents can't inherit broader scopes than the dedicated token grants.

### Creating the read-only token

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

### Image housekeeping

Rebuilding moves the `agentic-sandbox:latest` tag to the new image and leaves the previous one untagged — a `<none>:<none>` entry of ~2.7 GB in Docker Desktop. `build` now removes the image it replaced automatically.

It can only do that when nothing references the old image, and **stopped sandboxes still count**. `sbx` stops containers rather than removing them so sessions stay resumable, so old sandboxes accumulate and pin the image they were created from. When a rebuild reports:

```
Previous image kept — still used by: sbx-foo sbx-bar ...
```

that is the reason. Reclaim the space by removing sandboxes you're done with, after which the next build drops the image:

```bash
agent-sandbox list                  # see what exists
agent-sandbox remove sbx-old-thing  # container only; config volumes are kept
```

The prune is deliberately scoped to this image — it never runs `docker image prune`, which would also delete unrelated dangling images from your other projects.

## Project Structure

```
.
├── sbx                     # One-command launcher (the daily driver)
├── agent-sandbox.sh        # CLI for managing sandboxes
├── Dockerfile              # Main sandbox image (Ubuntu 24.04)
├── docker-compose.yml      # Compose with named volumes
├── entrypoint.sh           # Startup: installs agents, sets up git auth
├── .devcontainer/          # VS Code Dev Container config
├── .env.example            # API key template
├── extensions/             # Optional language Dockerfiles
├── tests/                  # Unit tests for sbx naming helpers
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
- **Egress firewall on by default**: outbound traffic restricted to an explicit allowlist (Anthropic, GitHub, npm, pypi, dhis2.org, dev CDNs). Adapted from [Anthropic's reference dev container](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh) with extensions for our domain list and Docker-network handling. Verified at every container start, **fails closed** if init fails, DNS is pinned to the container's own resolver, and the launchers refuse to attach until egress is actually filtered. Bypass with `--host-network` if needed.
- **Self-healing firewall**: the background refresh loop re-checks the rules, not just the allowlist, and re-applies the full policy if they have been flushed or weakened — so a sandbox that lost its firewall is re-fenced within one interval (default 300 s) instead of staying open until it is next recreated. The repair reuses the allowlist it already resolved, because re-resolving needs exactly the working egress that is broken at that moment.
- **Optional strict sudo** (`--strict-sudo`, or `SANDBOX_STRICT_SUDO=1` in `.env`): removes the agent's general root so the firewall cannot be removed from inside. Off by default; costs runtime `apt-get`. See "Sudo modes" above. In the default mode the firewall stops accidental and injected egress, not an agent that deliberately sets out to defeat it — the self-healing loop makes that tamper-evident rather than tamper-proof.

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
| Project mount | Full host path (unique per project) | `/workspace` |
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
