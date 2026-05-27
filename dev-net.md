# Dev networking design

This document describes how to wire the sandbox into a shared Docker network so the agent can reach your local DHIS2 (and other) dev containers directly, while still keeping a firewall on outbound internet traffic.

**Status:** design only. Not implemented yet. Apply when ready to migrate from `--network=host` to bridge + firewall.

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

## 1. Create the shared network

One-time, on the host:

```bash
docker network create dev-net
```

You can also pick a specific subnet if you want a stable range to add to the firewall allowlist:

```bash
docker network create --subnet=172.30.0.0/16 dev-net
```

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

Future `agent-sandbox start` will accept `--network`:

```bash
agent-sandbox start ~/Repos/dhis2-app --network dev-net
```

Multiple networks (e.g. dev-net plus a separate db-net) can be attached by passing `--network` more than once.

Inside the sandbox:

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

## 6. CORS and auth inside dev-net

A few gotchas when the agent is now reaching DHIS2 by container name rather than `localhost`:

- **`d2auth.json` and similar**: any project config that hard-codes `http://localhost:8080` needs to also accept `http://dhis2:8080`, or the project should read from env vars instead. Best: configure your dev tooling (vite, webpack, etc.) to take `DHIS2_BASE_URL` from env.
- **CORS allowlist on the DHIS2 side**: if you're testing a webapp running inside the sandbox (e.g. vite dev server on port 5173) against DHIS2, DHIS2 needs `http://localhost:5173` in its `corsWhitelist` (the dev server gets reached from the host browser, not from inside the network). The agent could also test via container-to-container HTTP without a browser, in which case CORS doesn't apply.
- **DHIS2 SPA login**: as noted in the gaps document, the React-rendered login form on `/dhis-web-login/` doesn't accept programmatic form fills. Use `POST /api/auth/login` with JSON body to get a JSESSIONID cookie, then attach it to subsequent requests or to Playwright's browser context.

## 7. Migration steps (when ready)

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

## See also

- Anthropic's reference `init-firewall.sh`: <https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh>
- Docker user-defined networks: <https://docs.docker.com/network/network-tutorial-standalone/#use-user-defined-bridge-networks>
- DHIS2 dev environment notes: see your project-level docs or the gaps notebook.
