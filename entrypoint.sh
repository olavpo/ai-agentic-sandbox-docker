#!/bin/bash
# Entrypoint: applies egress firewall, installs agents, sets up git auth,
# surfaces SANDBOX_HOST_PORT to the agent.

AGENT_HOME="/home/agent"

# Disable SSH agent forwarding (HTTPS-only git access)
unset SSH_AUTH_SOCK
export SSH_AUTH_SOCK=""

# --- Privileged boot: sudo policy, host-visible ports, egress firewall ---
# All of it happens in sandbox-privileged-boot.sh, the one thing the agent may
# run as root. It reads its config (SANDBOX_ALLOW_SUDO, SANDBOX_SKIP_FIREWALL,
# DHIS2_BROKER_URL, ADB_SERVER_SOCKET, SANDBOX_HOST_PORT*) from /proc/1/environ
# rather than from this shell, so those values cannot be forged from inside the
# container — see the comment block in that script for why that matters.
#
# The firewall needs NET_ADMIN + NET_RAW; without them init fails and the
# container refuses to boot rather than coming up unprotected.
#
# FIREWALL_READY is the launcher's attach handshake. `docker exec` bypasses this
# entrypoint's ordering entirely, so without it a session can attach while
# egress is still unrestricted — a window that recurs on every `docker start`,
# not just on first creation. It is written only after privileged boot has
# finished, which in a strict sandbox (the default) is also the point where any
# general root the agent had has been taken away. Clearing it here matters: a
# restarted container would otherwise reuse a stale marker and the wait would be
# a no-op.
FIREWALL_READY=/tmp/sandbox-firewall-ready
rm -f "$FIREWALL_READY"

if sudo -n /usr/local/bin/sandbox-privileged-boot.sh; then
    if [[ "${SANDBOX_SKIP_FIREWALL:-}" != "1" ]]; then
        # Keep up with CDN edge IP rotation. Hosts behind CloudFront (e.g.
        # docs.dhis2.org) return different edge IPs over time; the IPs we
        # resolved at boot age out of the allowed-domains ipset, and after
        # a while connections to those hosts start failing with "No route
        # to host". The background loop re-resolves DOMAINS into the
        # existing ipset (no rule flush, no in-flight disruption).
        #
        # It also re-checks the rules themselves and re-applies the full policy
        # if they have been flushed or weakened, so a sandbox that lost its
        # firewall is re-fenced within one interval instead of staying open
        # until it is next recreated. That is a backstop, not a boundary: in an
        # --allow-sudo sandbox an agent can flush it again straight away. The
        # default strict mode is what makes it a boundary.
        REFRESH_INTERVAL="${SANDBOX_FIREWALL_REFRESH_INTERVAL:-300}"
        (
            while true; do
                sleep "$REFRESH_INTERVAL"
                sudo -n /usr/local/bin/sandbox-privileged-boot.sh refresh \
                    >/tmp/firewall-refresh.log 2>&1 || true
            done
        ) &
        disown
    else
        echo "[entrypoint] SANDBOX_SKIP_FIREWALL=1 — running with unrestricted network."
    fi
    : > "$FIREWALL_READY"
    chmod 0644 "$FIREWALL_READY"
else
    # Fail closed. A transient DNS failure or GitHub API hiccup used to produce
    # a silently unprotected sandbox behind one warning line. An explicit
    # opt-out exists, which is what makes refusing to boot affordable: whoever
    # wants no firewall has a supported way to say so.
    echo "[entrypoint] FATAL: privileged boot failed; refusing to start unprotected." >&2
    echo "[entrypoint]   To run without a firewall on purpose:" >&2
    echo "[entrypoint]     agent-sandbox start <dir> --host-network" >&2
    echo "[entrypoint]   (or set SANDBOX_SKIP_FIREWALL=1 for a hand-rolled docker run)" >&2
    exit 1
fi

# --- Sandbox brief in ~/.claude/CLAUDE.md ---
# ~/.claude is the `agentic-sandbox-claude` volume, shared by every claude
# sandbox on the machine, so there is exactly ONE of these files and every
# sandbox reads it. The block is rewritten on each boot, which means anything
# per-sandbox written here is decided by whichever sandbox booted last.
#
# Everything in the block below is therefore written to be true in any sandbox:
# the broker and adb sections are phrased conditionally ("if X is set"), and the
# Permissions section describes both sudo modes with the command to tell them
# apart rather than asserting one. Per-sandbox values live in /etc/sandbox-info,
# which is container-local. Keep it that way when editing — a statement here that
# only holds for some sandboxes will be read by all of them.
#
# Changes to this entrypoint propagate on next boot; content outside the markers
# survives.
mkdir -p "$AGENT_HOME/.claude"
claude_md="$AGENT_HOME/.claude/CLAUDE.md"
start_marker="<!-- BEGIN agent-sandbox -->"
end_marker="<!-- END agent-sandbox -->"
# The host addendum gets its OWN marker pair, deliberately outside the block
# above. Sandboxes created before the addendum existed run an entrypoint baked
# into their image that strips everything between the agent-sandbox markers and
# rewrites it — and since CLAUDE.md lives in the shared config volume, such a
# sandbox booting would otherwise delete the addendum for every sandbox. Content
# outside its markers is the one thing an old entrypoint leaves alone.
addendum_start="<!-- BEGIN host-addendum -->"
addendum_end="<!-- END host-addendum -->"

# Rewrites in place rather than `mv`-ing a temp file over the target: CLAUDE.md
# is a bind-mounted file (see below), and replacing a mount point fails with
# "Resource busy". Truncating and rewriting keeps the same inode.
strip_block() {
    local file="$1" start="$2" end="$3"
    [[ -f "$file" ]] || return 0
    local tmp="/tmp/claude-md-strip.$$"
    awk -v start="$start" -v end="$end" '
        $0 == start { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip       { print }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

strip_block "$claude_md" "$start_marker" "$end_marker"
strip_block "$claude_md" "$addendum_start" "$addendum_end"

cat >> "$claude_md" <<'EOF'
<!-- BEGIN agent-sandbox -->
## Sandbox environment

You're running inside the **agentic-sandbox** Docker container, not directly on the user's machine. A few things to know:

### Network is restricted

Outbound traffic is filtered by an iptables egress firewall. Allowed by default: Anthropic, GitHub, npm/yarn registry, pypi, Maven Central, Google Maven and the Gradle distribution and plugin hosts (Android/Gradle builds), dhis2.org, plus a small set of dev CDNs (Playwright, VS Code marketplace, NodeSource, Debian/Ubuntu mirrors). Anything else is dropped — `curl https://example.com` will fail. If you need a new host, ask the user to add it to `init-firewall.sh`. The script is baked into the image, so a rebuild alone does not reach a running sandbox: the user has to recreate it, or copy the new script into it with `docker cp`.

You're on the **`dev-net`** Docker network by default. Sibling dev containers (e.g. a DHIS2 instance named `dhis2`, a database named `dhis2-db`, an MCP server wrapped as a container) are reachable by container name: `curl http://dhis2:8080/api/me`. Use `ip route` to see what subnets are attached.

`localhost:<port>` inside the sandbox is the sandbox itself — ports that other containers publish "to localhost" are published to the **host**, not to you. Prefer container names on `dev-net`. If a container isn't on dev-net but does publish a host port, that port is usually reachable on the bridge gateway IP (`ip route | awk '/default/ {print $3}'`).

Services running on the user's host machine are **not** reachable from inside the sandbox, with two exceptions when configured: the DHIS2 instance broker and the host's adb server (Android emulator), both below. For anything else on the host, ask the user to either run it as a sibling container on `dev-net` or to install/run the equivalent inside the sandbox.

### DHIS2 test instances (d2-broker)

If the `DHIS2_BROKER_URL` and `DHIS2_BROKER_TOKEN` environment variables are set, the host runs **d2-broker** — an HTTP API through which you can create, reset, start/stop and delete disposable DHIS2 instances for testing. You may only manage instances named `agent-*`, and only seed them from the curated list at `GET /seeds` (or create them empty). All mutating calls return a job to poll. Quick check:

```bash
curl -s -H "Authorization: Bearer $DHIS2_BROKER_TOKEN" "$DHIS2_BROKER_URL/instances"
```

Created instances are reachable on dev-net at `http://dhis2-<name>:8080` (credentials usually `admin`/`district`). See the `dhis2-instances` skill for the full API. If the env vars are unset, this capability is unavailable — don't probe for it.

### Android emulator (adb)

If the `ADB_SERVER_SOCKET` environment variable is set, the host runs an adb server (usually with an Android emulator attached) and the `adb` client in this sandbox already points at it — `adb devices` just works. You can:

- install APKs: `adb install /path/to/app.apk`
- see the screen: `adb exec-out screencap -p > /tmp/screen.png` (then read the PNG)
- inspect the UI: `adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml`
- interact: `adb shell input tap X Y`, `input swipe ...`, `input text '...'`, `input keyevent ...`
- read logs: `adb logcat -d`

**Never run `adb kill-server`** — the server belongs to the host; killing it breaks the connection for everyone and you cannot restart it from in here.

The emulator runs on the **host**, not on dev-net. Inside an app on the emulator, the host's loopback is `10.0.2.2` — so to point an Android app (e.g. the DHIS2 Capture app) at a broker-created DHIS2 instance, use `http://10.0.2.2:<http_port>`, where `http_port` comes from `GET $DHIS2_BROKER_URL/instances`. The dev-net URL (`http://dhis2-<name>:8080`) does NOT resolve on the emulator.

See the `dhis2-android-testing` skill for the full workflow. If `ADB_SERVER_SOCKET` is unset, there is no emulator wiring — don't probe for it.

### Host-visible ports: `$SANDBOX_HOST_PORT` (+ `$SANDBOX_HOST_PORT_2`)

The sandbox pre-publishes two ports to the user's host. Their values are in the `$SANDBOX_HOST_PORT` and `$SANDBOX_HOST_PORT_2` environment variables and in `/etc/sandbox-info`.

**When you start a server the user should view in their browser** (visual companion, dev preview, Playwright report, etc.), bind it to `$SANDBOX_HOST_PORT`. The user opens `http://localhost:$SANDBOX_HOST_PORT` on their host. Use `$SANDBOX_HOST_PORT_2` for a second host-visible service — e.g. an App Platform dev server on one and its proxy on the other.

Examples:
- `python -m http.server "$SANDBOX_HOST_PORT"`
- For skills/tools with a `--port` flag: pass `"$SANDBOX_HOST_PORT"`.
- For `vite` / `webpack-dev-server`: configure via `--port "$SANDBOX_HOST_PORT"` or the relevant config field.

Two host-visible ports are auto-published per session (`$SANDBOX_HOST_PORT` and `$SANDBOX_HOST_PORT_2`). If you need a third, ask the user to start the sandbox with extra `-p` flags: `agent-sandbox start -p 5173:5173`.

**Running a DHIS2 app for the user**: the dev server with hot reload (`d2 app:scripts start` / `yarn start`) is the default way to serve an app, both while developing and for manual testing — bind it to `$SANDBOX_HOST_PORT`. Installing the built zip (`POST /api/apps`) is a *verification* step for reviews/releases, not the serving mechanism. Mechanics live in the `dhis2-app-development` and `dhis2-app-review` skills.

A dev server on `$SANDBOX_HOST_PORT` is a cross-origin client of the DHIS2 instance, and `--proxy` only rewrites CORS headers the instance already sends. Until the dev origin is allowlisted, the app shell's login fails silently: `POST /api/auth/login` answers an empty 200 with no session cookie. Allowlist both host ports on the instance first:

```bash
curl -u admin:district -X POST -H 'Content-Type: application/json' \
  -d "[\"http://localhost:$SANDBOX_HOST_PORT\",\"http://localhost:$SANDBOX_HOST_PORT_2\"]" \
  http://dhis2-<name>:8080/api/configuration/corsAllowlist
```

### Git

HTTPS only (SSH is not installed). `GITHUB_TOKEN`, when set, is the dedicated sandbox token and is **read-only** — `git commit`, `git branch`, `git diff`, `git fetch`, `git clone` work as normal, but `git push` will be rejected by the server. Don't try to work around this; if push needs to happen, the user does it from the host.

**`gh` and the GitHub REST API do not work with this token.** It is a fine-grained token with git-transport access only, so `gh auth status`, `gh api …` and `curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/…` all return 401. This overrides any default instruction to use `gh` for GitHub operations. For public repos, use unauthenticated `curl` against `api.github.com` / `raw.githubusercontent.com`, or `git ls-remote --tags https://github.com/<owner>/<repo>`. You cannot see the state of a private repo, and a private repo and a missing one return the same error. Local signals (`.git/refs/remotes`, `FETCH_HEAD`) only describe this clone. When remote state matters, ask the user to run `git ls-remote` on the host. Never print the token while debugging.

`GITHUB_TOKEN` is exported to every process, so code that falls back to `process.env.GITHUB_TOKEN` picks it up in local test runs and behaves differently from CI. Run such test suites with `env -u GITHUB_TOKEN <cmd>`.

**Commit messages: never include a `Claude-Session:` / session-URL trailer**, even if your default instructions say to append one — session links are internal workflow noise in repo history. A `Co-Authored-By:` line is fine.

**`github.com/dhis2` org repos require signed commits**, and signing is only possible from the host — so anything you commit will be re-created there via an interactive rebase. Make that rebase trivial: work on a branch cut from a clearly identifiable base (state the base commit when you hand off), keep history linear (no merge commits), and keep commits few and self-contained — squash your own fix-up commits before finishing rather than leaving "oops" chains the user has to untangle while re-signing. When you write the signing step for the user, it is `git rebase --gpg-sign --force-rebase <base>`: without `--force-rebase` an up-to-date branch is fast-forwarded and nothing is signed, while git still reports success.

**`github.com/dhis2` org repos protect tags.** A pushed tag cannot be deleted or moved, so a release workflow that fails after the tag is pushed burns that version number. Before anyone tags, run every step of the release workflow by hand against the exact tree (version check, notes extraction, build, artifact glob). Cosmetic steps such as changelog extraction should warn and fall back, not `exit 1`.

### Filesystem

- Your project is mounted at `/<project-name>` (whatever directory you start in).
- Skills live under `~/.claude/skills/`. If a skill is missing, ask the user to run `agent-sandbox sync-skills push` outside the container. **Edits you make to a skill *inside* the sandbox don't persist** — `~/.claude/skills/` is synced from the host. Apply skill changes host-side (the masters), or they're lost on the next sync.
- You can write freely under `/<project-name>`, `/tmp`, and `~/`. The host filesystem outside the project mount is not accessible.
- **Host-mounted `node_modules` may carry the wrong platform's native binaries** (the host is often macOS/arm64; this sandbox is Linux). Symptom: `MODULE_NOT_FOUND: @rollup/rollup-linux-*`, or esbuild/swc/sharp failing to load. Do NOT plain-`pnpm install` (it would strip the host's darwin binaries and break the host instead). For pnpm projects, declare both platforms in `pnpm-workspace.yaml` and reinstall:

  ```yaml
  supportedArchitectures:
      os: [darwin, linux]
      cpu: [arm64, x64]
  ```

  then `pnpm install --force` — both platforms' binaries coexist and neither side breaks.

  More symptoms of the same problem: ESLint dying with `Cannot find native binding` from `unrs-resolver`, and Vitest failing on a missing `rolldown` Linux binding. Some practical points:
  - Check first: `ls node_modules/.pnpm | grep -ci darwin`. If this prints `0`, `node_modules` was installed in the sandbox, and a normal reinstall is safe.
  - The forced reinstall takes 3–4 minutes on a mid-size App Platform project. Don't try it speculatively.
  - The `supportedArchitectures` block is a sandbox-only workaround. Revert it before committing.
  - Add `--config.confirm-modules-purge=false` to any `pnpm install` after a layout change (for example `publicHoistPattern`). Otherwise pnpm waits on a `Proceed? (Y/n)` prompt that nobody can answer, until the command times out.
  - For npm projects, `supportedArchitectures` does not exist. `npm pack` the missing `*-linux-*` optional dependency in a scratch directory and copy it into `node_modules`, next to the darwin one. Don't run `npm install`.
  - pnpm may create a `.pnpm-store/` (several hundred MB) at the repo root, because it cannot hardlink across the mount. Delete it after the install, and never stage it.

### Stopping processes

**Never `pkill -f` or `pgrep -f … | xargs kill` with a pattern that appears in your own command.** The pattern matches the invoking shell, which then dies with exit 144 and usually leaves the target running. This applies to everything (dev servers, recording loops, poll loops, browsers), not only servers. Record the PID at launch and kill that number. Otherwise, find the PID in one call and kill it in a separate call, or use a bracket pattern such as `pgrep -f 'serve[.]mjs'`.

### Long-running dev servers

- Start dev servers with the shell tool's background mode (`run_in_background`), not `nohup …&`/`setsid`/`disown` (these exit 144 here). Record the PID at launch if you'll need to stop it.
- Before you start a server, check that nothing from an earlier session still holds the port (`lsof -i :"$SANDBOX_HOST_PORT"`). Old servers outlive their sessions and keep serving stale builds.
- The project tree and its `.git` are shared with the host. A running `d2-app-scripts start` rewrites generated files such as `i18n/en.pot`, and those changes block host-side git (`cannot rebase: You have unstaged changes`). Stop the server before the user does any host-side git work, and revert `en.pot` churn from `start` rather than committing it. A `git checkout` in the sandbox also changes what the user sees on the host.
- The DHIS2 dev servers' file watcher races editors' atomic writes: editing source while `d2-app-scripts start`/`webpack-dev-server` runs can crash it with `ENOENT … <file>.tmp.<pid>…`. Harmless — batch your edits, then (re)start the server, rather than restarting after every edit.

### Browsers (Playwright)

- The Python `playwright` package uses the image's Chromium with no setup. A project's npm `@playwright/test` or `@playwright/cli` may want a different Chromium revision ("Executable doesn't exist at /opt/playwright-browsers/…"). Run `npx playwright install chromium` from the project to add it; `/opt/playwright-browsers` is writable.
- Close every browser you start before you finish, including in subagents. A leftover Chromium holds around 800 MB, and under memory pressure the harness kills unrelated background tasks instead.

EOF

# The sudo mode is per-sandbox, but this file is not: ~/.claude is a volume
# shared by every claude sandbox, so whatever is written here is what ALL of them
# read. Asserting a mode would therefore be a coin flip decided by whichever
# sandbox booted last — and telling an agent it has root when it does not is
# exactly the failure this section exists to prevent. So describe both modes and
# give the one-command test instead. Correct in every sandbox, no per-container
# state, nothing to keep in sync.
cat >> "$claude_md" <<'EOF'
### Permissions

You run as the `agent` user. By default you have **no general sudo**. The user can opt a sandbox in when creating it (`--allow-sudo`), or grant sudo to a running sandbox until its next restart — so **check rather than assume**:

```bash
sudo -n true && echo "passwordless sudo" || echo "strict sudo"
```

`/etc/sandbox-info` records the same thing as `SANDBOX_ALLOW_SUDO=0|1`, along with this sandbox's host-visible ports.

- **Strict sudo** (the default): `sudo apt-get install …`, `sudo iptables …` and similar fail, and there is no way around it from inside. That is deliberate: it is what stops the egress firewall from being removable. Whatever you need should already be in the image. If something is genuinely missing, say so and ask the user — from the host they can grant sudo until the next restart (`agent-sandbox sudo <container> on`), install it themselves (`docker exec -u root <container> …`), or add it to the image. Don't spend turns hunting for a privilege-escalation route.
- **Passwordless sudo** (`--allow-sudo`, or granted temporarily): system changes inside the container work. Sudo doesn't reach the user's host. Note it also reaches the egress firewall — don't reconfigure or flush it to work around a blocked host; ask the user to allowlist what you need. A temporary grant ends when the sandbox restarts.

Resource limits: 8 GB RAM, 4 CPUs, 1 GB `/dev/shm`. Older sandboxes have Docker's 64 MB `/dev/shm` (check with `df -h /dev/shm`); there, launch Chromium with `--disable-dev-shm-usage` or it crashes with "Page crashed". The Docker VM's memory is shared with the broker's DHIS2 instances, so free memory can run out even when this container uses little.
EOF

cat >> "$claude_md" <<'EOF'
<!-- END agent-sandbox -->
EOF

# --- Host-managed addendum ---
# agent-sandbox.sh bind-mounts a host file (default ~/.claude/sandbox-CLAUDE.md)
# read-only at /mnt/host-claude-md. It is appended AFTER the block above, in its
# own markers, so an older sandbox booting cannot strip it out of the shared
# CLAUDE.md (see the note by the marker definitions). Re-read on every boot: edit
# the host file, restart the sandbox, and the context follows. Absent mount is
# the normal case for a fresh checkout, so stay quiet then — the strip above has
# already removed any stale copy.
if [[ -r /mnt/host-claude-md ]]; then
    {
        printf '\n%s\n' "$addendum_start"
        cat /mnt/host-claude-md
        printf '%s\n' "$addendum_end"
    } >> "$claude_md"
    echo "[entrypoint] Appended host CLAUDE.md addendum to $claude_md"
fi

# --- Install the chosen agent(s) on first run ---
# agent-sandbox.sh sets AGENT_CHOICE to one of: claude (default), copilot,
# vibe, all. The matching named volume is also mounted at /home/agent/.<agent>
# so installs persist across container recreations.
AGENT_CHOICE="${AGENT_CHOICE:-claude}"

case "$AGENT_CHOICE" in
    claude|all)
        if ! command -v claude &>/dev/null; then
            echo "[entrypoint] Installing Claude Code..."
            if ! curl -fsSL https://claude.ai/install.sh | bash; then
                # No sudo: NPM_CONFIG_PREFIX points at an agent-writable dir,
                # so this works in strict-sudo sandboxes too.
                echo "[entrypoint] Native installer failed, trying npm fallback..."
                npm install -g @anthropic-ai/claude-code \
                    || echo "[entrypoint] WARNING: Claude Code install failed."
            fi
        fi
        ;;
esac

case "$AGENT_CHOICE" in
    copilot|all)
        if ! command -v copilot &>/dev/null && command -v npm &>/dev/null; then
            echo "[entrypoint] Installing GitHub Copilot CLI..."
            npm install -g @github/copilot
        fi
        ;;
esac

case "$AGENT_CHOICE" in
    vibe|all)
        if ! command -v vibe &>/dev/null && command -v uv &>/dev/null; then
            echo "[entrypoint] Installing Mistral Vibe..."
            uv tool install mistral-vibe
        fi
        ;;
esac

# --- Claude Code plugins ---
# Install marketplace plugins natively in the container (skills come from the
# plugin, namespaced e.g. superpowers:brainstorming, and auto-update) rather
# than syncing the host's materialized skill copies. The marketplace is a
# public GitHub repo (GitHub is allowlisted in the firewall), so this works
# from inside the sandbox. Both commands are idempotent, so it's safe to run
# on every boot. Plugin state lives in the persistent ~/.claude volume.
#
# SANDBOX_CLAUDE_PLUGINS is a space-separated list of plugin@marketplace ids;
# SANDBOX_CLAUDE_MARKETPLACES is the matching list of marketplace sources to
# register first. Defaults install the superpowers skill set. Set either to
# an empty string to skip.
if [[ "$AGENT_CHOICE" == "claude" || "$AGENT_CHOICE" == "all" ]] \
        && command -v claude &>/dev/null; then
    marketplaces="${SANDBOX_CLAUDE_MARKETPLACES-anthropics/claude-plugins-official}"
    plugins="${SANDBOX_CLAUDE_PLUGINS-superpowers@claude-plugins-official}"
    for mkt in $marketplaces; do
        claude plugin marketplace add "$mkt" 2>/dev/null \
            || echo "[entrypoint] note: marketplace add '$mkt' failed (already added, or offline)"
    done
    for plg in $plugins; do
        if claude plugin list 2>/dev/null | grep -q "${plg%@*}"; then
            continue   # already installed
        fi
        echo "[entrypoint] Installing Claude plugin: $plg"
        claude plugin install "$plg" --scope user 2>/dev/null \
            || echo "[entrypoint] WARNING: plugin install '$plg' failed."
    done
fi

# --- Git HTTPS auth ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=$GITHUB_TOKEN"; }; f'
    # Sanity-check the token so a dead one is announced at boot instead of
    # surfacing mid-session as a baffling 401 from gh/git. Non-fatal: the
    # sandbox works without GitHub access.
    if command -v gh &>/dev/null; then
        if ! GH_TOKEN="$GITHUB_TOKEN" gh auth status &>/dev/null; then
            echo "[entrypoint] WARNING: GITHUB_TOKEN is set but GitHub rejects it" \
                 "(gh auth status failed) — expired or mis-injected. gh and git" \
                 "HTTPS operations will 401 until the host provides a fresh token."
        fi
    fi
fi

# --- Git identity ---
# Without this, the first commit fails with "Please tell me who you are".
# Overridable via GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL; otherwise a generic
# sandbox identity so commits don't hard-fail. The user pushes from the host,
# where their real identity applies.
git config --global --get user.email >/dev/null 2>&1 || \
    git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@agentic-sandbox.local}"
git config --global --get user.name >/dev/null 2>&1 || \
    git config --global user.name "${GIT_AUTHOR_NAME:-Agent Sandbox}"

# --- Ignore host-OS litter globally (macOS bind mounts drop .DS_Store etc.) ---
if [[ ! -f "$AGENT_HOME/.gitignore_global" ]]; then
    printf '.DS_Store\n._*\nThumbs.db\n' > "$AGENT_HOME/.gitignore_global"
fi
git config --global core.excludesfile "$AGENT_HOME/.gitignore_global"

# --- cd into the project ---
# PROJECT_DIR is the full-host-path mount; /$PROJECT_NAME is the legacy
# basename mount for containers created before PROJECT_DIR existed.
if [[ -n "${PROJECT_DIR:-}" && -d "$PROJECT_DIR" ]]; then
    cd "$PROJECT_DIR"
elif [[ -n "${PROJECT_NAME:-}" && -d "/$PROJECT_NAME" ]]; then
    cd "/$PROJECT_NAME"
fi

exec "$@"
