# Design: `sbx` — one-command project sandboxes

**Date:** 2026-07-15
**Status:** Approved

## Problem

The daily workflow for launching an agent sandbox requires too many decisions:
picking a container name, remembering `agent-sandbox start <dir> -n <name>` vs
`claude-sandboxed <name>`, and manually stopping the sandbox afterwards. The
desired workflow is: `cd` to the project, type one command, land in Claude
Code. No naming, no cleanup.

## Solution overview

A new `sbx` script in this repo, symlinked to `/usr/local/bin/sbx`. It is a
thin launcher over `agent-sandbox`, which remains the management layer
(`build`, `extend`, `sync-skills`, `reset-config`, `stop`, `remove`, `list`).

```
sbx                # create-or-resume sandbox for $(pwd), launch claude
                   #   (--continue when session history exists)
sbx new            # same, but force a fresh claude session (no --continue)
sbx shell          # same, but drop into bash instead of claude
sbx list           # all sandboxes: name, status, project path
sbx --agent vibe   # escape hatch for other agents (not the daily path)
```

`sbx` accepts `--agent <name>` before or after the subcommand; default is
`claude`.

## Naming (automatic)

- Container name derived from the project directory basename, sanitized to
  valid Docker name characters, prefixed: `~/Repos/my-app` → `sbx-my-app`.
  Sanitization: lowercase, replace any character outside `[a-z0-9_.-]` with
  `-`, trim leading/trailing separators.
- The absolute project path is stored as a Docker label
  (`agentic-sandbox-project=<path>`) at creation time. This requires a
  one-line addition to `cmd_start` in `agent-sandbox.sh` (label every
  container with its project path — useful for troubleshooting generally).
- Collision rule: if a container with the derived name exists but its
  project label differs from `$(pwd)`, append a short hash of the absolute
  path (first 4 hex chars of its sha256): `sbx-app-3fa2`.
- The user never types a name. `sbx list` shows `NAME  STATUS  PROJECT`
  (project read from the label) for troubleshooting. Removal and volume
  cleanup stay in `agent-sandbox remove` / `agent-sandbox reset-config`.

## Launch behavior

Same state machine as the previous `sandboxed.sh`:

1. Container running → `docker exec` straight in.
2. Container exists, stopped → `docker start`, then exec in.
3. No container → `agent-sandbox start "$(pwd)" -n <derived-name>
   --agent <agent>`, then exec in.

Exec details:

- The project is mounted at its **full host path** inside the container
  (`~/work/app` → `/Users/you/work/app`), passed in as `PROJECT_DIR`. The
  in-container path keys Claude Code's per-project session history in the
  shared config volume, so it must be unique per project — basename-only
  mounts made same-basename projects share (and cross-contaminate) session
  history. *(Revised 2026-07-15; originally `/$PROJECT_NAME`.)*
- Working directory inside the container is `$PROJECT_DIR`, falling back to
  the legacy `/$PROJECT_NAME` for containers created before the revision.
- Claude runs as `/home/agent/.local/bin/claude --dangerously-skip-permissions`.
- Default mode decides `--continue` by checking inside the container whether
  the project has prior Claude session history (a non-empty
  `~/.claude/projects/<munged-project-path>/` directory). History →
  `claude --continue`; none → plain `claude`. This avoids the "no
  conversation found" error on first run.
- `sbx new` always launches plain `claude`.
- `sbx shell` launches `/bin/bash -l` instead of the agent.
- `agent-sandbox start` is invoked with its existing defaults (dev-net,
  firewall, published ports, DHIS2 broker, adb detection); `sbx` adds no new
  start-time options. For non-default networking or ports, use
  `agent-sandbox start` directly — `sbx` will then find and reuse that
  container only if it was created with the sbx-derived name and project
  label.

## Auto-stop

When the interactive session launched by `sbx` exits:

- Count the distinct PTYs in use by live processes in the container
  (`ps -eo tty=`), not device nodes under `/dev/pts` — a just-exited
  session's device node lingers for a second or two after `docker exec`
  returns, which made a session count itself on the way out. *(Revised
  2026-07-15; originally `ls /dev/pts` minus `ptmx`.)*
- If zero remain (ours was the last interactive session), `docker stop` the
  container. Stopped, not removed — volumes and container state persist.
- If other sessions remain (e.g. a second terminal ran `sbx shell`), leave
  the container running. The last session out stops it.
- If the PTY check itself fails (container already gone, docker error), skip
  the stop silently — never block the user's shell on cleanup.

## Cleanup of old surface

- Delete `sandboxed.sh`; remove the `claude-sandboxed` and `vibe-sandboxed`
  symlinks from `/usr/local/bin` (documented as a manual step in the README,
  since the repo cannot assume symlink locations).
- `agent-sandbox.sh` is unchanged in behavior apart from the new
  `agentic-sandbox-project` label. README rewritten around the
  `sbx` workflow, with `agent-sandbox` presented as the management/
  troubleshooting layer.
- Existing containers created under old names keep working but won't match
  sbx's derived names; users remove strays once with `agent-sandbox remove`.

## Error handling

- `sbx` run outside a directory (or in a directory that no longer exists)
  fails with a clear message.
- `sbx` in a directory that is not the project root still works — the
  sandbox mounts `$(pwd)` — but each distinct directory gets its own
  sandbox. This is by design (no attempt to find a repo root).
- Docker not running → surface docker's error, exit non-zero.
- Unknown subcommand/flag → usage text, exit non-zero.

## Testing

- Shell-level manual test matrix (documented in the PR/commit, not
  automated): fresh create, resume stopped, attach running, `new`, `shell`,
  two-terminal auto-stop (last-one-out), collision naming (two dirs with the
  same basename), `sbx list` output.
- `bash -n` / shellcheck pass on the new script.

## Out of scope (YAGNI)

- No per-sandbox config files.
- No auto-remove of containers.
- No sbx subcommands duplicating agent-sandbox management (stop/remove/
  build/sync-skills stay where they are).
- No repo-root detection.
