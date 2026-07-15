# `sbx` One-Command Sandbox Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single `sbx` command that, run from any project directory, creates-or-resumes that project's sandbox, drops the user into Claude Code (`--continue` when history exists), and auto-stops the sandbox when the last interactive session exits.

**Architecture:** `sbx` is a new standalone bash launcher script at the repo root, layered on top of the existing `agent-sandbox.sh` (which stays the management tool: build, stop, remove, sync-skills, reset-config). Container names are derived from the project directory basename; the absolute project path is stored as a Docker label for collision detection and listing. The old `sandboxed.sh` wrapper is deleted.

**Tech Stack:** Bash (must run on macOS's default bash 3.2), Docker CLI, `shasum`. Spec: `docs/superpowers/specs/2026-07-15-sbx-launcher-design.md`.

## Global Constraints

- Bash 3.2 compatible: no `${var,,}`, no associative arrays, no `mapfile`. Use `tr`/`sed` for case/character mapping.
- Docker label key for the project path is exactly `agentic-sandbox-project`; its value is the absolute project directory path.
- Container name pattern: `sbx-<sanitized basename>`, collision suffix `-<first 4 hex chars of sha256 of absolute path>`.
- Claude runs as `/home/agent/.local/bin/claude --dangerously-skip-permissions` (full path — non-interactive exec has no alias expansion).
- Auto-stop = `docker stop` (never `docker rm`).
- Cleanup code must never block the user's shell: every docker call in the stop path tolerates failure.
- The repo checkout lives at `~/Repos/ai-sandbox`.

---

### Task 1: Project-path label on all sandbox containers

**Files:**
- Modify: `agent-sandbox.sh:324-336` (the `docker run` invocation in `cmd_start`)

**Interfaces:**
- Produces: every container created by `agent-sandbox start` carries the label `agentic-sandbox-project=<absolute project dir>`. Task 2/3's `sbx` reads this label via `docker inspect` and `docker ps --format '{{.Label "agentic-sandbox-project"}}'`.

- [ ] **Step 1: Add the label to `docker run`**

In `agent-sandbox.sh`, `cmd_start`, the `docker run` command currently reads:

```bash
    docker run -dit \
        --name "$container_name" \
        --label "agentic-sandbox=true" \
        --label "agentic-sandbox-agent=$agent_choice" \
```

Add one line so it reads:

```bash
    docker run -dit \
        --name "$container_name" \
        --label "agentic-sandbox=true" \
        --label "agentic-sandbox-agent=$agent_choice" \
        --label "agentic-sandbox-project=$project_dir" \
```

(`$project_dir` is already absolute at this point — it is normalized with `cd`/`pwd` near the top of `cmd_start`.)

- [ ] **Step 2: Verify syntax**

Run: `bash -n agent-sandbox.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add agent-sandbox.sh
git commit -m "sandbox: label containers with their project path"
```

---

### Task 2: `sbx` script skeleton with naming helpers (TDD)

**Files:**
- Create: `sbx` (repo root, executable)
- Test: `tests/test-sbx-naming.sh` (executable)

**Interfaces:**
- Produces: `sanitize_name <string>` → sanitized lowercase name on stdout (may be empty). `path_hash <string>` → 4 lowercase hex chars on stdout. Sourcing `sbx` with `SBX_TEST=1` set loads functions without executing anything. Task 3 fills in `main` and the launch logic in this same file.

- [ ] **Step 1: Write the failing test**

Create `tests/test-sbx-naming.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for sbx's pure naming helpers. No docker required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_TEST=1 source "$SCRIPT_DIR/../sbx"
set +e  # sbx enables -e when sourced; tests manage their own failures

fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc — expected '$expected', got '$actual'"
        fail=1
    fi
}

assert_eq "simple name unchanged"    "my-app"  "$(sanitize_name 'my-app')"
assert_eq "uppercase lowered"        "myapp"   "$(sanitize_name 'MyApp')"
assert_eq "space becomes dash"       "my-app"  "$(sanitize_name 'My App')"
assert_eq "unicode becomes dash"     "my-app"  "$(sanitize_name 'My✨App')"
assert_eq "inner dot kept"           "my.app"  "$(sanitize_name 'my.app')"
assert_eq "underscore kept"          "my_app"  "$(sanitize_name 'my_app')"
assert_eq "leading dot trimmed"      "hidden"  "$(sanitize_name '.hidden')"
assert_eq "junk runs squeezed"       "a-b"     "$(sanitize_name 'a--&&b')"
assert_eq "all-junk becomes empty"   ""        "$(sanitize_name '✨✨')"

h1=$(path_hash '/some/path')
h2=$(path_hash '/some/path')
h3=$(path_hash '/other/path')
assert_eq "hash deterministic" "$h1" "$h2"
if [[ "$h1" != "$h3" ]]; then echo "ok: different paths hash differently"
else echo "FAIL: same hash for different paths"; fail=1; fi
if [[ "$h1" =~ ^[0-9a-f]{4}$ ]]; then echo "ok: hash is 4 hex chars"
else echo "FAIL: hash format: '$h1'"; fail=1; fi

exit $fail
```

Then: `chmod +x tests/test-sbx-naming.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test-sbx-naming.sh`
Expected: FAIL — `../sbx: No such file or directory` (non-zero exit)

- [ ] **Step 3: Write the skeleton with the naming helpers**

Create `sbx`:

```bash
#!/usr/bin/env bash
# sbx — one-command project sandbox launcher.
#
# cd to a project and run `sbx`: the project's sandbox is created or resumed
# automatically (named after the directory) and you land in Claude Code,
# continuing the previous session when one exists. When the last interactive
# session exits, the sandbox is stopped (not removed).
#
# Management (build, stop, remove, sync-skills, reset-config) stays in
# agent-sandbox.
set -euo pipefail

PROJECT_LABEL="agentic-sandbox-project"

usage() {
    cat <<'USAGE'
Usage: sbx [new|shell|list] [--agent NAME]

  sbx                Create-or-resume the sandbox for the current directory
                     and launch claude (continues the previous session when
                     one exists).
  sbx new            Same, but start a fresh claude session (no --continue).
  sbx shell          Same, but open a bash shell instead of claude.
  sbx list           List all sandboxes with their project paths.

Options:
  --agent NAME       claude (default), copilot, or vibe.

Sandboxes are named after the project directory (~/Repos/my-app →
sbx-my-app). When the last interactive session exits, the sandbox is
stopped, not removed. Management commands (build, stop, remove,
sync-skills, reset-config) live in agent-sandbox.
USAGE
}

# --- naming ----------------------------------------------------------------

# Lowercase; anything outside [a-z0-9_.-] becomes '-'; squeeze repeated '-';
# trim leading/trailing '-' and '.' (Docker names must start alphanumeric).
# LC_ALL=C so multibyte input is treated as plain junk bytes.
sanitize_name() {
    printf '%s' "$1" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9_.-]+/-/g; s/-+/-/g; s/^[-.]+//; s/[-.]+$//'
}

# First 4 hex chars of the sha256 of the given string.
path_hash() {
    printf '%s' "$1" | shasum -a 256 | cut -c1-4
}

main() {
    echo "sbx: not implemented yet" >&2
    exit 1
}

# When sourced with SBX_TEST=1, expose functions without running main
# (used by tests/test-sbx-naming.sh).
if [[ "${SBX_TEST:-}" != "1" ]]; then
    main "$@"
fi
```

Then: `chmod +x sbx`

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test-sbx-naming.sh && echo ALL-PASS`
Expected: 12 `ok:` lines, then `ALL-PASS`

- [ ] **Step 5: Commit**

```bash
git add sbx tests/test-sbx-naming.sh
git commit -m "sbx: launcher skeleton with naming helpers and tests"
```

---

### Task 3: `sbx` launch flow, auto-stop, and list

**Files:**
- Modify: `sbx` (replace the placeholder `main` with the full implementation)

**Interfaces:**
- Consumes: `sanitize_name`, `path_hash` from Task 2; the `agentic-sandbox-project` label from Task 1; `agent-sandbox start <dir> -n <name> --agent <agent>` (existing CLI, resolves via `/usr/local/bin/agent-sandbox`).
- Produces: the complete user-facing `sbx` command (`sbx`, `sbx new`, `sbx shell`, `sbx list`, `--agent`).

- [ ] **Step 1: Replace the placeholder `main` with the full implementation**

In `sbx`, replace everything from `main() {` through the final `fi` with:

```bash
container_exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }
container_running() { docker ps    --format '{{.Names}}' | grep -qx "$1"; }

container_project_label() {
    docker inspect -f "{{index .Config.Labels \"$PROJECT_LABEL\"}}" "$1" 2>/dev/null || true
}

# Container name for a project path: sbx-<sanitized basename>, with a short
# path hash appended when that name is taken by a different project (or by a
# pre-label container whose project path is unknown).
derive_container_name() {
    local project_dir="$1"
    local base
    base=$(sanitize_name "$(basename "$project_dir")")
    [[ -z "$base" ]] && base="project"
    local name="sbx-${base}"
    if container_exists "$name" \
            && [[ "$(container_project_label "$name")" != "$project_dir" ]]; then
        name="${name}-$(path_hash "$project_dir")"
    fi
    echo "$name"
}

# --- launch ------------------------------------------------------------------

# Claude Code stores per-project session history under
# ~/.claude/projects/<project path with non-alphanumerics replaced by '-'>.
# The project is mounted at /$PROJECT_NAME inside the container.
has_claude_history() {
    local container="$1"
    docker exec "$container" sh -c '
        d="$HOME/.claude/projects/$(printf %s "/$PROJECT_NAME" | sed "s/[^A-Za-z0-9]/-/g")"
        [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]
    ' 2>/dev/null
}

# The command line to exec inside the container for the chosen agent/mode.
agent_command() {
    local agent="$1" mode="$2" container="$3"
    case "$agent" in
        claude)
            local cmd="/home/agent/.local/bin/claude --dangerously-skip-permissions"
            if [[ "$mode" == "default" ]] && has_claude_history "$container"; then
                cmd="$cmd --continue"
            fi
            echo "$cmd"
            ;;
        vibe)    echo "/home/agent/.local/bin/vibe" ;;
        copilot) echo "copilot" ;;
    esac
}

# Stop the sandbox when ours was the last interactive session. Each
# `docker exec -it` holds one PTY in the container's /dev/pts; ours is gone
# by the time this runs. The container is created with `docker run -dit`, so
# the entrypoint permanently holds one PTY — the idle baseline is 1, not 0.
maybe_stop() {
    local container="$1" open_ptys
    open_ptys=$(docker exec "$container" sh -c \
        'ls /dev/pts 2>/dev/null | grep -v "^ptmx$" | wc -l' 2>/dev/null \
        | tr -d '[:space:]') || true
    if [[ -z "$open_ptys" ]]; then
        return 0   # container gone or docker error — never block exit on cleanup
    fi
    if [[ "$open_ptys" -le 1 ]]; then
        docker stop "$container" >/dev/null 2>&1 || true
        echo "Sandbox '$container' stopped."
    else
        echo "Sandbox '$container' left running ($((open_ptys - 1)) other session(s) attached)."
    fi
}

cmd_launch() {
    local mode="$1" agent="$2"
    local project_dir
    project_dir=$(pwd -P) || { echo "Error: cannot resolve current directory" >&2; exit 1; }

    local container
    container=$(derive_container_name "$project_dir")

    if container_running "$container"; then
        echo "Attaching to running sandbox '$container'..."
    elif container_exists "$container"; then
        echo "Starting stopped sandbox '$container'..."
        docker start "$container" >/dev/null
    else
        echo "Creating sandbox '$container' for $project_dir..."
        agent-sandbox start "$project_dir" -n "$container" --agent "$agent"
    fi

    local proj
    proj=$(docker exec "$container" printenv PROJECT_NAME 2>/dev/null || true)
    local -a workdir=()
    [[ -n "$proj" ]] && workdir=(-w "/$proj")

    if [[ "$mode" == "shell" ]]; then
        docker exec -it ${workdir[@]+"${workdir[@]}"} "$container" /bin/bash -l || true
    else
        local run_cmd
        run_cmd=$(agent_command "$agent" "$mode" "$container")
        docker exec -it ${workdir[@]+"${workdir[@]}"} "$container" /bin/bash -lc "exec $run_cmd" || true
    fi

    maybe_stop "$container"
}

cmd_list() {
    docker ps -a --filter "label=agentic-sandbox=true" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Label \"$PROJECT_LABEL\"}}"
}

main() {
    local mode="default" agent="claude"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            new)   mode="new"; shift ;;
            shell) mode="shell"; shift ;;
            list)  cmd_list; exit 0 ;;
            --agent) agent="${2:?--agent requires a value}"; shift 2 ;;
            -h|--help|help) usage; exit 0 ;;
            *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
    case "$agent" in
        claude|copilot|vibe) ;;
        *) echo "Error: --agent must be one of: claude, copilot, vibe" >&2; exit 1 ;;
    esac
    cmd_launch "$mode" "$agent"
}

# When sourced with SBX_TEST=1, expose functions without running main
# (used by tests/test-sbx-naming.sh).
if [[ "${SBX_TEST:-}" != "1" ]]; then
    main "$@"
fi
```

- [ ] **Step 2: Syntax, unit tests, lint**

Run: `bash -n sbx && ./tests/test-sbx-naming.sh && echo ALL-PASS`
Expected: 12 `ok:` lines, `ALL-PASS`

Run: `command -v shellcheck >/dev/null && shellcheck sbx || echo "shellcheck not installed — skipped"`
Expected: no errors (info/style notes acceptable), or the skip message.

- [ ] **Step 3: Verify the PTY baseline assumption (needs the built image)**

The auto-stop threshold assumes an idle container holds exactly one PTY
(from `docker run -dit`). Verify empirically:

```bash
docker run -dit --name sbx-pts-probe --label agentic-sandbox=true agentic-sandbox:latest
sleep 2
docker exec sbx-pts-probe sh -c 'ls /dev/pts | grep -v "^ptmx$" | wc -l'
docker rm -f sbx-pts-probe
```

Expected: `1`. If it prints `0`, change `maybe_stop`'s comparison from
`-le 1` to `-le 0` and update its comment; if it prints `2`, investigate
before proceeding (do not just bump the threshold).

- [ ] **Step 4: End-to-end smoke test of the non-interactive paths**

```bash
./sbx list
```
Expected: a table with `NAMES  STATUS  AGENTIC-SANDBOX-PROJECT` columns (existing sandboxes, if any, listed; old ones show an empty project column).

```bash
./sbx --agent bogus
```
Expected: `Error: --agent must be one of: claude, copilot, vibe`, exit 1.

```bash
./sbx frobnicate
```
Expected: `Unknown argument: frobnicate` plus usage, exit 1.

- [ ] **Step 5: Commit**

```bash
git add sbx
git commit -m "sbx: launch flow, auto-stop on last exit, list"
```

---

### Task 4: Retire `sandboxed.sh`, rewrite README, install symlinks

**Files:**
- Delete: `sandboxed.sh`
- Modify: `README.md` (Quick Start, Usage, "Convenience wrappers" section)
- Symlinks: `/usr/local/bin/sbx` created; `claude-sandboxed`/`vibe-sandboxed` removed (may need sudo)

**Interfaces:**
- Consumes: the finished `sbx` from Task 3.
- Produces: documentation and PATH entry; no code interfaces.

- [ ] **Step 1: Delete the old wrapper**

```bash
git rm sandboxed.sh
```

- [ ] **Step 2: Update the README Quick Start**

Replace steps 3–5 of the Quick Start code block (currently `agent-sandbox start /path/to/your/project`, `agent-sandbox shell`, and the login step) with:

```bash
# 3. cd to your project and launch — sandbox is created/resumed automatically
cd ~/projects/my-app
sbx

# 4. Log in to your agents (first time only)
claude login
gh auth login
```

Directly after the Quick Start block, replace the line
`The /usr/local/bin/agent-sandbox symlink points to agent-sandbox.sh in this directory.` with:

```markdown
Symlinks in `/usr/local/bin` point into this directory:

​```bash
ln -s ~/Repos/ai-sandbox/agent-sandbox.sh /usr/local/bin/agent-sandbox
ln -s ~/Repos/ai-sandbox/sbx /usr/local/bin/sbx
​```
```

(Remove the zero-width characters around the inner code fence — they are only there to nest it in this plan.)

- [ ] **Step 3: Replace the "Convenience wrappers" section**

Replace the entire `## Convenience wrappers: claude-sandboxed / vibe-sandboxed` section (heading through the paragraph ending "use `agent-sandbox start` directly.") with:

```markdown
## Everyday use: `sbx`

`sbx` is the daily driver: cd to a project, run `sbx`, land in Claude Code.

​```bash
cd ~/projects/my-app
sbx                # create-or-resume "sbx-my-app", launch claude
                   #   (--continue when the project has session history)
sbx new            # fresh claude session (no --continue)
sbx shell          # bash shell instead of claude
sbx list           # all sandboxes: name, status, project path
sbx --agent vibe   # another agent (claude is the default)
​```

Sandboxes are named after the project directory (`~/projects/my-app` →
`sbx-my-app`); the absolute project path is stored as a Docker label, and a
short path hash is appended if two projects share a basename. When the last
interactive session exits, the sandbox is **stopped automatically** — not
removed, so container state and volumes persist and the next `sbx` resumes
where you left off.

Management stays in `agent-sandbox` (`build`, `stop`, `remove`,
`sync-skills`, `reset-config`). To create a sandbox with non-default options
(extra networks, ports), use `agent-sandbox start -n <name>` with the name
`sbx` would derive — `sbx` will then find and reuse it.
```

(Again remove the zero-width characters around the inner fence.)

Also update the README `## Usage` block for `agent-sandbox` only if it still mentions the wrappers; the command list itself is unchanged.

- [ ] **Step 4: Update the sbx-list note in the Usage section**

In the `## Usage` block, after the `Commands:` list, no changes are required — but scan the rest of the README for `claude-sandboxed`, `vibe-sandboxed`, or `sandboxed.sh` references and remove/replace each with `sbx` equivalents:

Run: `grep -n "sandboxed" README.md`
Expected after edits: no matches (the word `sandboxed` no longer appears).

- [ ] **Step 5: Install/remove host symlinks**

```bash
ln -sf ~/Repos/ai-sandbox/sbx /usr/local/bin/sbx
rm -f /usr/local/bin/claude-sandboxed /usr/local/bin/vibe-sandboxed
```

(Prefix with `sudo` if `/usr/local/bin` is not writable. If running as a
sandboxed/CI worker without permission, skip and note it in the report —
the user runs these two lines once.)

Run: `sbx --help | head -2`
Expected: the usage text, proving the symlink resolves.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "sbx: retire sandboxed.sh wrappers, document the sbx workflow"
```

---

## Manual acceptance matrix (after all tasks; interactive, run by the user)

Requires the built image and a terminal. Each row from a test project dir, e.g. `cd ~/Repos/some-project`:

1. **Fresh create:** `sbx` in a project with no sandbox → creates `sbx-<name>`, installs agent, lands in claude (no `--continue` first time). Exit claude → "Sandbox 'sbx-<name>' stopped."
2. **Resume stopped:** `sbx` again → "Starting stopped sandbox...", lands in `claude --continue`.
3. **Attach running + last-one-out:** terminal A: `sbx`; terminal B: `sbx shell`. Exit A → "left running (1 other session(s) attached)". Exit B → "stopped."
4. **Fresh session:** `sbx new` → claude without `--continue`.
5. **Shell mode:** `sbx shell` → bash prompt in `/<project>`, no claude.
6. **Collision:** create sandboxes from two directories both named e.g. `app` → second gets `sbx-app-<hash>`; `sbx list` shows both with distinct project paths; `sbx` in each dir attaches to the right one.
