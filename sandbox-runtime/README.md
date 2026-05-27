# Agentic Sandbox

A lightweight wrapper around [Anthropic's sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) for running Claude Code (and other agents/commands) with strict filesystem and network restrictions.

By default Claude can only:
- **Read** the current project, `/tmp`, `~/.claude`, `~/Downloads`, `~/Desktop`, and your skills repo
- **Write** to the current project, `/tmp`, and Claude's own config
- **Reach** Anthropic, GitHub, npm, pypi, and a small list of dev-tool CDNs

Everything else (credentials, SSH keys, cloud storage, command histories, app state under `~/Library`, etc.) is **denied by default**.

## Requirements

- macOS or Linux (Windows not supported)
- [Node.js](https://nodejs.org) (for sandbox-runtime)
- [`jq`](https://stedolan.github.io/jq/) (for settings manipulation)

## Setup

One-time install:

```bash
npm install -g @anthropic-ai/sandbox-runtime
brew install jq          # macOS — or: apt-get install jq

# Clone this repo and symlink agent-sandbox into your PATH
git clone <this-repo> ~/Repos/ai-agentic-sandbox
ln -s ~/Repos/ai-agentic-sandbox/agent-sandbox.sh /usr/local/bin/agent-sandbox

# Check the setup
agent-sandbox doctor
```

Then from any project directory:

```bash
cd ~/Repos/my-project
agent-sandbox          # launches Claude with the bundled default policy
claude login           # one-time login (persists in ~/.claude)
```

## Usage

```
agent-sandbox [options] [COMMAND...]

With no COMMAND, launches `claude`.

Options:
  --settings PATH     Use a specific settings file
  --profile NAME      Use bundled profile <repo>/settings/NAME.json
                      (currently: default, strict)
  -h, --help          Show help

Subcommands:
  init [--strict]     Copy default (or strict) profile to ./.srt-settings.json
  status              Print the resolved settings path + final policy
  doctor              Check dependencies are installed
```

Examples:
```bash
agent-sandbox                          # claude with defaults
agent-sandbox bash                     # wrap a shell instead
agent-sandbox --profile strict         # strict allowlist (Anthropic + npm only)
agent-sandbox --settings ./mine.json   # custom settings file
agent-sandbox init                     # seed ./.srt-settings.json
agent-sandbox init --strict            # seed from the strict profile
agent-sandbox status                   # what's in effect here?
```

## Settings resolution

The wrapper picks **one** settings file per invocation — first match wins:

1. `--settings PATH` flag
2. `--profile NAME` flag → `<repo>/settings/NAME.json`
3. `./.srt-settings.json` in the current directory
4. `~/.srt-settings.json` (your user global, if you created one)
5. `<repo>/settings/default.json` (bundled fallback — always present)

There's no merging — if you create a project-local file you start from a copy of the default (or strict) profile via `agent-sandbox init`, then edit.

## What's in the default policy

### Network: domain allowlist

```
api.anthropic.com, *.anthropic.com
github.com, *.github.com, raw.githubusercontent.com, codeload.github.com, ...
registry.npmjs.org, *.npmjs.org, registry.yarnpkg.com
pypi.org, files.pythonhosted.org
deb.nodesource.com, deb.debian.org
playwright.azureedge.net, cdn.playwright.dev
```

Anything else is blocked (or prompts, depending on the sandbox-runtime mode).

### Filesystem: deny-all-home, then allow back

The default explicitly **denies reads on `~/`** and re-allows only:
- `.` (the project — cwd at launch)
- `/tmp`
- `~/.claude`, `~/.claude.json` — Claude's own config
- `~/.cache` — package manager caches
- `~/Downloads`, `~/Desktop` — convenience
- `~/Repos/ai-skills` — symlink targets for skills

This rule blocks **everything else** in your home directory without enumerating it: credentials (`~/.aws`, `~/.ssh`, `~/.docker`, `~/.kube`, `~/.gnupg`, `~/.config/gh`, `~/.npm`, etc.), shell/REPL histories (`~/.zsh_history`, `~/.python_history`, ...), VPN configs (`~/.cisco`, `~/.vmware`, ...), personal content (`~/Documents`, `~/Music`, `~/Pictures`, ...), cloud storage (iCloud Drive, Google Drive, OneDrive), and all of `~/Library`.

### Filesystem: writes are allow-only

Writes default to denied. The default allows:
- `./` (project)
- `/tmp`
- `~/.claude`, `~/.claude.json`
- `~/.cache`

Specific files are denied even within those:
- `./.srt-settings.json` — the sandbox policy itself (prevents the agent from rewriting its own rules)
- `./.claude/settings.json`, `./.claude/settings.local.json` — Claude Code project settings (hooks/permissions)

The wrapper also dynamically appends the actual resolved settings file path to `denyWrite` at launch, so a custom file passed via `--settings` is still protected.

### Environment scrubbing

Your shell may have sensitive variables exported (`AWS_ACCESS_KEY_ID`, third-party API keys, etc.). The wrapper uses `env -i` to clear the environment, then passes through:

- Always: `HOME`, `USER`, `PATH`, `SHELL`, `TERM`, `LANG`, `LC_*`, `TZ`, `PWD`, `OLDPWD`
- Opt-in via the settings `passEnv` array: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*`

So `AWS_ACCESS_KEY_ID` in your shell does **not** leak into the agent unless you explicitly add it to `passEnv`.

## GitHub access

Claude Code uses `GITHUB_TOKEN` for HTTPS git auth and `gh` operations. Two patterns:

- Set `GITHUB_TOKEN` in your shell. The default `passEnv` lets it through.
- Or set `SANDBOX_GITHUB_TOKEN` instead — the wrapper renames it to `GITHUB_TOKEN` inside the sandbox. Useful if you want a different (e.g. read-only) token for sandbox use without changing your host shell.

### Read-only Git access (recommended)

To prevent the agent from pushing or merging, use a **fine-grained** GitHub PAT:

1. **GitHub Settings → Developer settings → Fine-grained tokens**
2. **Repository access**: All repositories (or specific repos)
3. **Permissions → Contents**: **Read-only**
4. **Permissions → Pull requests**: **Read-only** (optional)
5. Set as `SANDBOX_GITHUB_TOKEN` in your shell

Local git operations (commit, branch, diff, log) still work — only remote pushes are blocked, and that's enforced server-side, so no sandbox bypass can circumvent it.

## Per-project customization

If a project needs extra hosts, paths, or env vars:

```bash
cd ~/Repos/my-project
agent-sandbox init                     # creates ./.srt-settings.json
$EDITOR .srt-settings.json             # add to allowedDomains / allowRead / etc.
agent-sandbox                          # picks up the project-local file
agent-sandbox status                   # confirm what's resolved
```

The project-local file is **not** automatically loaded by sandbox-runtime — the wrapper is what looks for it. So this only works when you launch via `agent-sandbox`.

You probably want to `gitignore` `./.srt-settings.json` if it contains anything you don't want to share.

## Profiles

- **`default`** — moderate: GitHub, npm, pypi, common dev hosts. Project + `/tmp` + `~/.claude` writable. Good for most work.
- **`strict`** — minimal: only Anthropic and npm registry. For projects where you want explicit prompts on every other domain.

Switch with `--profile strict` or seed via `agent-sandbox init --strict`.

## Resetting Claude state

Your login and settings live in `~/.claude/`. To start fresh:

```bash
mv ~/.claude ~/.claude.backup        # or just rm -rf if you don't want the backup
```

Then run `agent-sandbox` and `claude login` again.

## Limitations

- **Same-user execution**: sandbox-runtime restricts processes via OS primitives (Seatbelt on macOS, bubblewrap on Linux), but the agent runs as your user. If the agent escapes the sandbox, it has your permissions. This is a weaker boundary than a container with separate UID/GID.
- **Hostname-only network filtering**: the proxy filters outbound traffic by hostname without TLS inspection. Domain fronting is possible if `allowedDomains` is broad. For threat models that need TLS-aware filtering, set up a custom proxy and import its CA into the sandbox.
- **No resource limits**: unlike Docker, sandbox-runtime doesn't cap memory or CPU.
- **Beta software**: sandbox-runtime is marked experimental upstream.

For stronger isolation (kernel-level + multi-agent + resource limits) the Docker-based setup is preserved in `legacy-docker/`. See `legacy-docker/README-legacy.md`.

## Project structure

```
.
├── agent-sandbox.sh        # wrapper script
├── settings/
│   ├── default.json        # moderate defaults
│   └── strict.json         # minimal allowlist
├── legacy-docker/          # archived Docker-based setup
│   └── README-legacy.md
├── LICENSE
└── README.md
```

## Troubleshooting

- **`srt: command not found`** — `npm install -g @anthropic-ai/sandbox-runtime`
- **`jq: command not found`** — `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **Claude says "login required" every time** — make sure `~/.claude` is writable (it is by default) and that you ran `claude login` once
- **A skill fails with "permission denied" reading files** — the skill probably symlinks into a directory outside `~/Repos/ai-skills`. Add the target path to `allowRead` in your settings.
- **Build hangs trying to reach an external host** — that host isn't in `allowedDomains`. Add it to a project-local settings file or accept the prompt.
- **What's the actual policy in effect?** — `agent-sandbox status` from inside the project.

## License

BSD 3-Clause. See `LICENSE`.
