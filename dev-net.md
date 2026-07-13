# Dev networking design

This document describes how the sandbox is wired into a shared Docker network (`dev-net`) so the agent can reach your local DHIS2 (and other) dev containers directly, while still keeping a firewall on outbound internet traffic.

**Status:** implemented. The sandbox attaches to `dev-net` by default; the firewall is on by default. `host.docker.internal` is **not** broadly allowlisted — the only host-running services reachable from the sandbox are the DHIS2 instance broker (`d2-broker`, section 9) and the adb server for Android emulator testing (section 10), each on its single port, when configured.

## Architecture

```
                 ┌─────────────────────────────────────────────────┐
                 │ Host (macOS)                                    │
                 │                                                 │
   browser ──────┼──► localhost:8080  ──► dhis2 published port     │
                 │    localhost:49234 ──► sandbox published port   │
                 │                                                 │
                 │   ┌─────────────── dev-net (bridge) ────────┐   │
                 │   │                                          │   │
                 │   │  ┌─────────────┐   ┌─────────────┐       │   │
                 │   │  │ sandbox     │◄─►│ dhis2       │       │   │
                 │   │  │  agent      │   │ web         │       │   │
                 │   │  │             │   └─────────────┘       │   │
                 │   │  │             │   ┌─────────────┐       │   │
                 │   │  │             │◄─►│ dhis2-db    │       │   │
                 │   │  └──────┬──────┘   └─────────────┘       │   │
                 │   └─────────┼────────────────────────────────┘   │
                 │             │                                    │
                 │             ▼                                    │
                 │       iptables firewall (egress allowlist)       │
                 └─────────────┼────────────────────────────────────┘
                               ▼
                         internet (allowlist only)
```

Key properties:

- **Sandbox ↔ DHIS2 traffic** flows internally on `dev-net`. No firewall, no host hop. Resolved by container name via Docker's embedded DNS.
- **Sandbox → internet** goes through an iptables firewall that drops everything except an allowlist (Anthropic, npm, GitHub, pypi, dhis2.org, etc.).
- **Browser → DHIS2 admin UI** uses ports DHIS2 publishes to the host (e.g. `-p 8080:8080`).
- **Browser → sandbox-started service** (e.g. brainstorming visual companion) uses a port the sandbox pre-publishes (see "Random port" below).

## 1. The shared network

`agent-sandbox start` automatically creates `dev-net` if it doesn't already exist, and attaches the sandbox to it. So this is normally one-time, automatic.

If you want a specific subnet (e.g. to add a stable range to the firewall allowlist), pre-create it before starting any sandbox:

```bash
docker network create --subnet=172.30.0.0/16 dev-net
```

To opt out for a session, pass `--no-dev-net` to `agent-sandbox start`. The sandbox then runs on Docker's default bridge only.

## 2. Put DHIS2 dev containers on dev-net

### Single-container DHIS2 (docker run)

Add `--network dev-net` and give it a predictable `--name`:

```bash
docker run -d \
  --name dhis2 \
  --network dev-net \
  -p 8080:8080 \
  dhis2/core:2.41.0
```

The agent can then reach it inside the sandbox at `http://dhis2:8080`. The `-p 8080:8080` is only needed if **you** want to open it in your host browser.

### docker-compose DHIS2

If your DHIS2 is in a `docker-compose.yml`, declare `dev-net` as external and attach the services:

```yaml
services:
  web:
    image: dhis2/core:2.41.0
    container_name: dhis2          # so the sandbox can resolve it by name
    networks:
      - default                    # internal compose net (web ↔ db)
      - dev-net                    # shared net (sandbox ↔ web)
    ports:
      - "8080:8080"                # only if browser access is needed

  db:
    image: dhis2/postgres:...
    container_name: dhis2-db
    networks:
      - default                    # db talks only on the internal net

networks:
  default:
  dev-net:
    external: true                 # use the network created above
```

The `container_name` is what matters — without it, compose generates a random name (`projectname-web-1`) which the sandbox would need to resolve instead.

### Multiple DHIS2 versions side-by-side

If you run multiple DHIS2 instances, give each a distinct name (`dhis2-241`, `dhis2-242`, etc.) and the agent can reach each independently. Either set the active instance via env var at sandbox start, or have project-local CLAUDE.md state which name to use.

## 3. Launch the sandbox on dev-net

`agent-sandbox start` joins dev-net by default. To attach to additional networks:

```bash
agent-sandbox start ~/Repos/dhis2-app --network another-net
```

To opt out of dev-net entirely (use only Docker's default bridge):

```bash
agent-sandbox start ~/Repos/my-app --no-dev-net
```

Inside the sandbox (default case):

```bash
# These all work — Docker's embedded DNS resolves container names on dev-net
curl http://dhis2:8080/api/me
curl http://dhis2-db:5432
```

## 4. Random port for sandbox-started services

When the agent starts a server inside the sandbox (e.g. brainstorming visual companion, a vite dev server, a Playwright report viewer), you usually want to open it in your host browser. With bridge networking, the container's port is not reachable from the host unless explicitly published.

Pattern: the sandbox pre-allocates a random port at startup and tells the agent about it.

**On `agent-sandbox start`:**

1. Pick a random unused port in `49200–49300`. Verify it's free both on the host and in the container (low collision risk; this range is in the IANA dynamic range, well below 60000+ that's commonly used).
2. Publish it: `-p <port>:<port>`.
3. Set inside the container:
   - `SANDBOX_HOST_PORT=<port>` — env var
   - `/etc/sandbox-info` — file containing the port (for tools that don't read env)
4. Print on the host: `Sandbox port: 49234 → http://localhost:49234`

**Inside the sandbox**, agents that need to bind a port for browser access should bind `$SANDBOX_HOST_PORT`. For example:

```bash
# Inside sandbox
python -m http.server "$SANDBOX_HOST_PORT"
# Then on the host: open http://localhost:<that-port>
```

**For Claude's awareness:** the port is exposed as an env var and as the contents of `/etc/sandbox-info`. We deliberately do **not** write a snippet to `~/.claude/CLAUDE.md` — that file lives in the named `agentic-sandbox-claude` volume which is shared across every sandbox on the host, so writing port `49234` from one sandbox would clobber the value another sandbox is using and Claude in either session would see the wrong port.

To make Claude aware, either:
- Mention the port in your prompt: "use `$SANDBOX_HOST_PORT` for the visual companion"
- Add a project-level `CLAUDE.md` in repos that regularly need host-visible servers, with text like:
  > When starting any server the user should open in their browser, bind to `$SANDBOX_HOST_PORT` (set by the agent-sandbox container, also in `/etc/sandbox-info`).

The skills that take `--port` flags (brainstorming etc.) can be invoked with that env var.

### Why a port range and not a fixed port

Multiple sandboxes can run simultaneously. A fixed published port would cause `port already allocated` errors after the first sandbox grabs it. A range gives ~100 slots — enough for any reasonable number of concurrent sandboxes.

### What if Claude needs more than one port

Two reasonable answers:
1. **Multiple env vars**: allocate `SANDBOX_HOST_PORT_1`, `SANDBOX_HOST_PORT_2`, ... at start. Most agents don't need more than one — defer until a real case shows up.
2. **Document a manual flag**: `agent-sandbox start ... -p 5173 -p 8080` for explicitly-needed ports.

## 5. Firewall and dev-net

The egress firewall (adapted from Anthropic's `init-firewall.sh`) drops outbound to anything not on the allowlist. To not block intra-`dev-net` traffic:

- The firewall script detects each attached Docker network and adds its subnet to the allowlist before applying default-DROP.
- Specifically: read `/etc/resolv.conf` for the embedded DNS server (Docker uses 127.0.0.11), allow that; query Docker's metadata or use `ip route` to find the network's CIDR; add it via `iptables -A OUTPUT -d <subnet> -j ACCEPT`.

Anthropic's script already does the "host network" detection. Extending it to all attached Docker networks is one extra step.

## 6. MCP servers in the sandbox

The sandbox can't invoke stdio-type MCP servers that live on the host: the MCP stdio transport spawns a subprocess (`python -m my_mcp` or similar) and talks over its stdin/stdout, but the host's `/opt/homebrew/...` paths and Python virtualenvs aren't visible inside the container. The host config can't be copied as-is.

Two patterns that work:

1. **Install the MCP server inside the sandbox.** Bake it into the Dockerfile (`pip install my_mcp`, `npm install -g my-mcp`) or install on demand from the shell. Configure Claude's `mcpServers` to point at the in-container binary. Any auth/state goes in the agent's named volume so it persists across container rebuilds.

2. **Wrap the MCP server as a sibling container on `dev-net`.** Build a small image (often just `python:3.12-slim` with a pip install) that runs the MCP server with an HTTP transport. Start it once: `docker run -d --name my-mcp --network dev-net <image>`. From the sandbox, configure Claude to reach `http://my-mcp:PORT`. Survives sandbox rebuilds; works across multiple sandboxes simultaneously.

Pattern 1 is simplest when the MCP server is something pip/npm-installable and you mostly use it from one sandbox at a time. Pattern 2 is better when it's experimental, hard to install, or you want it shared across sandboxes.

`host.docker.internal` is **not** allowlisted in the firewall by default, so reaching a host-running MCP server over HTTP isn't possible without modifying `init-firewall.sh`. If you need that path, add `"host.docker.internal"` to the `DOMAINS` array, rebuild the image, and ensure the host service binds on `0.0.0.0` rather than `127.0.0.1`. (For a port-restricted example of this pattern, see how `DHIS2_BROKER_URL` is handled in `init-firewall.sh` — section 9.)

## 7. CORS and auth inside dev-net

A few gotchas when the agent is now reaching DHIS2 by container name rather than `localhost`:

- **`d2auth.json` and similar**: any project config that hard-codes `http://localhost:8080` needs to also accept `http://dhis2:8080`, or the project should read from env vars instead. Best: configure your dev tooling (vite, webpack, etc.) to take `DHIS2_BASE_URL` from env.
- **CORS allowlist on the DHIS2 side**: if you're testing a webapp running inside the sandbox (e.g. vite dev server on port 5173) against DHIS2, DHIS2 needs `http://localhost:5173` in its `corsWhitelist` (the dev server gets reached from the host browser, not from inside the network). The agent could also test via container-to-container HTTP without a browser, in which case CORS doesn't apply.
- **DHIS2 SPA login**: as noted in the gaps document, the React-rendered login form on `/dhis-web-login/` doesn't accept programmatic form fills. Use `POST /api/auth/login` with JSON body to get a JSESSIONID cookie, then attach it to subsequent requests or to Playwright's browser context.

## 8. Migration steps (historical — already applied)

1. Create the network: `docker network create dev-net`.
2. Update DHIS2 containers/compose to join `dev-net` (with stable `container_name`).
3. Adopt `init-firewall.sh` from Anthropic's reference into this repo; extend to allow `dev-net` subnet.
4. Update `Dockerfile` to install iptables/ipset, copy the script in.
5. Update `docker-compose.yml` and `agent-sandbox.sh` to:
   - Switch `network_mode: host` → bridge default
   - Add `--cap-add=NET_ADMIN --cap-add=NET_RAW`
   - Run `init-firewall.sh` from entrypoint (or post-start)
   - Accept `--network NAME` (repeatable)
   - Pre-allocate the random port and set `SANDBOX_HOST_PORT`
   - Write the CLAUDE.md hint
   - Accept `--host-network` as opt-out
6. Verify firewall at startup: curl example.com (should fail), curl api.anthropic.com (should succeed), curl http://dhis2:8080 (should succeed once on dev-net).
7. Update README to document the new flow.

## 9. DHIS2 instance broker (d2-broker)

The one sanctioned sandbox→host channel. The host runs
[`d2-broker`](https://github.com/olavpo/dhis2-docker-tools) (from
dhis2-docker-tools), a token-authenticated HTTP API over the `d2-*` instance
scripts. Agents inside the sandbox can create, reset, start/stop and delete
**disposable DHIS2 test instances** without any host shell or Docker access.

How the pieces fit:

- **Host**: `d2-broker install` runs the broker as a launchd agent on port
  9300 (configurable via `D2_BROKER_PORT`). Tokens live in
  `$DHIS2_BASE/_broker/tokens.json`.
- **`agent-sandbox start`**: if that token file exists, the *agent-scoped*
  token is passed into the container as `DHIS2_BROKER_TOKEN`, together with
  `DHIS2_BROKER_URL` (default `http://host.docker.internal:9300`). Opt out
  with `--no-dhis2-broker`.
- **Firewall**: `init-firewall.sh` resolves the URL's host and allows egress
  to **that host:port only** — the rest of the host stays unreachable. This
  works because Docker Desktop's `host.docker.internal` resolves via the
  embedded DNS.
- **Agent guardrails** (enforced by the broker, not the sandbox): the agent
  token can only manage instances named `agent-*`, can only seed them from
  the curated `$DHIS2_BASE/_seeds/` directory (never real-data backups,
  arbitrary paths, or URLs), and is capped in instance count. Created
  instances join `dev-net`, so the agent reaches them at
  `http://dhis2-<name>:8080`.

Full API contract and security model: `broker.md` in the dhis2-docker-tools
repo. Agent-facing usage doc: the `dhis2-instances` skill (synced into
sandboxes like any other skill).

## 10. Android emulator testing (adb)

The second sanctioned sandbox→host channel, following the same pattern as the
broker. The Android emulator cannot run inside the sandbox (no nested
virtualization in Docker's Linux VM on macOS), so it runs on the host and the
sandbox drives it remotely through the host's adb server:

- **Host**: an Android emulator (AVD) plus an adb server on port 5037. The
  default loopback bind is enough — Docker Desktop forwards
  `host.docker.internal` traffic from the host's loopback, so nothing needs
  to listen on external interfaces.
- **`agent-sandbox start`**: if something is listening on the host's adb port
  (5037, override with `SANDBOX_ADB_PORT`), the socket is passed into the
  container as `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037`. Opt out
  with `--no-adb`.
- **Firewall**: `init-firewall.sh` opens egress to **that host:port only**,
  exactly like the broker exemption.
- **In the sandbox**: the `adb` client (baked into the image) reads
  `ADB_SERVER_SOCKET` natively, so `adb devices`, `adb install`,
  `adb exec-out screencap`, `adb shell input ...` etc. all hit the host's
  emulator with no further setup.
- **App → DHIS2**: the emulator is on the host, not on dev-net. Apps on the
  emulator reach broker-created DHIS2 instances via the host-published port:
  `http://10.0.2.2:<http_port>` (the broker's `GET /instances` returns
  `http_port` per instance).

Host setup (emulator install, launchd service, getting the APK):
`android-testing.md` in this repo.

## See also

- Anthropic's reference `init-firewall.sh`: <https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh>
- Docker user-defined networks: <https://docs.docker.com/network/network-tutorial-standalone/#use-user-defined-bridge-networks>
- DHIS2 dev environment notes: see your project-level docs or the gaps notebook.
