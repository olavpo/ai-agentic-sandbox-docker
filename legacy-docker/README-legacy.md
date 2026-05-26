# Legacy Docker sandbox

This directory contains the previous Docker-based sandbox setup. It has been **superseded** by the sandbox-runtime approach at the root of this repo. These files are kept for reference and can be revived if you need:

- Kernel-level isolation (separate container, no shared host filesystem)
- Multi-agent support (Claude + GitHub Copilot + Mistral Vibe in the same env)
- A reproducible toolchain independent of the host
- Resource limits (memory/CPU caps)

## What's here

| File | Role |
|---|---|
| `Dockerfile` | Ubuntu 24.04 image with all agents and tools pre-installed |
| `docker-compose.yml` | Compose configuration with named volumes |
| `entrypoint.sh` | Container startup: installs agents, sets up git auth |
| `agent-sandbox.sh` | Original CLI: start/stop/shell/sync-skills/etc. |
| `extensions/` | Optional language extensions (Go, Java, Rust) |
| `.devcontainer/` | VS Code devcontainer config |
| `.env.example` | API key template |

## Reviving the Docker setup

If you ever want to switch back:

```bash
# From the repo root
cd legacy-docker
./agent-sandbox.sh build
./agent-sandbox.sh start /path/to/project
./agent-sandbox.sh shell
```

You'll likely want to retarget `/usr/local/bin/agent-sandbox` back to `legacy-docker/agent-sandbox.sh` as well.

## Why we moved away

The Docker setup worked but was heavy for the actual usage pattern:

- Image builds for every change
- Named volumes to manage
- `--network=host` was needed for Playwright UIs, which negated network isolation
- Playwright + chromium added 400 MB to the image
- Mostly only Claude was used; Copilot and Vibe were rarely touched

sandbox-runtime gives us the network restrictions we were missing, with much less overhead. See the root README for details.
