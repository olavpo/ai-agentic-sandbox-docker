# Why this isn't the active path

This directory holds a working sandbox-runtime (`srt`) wrapper for Claude Code. It is **not** currently the recommended way to run Claude on this machine, because of a known upstream bug that prevents Claude's TUI from working on macOS.

## The blocker: srt issue #76

Running Claude interactively under srt on macOS fails. The TUI starts but cannot enter raw mode, so keypresses (arrows, Enter, Esc, Ctrl-C) leak through to the screen as literal escape sequences and Claude never receives input.

Root cause: `setRawMode` requires `TIOCGETD`/`TIOCSETD` ioctls on the TTY, which macOS Seatbelt blocks under the dynamic profile srt generates. There is no settings key to allow it.

Upstream: [anthropic-experimental/sandbox-runtime#76 — Feature Request: TTY passthrough for interactive terminal applications](https://github.com/anthropic-experimental/sandbox-runtime/issues/76). Open since 2025-12-22, no Anthropic response or fix at time of writing.

## How to verify the bug is still present

```bash
cd /tmp
srt --settings ~/Repos/ai-agentic-sandbox/sandbox-runtime/settings/default.json -- bash -c 'stty raw 2>&1; echo "exit=$?"; stty sane'
```

Expected if still broken: `stty: TIOCGETD: Operation not permitted` and exit=1.
Expected if fixed: empty output and exit=0.

If the test passes, then `srt -- claude` should work and this directory can be promoted back to the active path (see "Reviving this setup" below).

## What's here

| File | Role |
|---|---|
| `agent-sandbox.sh` | Wrapper around `srt` with env scrubbing, settings resolution, denyWrite self-protection |
| `settings/default.json` | Moderate filesystem allowlist + network domain allowlist |
| `settings/strict.json` | Minimal allowlist (Anthropic + npm + dhis2 only) |
| `README.md` | Full documentation of the sandbox-runtime approach |

## Reviving this setup

When upstream fixes #76:

```bash
# Swap the layouts: srt to root, Docker to legacy-docker
git mv Dockerfile docker-compose.yml entrypoint.sh agent-sandbox.sh \
       extensions .devcontainer .env.example legacy-docker/
git mv sandbox-runtime/agent-sandbox.sh sandbox-runtime/settings .
git mv sandbox-runtime/README.md README.md

# Re-test
agent-sandbox doctor
agent-sandbox claude --version       # should report Claude's version
agent-sandbox                        # should launch Claude's TUI and accept input
```

The `/usr/local/bin/agent-sandbox` symlink already points at the repo's root `agent-sandbox.sh`, so no symlink retargeting is needed.

## Tested working (the parts srt does support today)

- Filesystem allow/deny enforced
- Network domain allowlist enforced
- Env scrubbing via `env -i` baseline + `_passEnv`
- `SANDBOX_GITHUB_TOKEN` → `GITHUB_TOKEN` renaming
- Self-edit protection of the settings file (`denyWrite` auto-injection)
- Non-interactive commands like `agent-sandbox bash -c '...'` or `agent-sandbox claude --print '...'`

The TUI issue is the only blocker.
