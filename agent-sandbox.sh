#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE_NAME="agentic-sandbox:latest"
VOLUME_PREFIX="agentic-sandbox"
AGENT_USER="agent"   # matches USERNAME in the Dockerfile

# Load .env file if present (won't override existing env vars)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

usage() {
    cat <<'USAGE'
Usage: agent-sandbox <command> [options]

Commands:
  start <project-dir>    Start a new sandbox with the given project mounted
  shell [container]      Open a shell in a running sandbox (default: agentic-sandbox)
  stop  [container]      Stop a running sandbox
  remove <container>     Remove a sandbox container (volumes preserved)
  sudo <container> [on|off]
                         Grant or revoke the agent's general sudo in a running
                         sandbox until its next restart. No argument: show the
                         current state.
  reset-config           Wipe all agent config volumes (auth, settings, skills)
  list                   List running sandboxes
  build                  Rebuild the sandbox image
  extend <dockerfile>    Build a custom image extending the base sandbox
  sync-skills [container] [push|pull]  Sync skills between host and container

Options for `start`:
  -n, --name NAME        Container name (default: agentic-sandbox)
  --agent NAME           Which agent to install/mount: claude (default), copilot,
                         vibe, or all. Only the chosen agent's config volume is
                         mounted; only that agent is installed at first start.
  -e, --env KEY=VAL      Pass extra environment variable (repeatable)
  --network NAME         Attach to an *additional* Docker network (repeatable).
                         The sandbox is already on `dev-net` by default; use this
                         to also join a second network.
  --no-dev-net           Skip attaching to dev-net (the default shared network).
  -p, --port HOST:CONT   Publish an additional port (repeatable). Two random ports from
                         49200-49300 are always published as SANDBOX_HOST_PORT and
                         SANDBOX_HOST_PORT_2.
  --host-network         Opt out of bridge networking and firewall. Use --network=host
                         and skip iptables. SANDBOX_HOST_PORT is not set.
  --allow-sudo           Give the agent general passwordless sudo. Off by
                         default: the agent has no root, so it cannot flush the
                         egress firewall — and cannot apt-get. Set
                         SANDBOX_ALLOW_SUDO=1 in your environment or .env to make
                         it the default. For a one-off need in a strict sandbox,
                         `agent-sandbox sudo <container> on` grants it until the
                         next restart instead.
  --no-config            Don't mount agent config directories
  --no-dhis2-broker      Don't wire up the DHIS2 instance broker (d2-broker).
                         By default, if $DHIS2_BASE/_broker/tokens.json exists
                         on the host, the agent-scoped token and broker URL are
                         passed in as DHIS2_BROKER_TOKEN / DHIS2_BROKER_URL and
                         the firewall opens that single host port.
  --no-adb               Don't wire up the host's adb server (Android emulator
                         testing). By default, if an adb server is listening on
                         the host (port 5037, override with SANDBOX_ADB_PORT),
                         ADB_SERVER_SOCKET is passed in and the firewall opens
                         that single host port. See android-testing.md.

Examples:
  agent-sandbox start ~/projects/my-app
  agent-sandbox start ~/projects/my-app --agent vibe       # only Mistral Vibe
  agent-sandbox start ~/projects/my-app --agent all        # all three agents
  agent-sandbox start ~/projects/my-app -n my-sandbox -e MY_VAR=hello
  agent-sandbox start ~/projects/dhis2-app --network dev-net
  agent-sandbox start ~/projects/my-app -p 5173:5173
  agent-sandbox start ~/projects/my-app --host-network    # no firewall (legacy mode)
  agent-sandbox shell
  agent-sandbox shell my-sandbox
  agent-sandbox stop
  agent-sandbox extend ./my-extensions.Dockerfile
  agent-sandbox sync-skills              # interactive: show diff, choose direction
  agent-sandbox sync-skills push         # push host skills to any running sandbox
  agent-sandbox sync-skills pull         # pull container skills to host
  agent-sandbox sync-skills my-sandbox push  # target a specific container
USAGE
}

# Find an unused TCP port in the 49200-49300 range.
# Echoes the port number on stdout, or returns non-zero if no port is free.
# An optional first argument is a port to skip (so callers can pick a second,
# distinct port that the not-yet-bound first pick would otherwise collide with).
pick_port() {
    local exclude="${1:-}"
    local candidate
    local attempts=30
    for ((i=0; i<attempts; i++)); do
        candidate=$((49200 + RANDOM % 101))
        [[ -n "$exclude" && "$candidate" == "$exclude" ]] && continue
        # Skip ports already in use on the host (any state, not just LISTEN, to
        # avoid TIME_WAIT collisions when re-creating sandboxes quickly).
        if ! lsof -nP -iTCP:"$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Rebuilding with the same tag moves ':latest' to the new image and leaves the
# previous one untagged (<none>:<none>) but still on disk — ~2.7 GB a piece,
# which is what makes them pile up in Docker Desktop. Drop the one we just
# replaced, but only if nothing references it. Deliberately targeted at this
# image rather than `docker image prune`, which would also delete unrelated
# dangling images from other projects.
prune_previous_image() {
    local old_id="$1" new_id users short
    [[ -z "$old_id" ]] && return 0
    short="${old_id#sha256:}"; short="${short:0:12}"

    new_id=$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)
    # Cache hit: the rebuild produced the same image, so there is nothing to drop.
    [[ "$old_id" == "$new_id" ]] && return 0

    # Containers still on the old image pin it — including stopped sandboxes,
    # which is why old images can legitimately survive a rebuild. `docker rmi`
    # would refuse anyway; checking first keeps the output honest.
    users=$(docker ps -a --filter "ancestor=$old_id" --format '{{.Names}}' | paste -sd' ' -)
    if [[ -n "${users// /}" ]]; then
        echo "  Previous image kept — still used by: $users"
        echo "  It is removed once those sandboxes are gone (agent-sandbox remove <name>)."
        return 0
    fi

    if docker rmi "$old_id" >/dev/null 2>&1; then
        echo "  Removed previous image ($short)."
    else
        echo "  Note: could not remove previous image ($short); left in place."
    fi
}

build_image() {
    local old_id
    old_id=$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME" 2>/dev/null || true)
    echo "Building sandbox image..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    prune_previous_image "$old_id"
}

ensure_image() {
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        build_image
    fi
}

cmd_build() {
    build_image
}

# Block until the entrypoint signals that egress is filtered. `docker run` and
# `docker start` both return before the firewall is configured, and `docker
# exec` bypasses the entrypoint's ordering, so attaching early means attaching
# to an unfiltered container. The entrypoint clears the marker on every start,
# so a restart cannot be satisfied by a stale one.
wait_for_firewall() {
    local c="$1" i
    # Sandboxes created before the handshake existed never write the marker, and
    # cannot be made to: image content is fixed at creation. Waiting on them
    # would block for the full timeout and then refuse to attach, so probe the
    # container's own entrypoint for the capability first.
    if ! docker exec "$c" grep -q sandbox-firewall-ready \
            /usr/local/bin/entrypoint.sh 2>/dev/null; then
        echo "Note: '$c' predates the firewall readiness handshake; attaching without it."
        echo "  It also lacks pinned DNS, fail-closed init and the self-healing loop."
        echo "  Recreate it to pick those up: agent-sandbox remove $c"
        return 0
    fi
    for ((i = 0; i < 90; i++)); do
        docker exec "$c" test -f /tmp/sandbox-firewall-ready 2>/dev/null && return 0
        # Firewall init fails closed, so a container that refused to come up
        # unprotected has exited rather than sitting there unfiltered.
        if ! docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
            echo "Error: sandbox '$c' exited during startup." >&2
            echo "  Firewall init likely failed. Inspect with: docker logs $c" >&2
            exit 1
        fi
        sleep 1
    done
    echo "Error: firewall did not come up within 90s; refusing to attach." >&2
    echo "  Inspect with: docker logs $c" >&2
    exit 1
}

cmd_start() {
    local project_dir=""
    local container_name="agentic-sandbox"
    local extra_envs=()
    local mount_config=true
    local extra_networks=()
    local extra_ports=()
    local host_network=false
    local use_devnet=true
    local use_dhis2_broker=true
    local use_adb=true
    local agent_choice="claude"
    # Whether the agent gets general passwordless sudo in this sandbox. Strict
    # (no sudo) unless SANDBOX_ALLOW_SUDO=1 — from the environment or .env, which
    # is sourced above — so setting it there flips the default for every
    # sandbox, including the ones `sbx` creates, without any flag plumbing in
    # `sbx` itself.
    local allow_sudo="${SANDBOX_ALLOW_SUDO:-0}"
    if [[ "${SANDBOX_STRICT_SUDO:-}" == "1" ]]; then
        echo "Note: SANDBOX_STRICT_SUDO is ignored — strict is now the default. Use SANDBOX_ALLOW_SUDO=1 to opt in." >&2
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) container_name="$2"; shift 2 ;;
            -e|--env) extra_envs+=(-e "$2"); shift 2 ;;
            --network) extra_networks+=("$2"); shift 2 ;;
            --no-dev-net) use_devnet=false; shift ;;
            -p|--port|--publish) extra_ports+=(-p "$2"); shift 2 ;;
            --host-network) host_network=true; shift ;;
            --no-config) mount_config=false; shift ;;
            --no-dhis2-broker) use_dhis2_broker=false; shift ;;
            --no-adb) use_adb=false; shift ;;
            --allow-sudo) allow_sudo=1; shift ;;
            --strict-sudo|--no-strict-sudo)
                echo "Error: $1 was removed — strict sudo is now the default." >&2
                echo "  Use --allow-sudo to give the agent general sudo." >&2
                exit 1 ;;
            --agent)
                agent_choice="$2"
                case "$agent_choice" in
                    claude|copilot|vibe|all) ;;
                    *) echo "Error: --agent must be one of: claude, copilot, vibe, all" >&2; exit 1 ;;
                esac
                shift 2
                ;;
            -*) echo "Unknown option: $1"; usage; exit 1 ;;
            *)
                if [[ -z "$project_dir" ]]; then
                    project_dir="$1"
                elif [[ "$container_name" == "agentic-sandbox" ]]; then
                    container_name="$1"
                fi
                shift ;;
        esac
    done

    if [[ -z "$project_dir" ]]; then
        echo "Error: project directory required"
        usage
        exit 1
    fi

    project_dir="$(cd "$project_dir" && pwd -P)"

    if ! [[ -d "$project_dir" ]]; then
        echo "Error: $project_dir is not a directory"
        exit 1
    fi

    ensure_image

    # If a container with this name already exists, resume it if stopped, or warn if running.
    # Resuming reuses the container as created: the sudo mode and the capabilities the
    # wrapper needs are fixed by `docker run`, so --allow-sudo cannot be applied after
    # the fact. Say so rather than appearing to honour it.
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        if [[ "$allow_sudo" == "1" ]]; then
            echo "Note: --allow-sudo only applies when a sandbox is created; '$container_name' already exists."
            echo "  For this session: agent-sandbox sudo $container_name on (lasts until restart)."
            echo "  To switch it for good: agent-sandbox remove $container_name, then start again with --allow-sudo."
        fi
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo "Sandbox '$container_name' is already running."
            echo "  Attach with: agent-sandbox shell $container_name"
            return
        fi
        echo "Resuming stopped sandbox '$container_name'..."
        docker start "$container_name" >/dev/null
        wait_for_firewall "$container_name"
        echo "Sandbox running. Attach with:"
        echo "  agent-sandbox shell $container_name"
        return
    fi

    local project_name
    project_name="$(basename "$project_dir")"
    # Mount the project at its full host path. The in-container path is what
    # keys Claude Code's per-project session history (in the shared config
    # volume), so it must be unique per project — basenames alone collide.
    local volumes=(-v "$project_dir:$project_dir")

    if $mount_config; then
        # gh config is generic (git auth); always mount it.
        volumes+=(-v "${VOLUME_PREFIX}-gh:/home/agent/.config/gh")

        # Mount only the chosen agent's config volume. Each is a named volume
        # so the auth/state persists across sandbox restarts even though it's
        # only mounted in sessions that need it.
        case "$agent_choice" in
            claude|all) volumes+=(-v "${VOLUME_PREFIX}-claude:/home/agent/.claude") ;;
        esac
        case "$agent_choice" in
            copilot|all) volumes+=(-v "${VOLUME_PREFIX}-copilot:/home/agent/.copilot") ;;
        esac
        case "$agent_choice" in
            vibe|all) volumes+=(-v "${VOLUME_PREFIX}-vibe:/home/agent/.vibe") ;;
        esac
    fi

    # --- Shared infrastructure-lessons directory ---
    # One host directory, mounted read-WRITE at the same path in every sandbox,
    # so the infra-lessons skill can keep a single LESSONS.md plus a per-sandbox
    # lessons-scratch-<hostname>.md. Deliberately under /mnt and NOT inside the
    # project mount or /workspaces: project tooling that walks the tree (prettier,
    # eslint) must never find it. Only mounted when the host directory exists, so
    # a checkout without one is unaffected.
    local lessons_dir="${SANDBOX_LESSONS_DIR:-$HOME/Repos/AI/ai-agent-lessons}"
    local lessons_active=""
    if [[ -d "$lessons_dir" ]]; then
        volumes+=(-v "$lessons_dir:/mnt/lessons")
        lessons_active="$lessons_dir"
    fi

    # NOTE: a per-sandbox CLAUDE.md bind-mounted over the shared volume's copy
    # was tried and rejected. It works until any container replaces the shared
    # volume's CLAUDE.md by rename — which every sandbox built before that change
    # does on boot — at which point the nested mount is orphaned and running
    # sandboxes silently fall back to the shared file. Silent is worse than
    # wrong, so per-sandbox facts are handled in the brief instead: it tells the
    # agent to check its own sudo rather than asserting a mode. See entrypoint.sh.

    # --- Host-managed CLAUDE.md addendum ---
    # Read-only so the agent cannot rewrite the host's copy. entrypoint.sh splices
    # it into ~/.claude/CLAUDE.md inside the sandbox brief's markers, which means
    # it is refreshed on every boot and cannot drift from the host file. Kept out
    # of this repo on purpose: private guidance should not live in a public repo.
    local host_claude_md="${SANDBOX_CLAUDE_MD:-$HOME/.claude/sandbox-CLAUDE.md}"
    local host_claude_md_active=""
    if [[ -f "$host_claude_md" ]]; then
        volumes+=(-v "$host_claude_md:/mnt/host-claude-md:ro")
        host_claude_md_active="$host_claude_md"
    fi

    # Pass through API keys if set on host
    local env_args=(
        -e "PROJECT_NAME=$project_name"
        -e "PROJECT_DIR=$project_dir"
        -e "SSH_AUTH_SOCK="
        -e "AGENT_CHOICE=$agent_choice"
    )
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [[ -n "${OPENAI_API_KEY:-}" ]]    && env_args+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
    [[ -n "${MISTRAL_API_KEY:-}" ]]   && env_args+=(-e "MISTRAL_API_KEY=$MISTRAL_API_KEY")
    # GitHub access: ONLY the dedicated read-only sandbox token. Never fall
    # back to the user's personal GITHUB_TOKEN — agents must not inherit
    # broader scopes than the sandbox token grants.
    if [[ -n "${SANDBOX_GITHUB_TOKEN:-}" ]]; then
        env_args+=(-e "GITHUB_TOKEN=$SANDBOX_GITHUB_TOKEN")
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "Note: GITHUB_TOKEN is set but ignored — sandboxes only get the" >&2
        echo "      dedicated read-only token. Set SANDBOX_GITHUB_TOKEN to grant GitHub access." >&2
    fi

    # --- DHIS2 instance broker (d2-broker from dhis2-docker-tools) ---
    # If the host runs the broker, pass the agent-scoped token (restricted to
    # agent-* instances and curated seeds) plus the URL into the sandbox. The
    # in-container firewall reads DHIS2_BROKER_URL and opens egress to that
    # single host:port.
    local dhis2_broker_active=""
    if $use_dhis2_broker && [[ -n "${DHIS2_BASE:-}" && -f "$DHIS2_BASE/_broker/tokens.json" ]]; then
        local broker_agent_token
        broker_agent_token=$(python3 -c \
            'import json,sys; print(json.load(open(sys.argv[1]))["agent"]["token"])' \
            "$DHIS2_BASE/_broker/tokens.json" 2>/dev/null || true)
        if [[ -n "$broker_agent_token" ]]; then
            local broker_url="${DHIS2_BROKER_URL:-http://host.docker.internal:${D2_BROKER_PORT:-9300}}"
            env_args+=(-e "DHIS2_BROKER_URL=$broker_url")
            env_args+=(-e "DHIS2_BROKER_TOKEN=$broker_agent_token")
            dhis2_broker_active="$broker_url"
        fi
    fi

    # --- Android emulator / adb on the host (android-testing.md) ---
    # If an adb server is listening on the host, pass its socket into the
    # sandbox so the in-container adb client (and anything built on it) can
    # drive the host's Android emulator. Docker Desktop forwards
    # host.docker.internal traffic from the host's loopback, so the default
    # loopback-bound adb server is reachable — no all-interfaces bind needed.
    # The in-container firewall reads ADB_SERVER_SOCKET and opens egress to
    # that single host:port.
    local adb_active=""
    if $use_adb; then
        local adb_port="${SANDBOX_ADB_PORT:-5037}"
        if lsof -nP -iTCP:"$adb_port" -sTCP:LISTEN >/dev/null 2>&1; then
            local adb_socket="${SANDBOX_ADB_SERVER:-tcp:host.docker.internal:${adb_port}}"
            env_args+=(-e "ADB_SERVER_SOCKET=$adb_socket")
            adb_active="$adb_socket"
        fi
    fi

    # --- Networking + ports ---
    # Default: bridge (default Docker network), egress firewall on, plus a
    # random pre-published host port (SANDBOX_HOST_PORT) so the agent can
    # bind something the user can open in their host browser.
    #
    # Opt-out: --host-network uses --network=host and skips the firewall.
    # This is the legacy behavior; loses egress restrictions.
    #
    # Joining a user-defined network: pass --network NAME (repeatable). docker
    # run only accepts one --network, so the first goes into the run command
    # and any extras are attached afterward via `docker network connect`.
    local net_args=()
    # SYS_PTRACE lets the root privileged-boot wrapper read /proc/1/environ,
    # which is how it gets its config from a source the container cannot forge.
    # Reading another uid's environ is a ptrace-mode access, so plain root is not
    # enough and Docker's default capability set omits this one. It grants the
    # agent nothing: capabilities belong to processes, and the agent is not root
    # (strict mode) or already has root anyway (permissive mode).
    local cap_args=(--cap-add=SYS_PTRACE)
    local port_args=()
    local sandbox_port=""
    local sandbox_port2=""

    # Read by sandbox-privileged-boot.sh from /proc/1/environ at every boot, so
    # the mode is fixed for the life of the container but re-applied on each
    # start rather than being a one-way change to its filesystem. Absent means
    # strict.
    if [[ "$allow_sudo" == "1" ]]; then
        env_args+=(-e "SANDBOX_ALLOW_SUDO=1")
    fi

    if $host_network; then
        net_args=(--network=host)
        env_args+=(-e "SANDBOX_SKIP_FIREWALL=1")
    else
        cap_args+=(--cap-add=NET_ADMIN --cap-add=NET_RAW)
        # Two host-visible ports by default: enough for an App Platform app that
        # serves a dev server on one and its proxy on the other, without the
        # user having to remember explicit -p flags. Use -p for a third+.
        if ! sandbox_port=$(pick_port); then
            echo "Error: could not find a free port in 49200-49300 on the host." >&2
            exit 1
        fi
        port_args+=(-p "${sandbox_port}:${sandbox_port}")
        env_args+=(-e "SANDBOX_HOST_PORT=$sandbox_port")

        if ! sandbox_port2=$(pick_port "$sandbox_port"); then
            echo "Error: could not find a second free port in 49200-49300 on the host." >&2
            exit 1
        fi
        port_args+=(-p "${sandbox_port2}:${sandbox_port2}")
        env_args+=(-e "SANDBOX_HOST_PORT_2=$sandbox_port2")

        # Build the effective network list: dev-net (default) + any user --network entries.
        # docker run only accepts one --network, so the first one goes there
        # and any others are attached after the container starts.
        local -a all_networks=()
        if $use_devnet; then
            # Auto-create dev-net if missing. Idempotent.
            docker network inspect dev-net &>/dev/null \
                || docker network create dev-net >/dev/null
            all_networks+=("dev-net")
        fi
        all_networks+=("${extra_networks[@]+"${extra_networks[@]}"}")

        if [[ ${#all_networks[@]} -gt 0 ]]; then
            net_args=(--network="${all_networks[0]}")
        fi
    fi

    # Append any user-specified explicit port forwards.
    port_args+=("${extra_ports[@]+"${extra_ports[@]}"}")

    # --- Stable, distinct hostname ---
    # Without --hostname a container reports a random short ID, which the
    # infra-lessons skill would turn into a new lessons-scratch-<hostname>.md on
    # every recreation. Use the sandbox name so the scratch file is stable and
    # identifiable. Container names allow '_' and '.', which are not valid in a
    # hostname, so map anything outside [a-z0-9-] to '-', collapse repeats, trim
    # leading/trailing '-' and cap at the 63-char DNS label limit.
    local sandbox_hostname
    sandbox_hostname=$(printf '%s' "$container_name" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-63 | LC_ALL=C sed -E 's/-+$//')
    [[ -z "$sandbox_hostname" ]] && sandbox_hostname="sandbox"

    echo "Starting sandbox '$container_name'..."
    echo "  Project: $project_dir (mounted at the same path in the container)"
    echo "  Agent: $agent_choice"
    $mount_config && echo "  Agent configs: named volumes (isolated)"
    if $host_network; then
        echo "  Network: host (firewall disabled)"
    else
        echo "  Network: ${all_networks[*]:-bridge} (firewall on, egress allowlisted)"
        echo "  Host-visible ports: http://localhost:$sandbox_port (\$SANDBOX_HOST_PORT), http://localhost:$sandbox_port2 (\$SANDBOX_HOST_PORT_2)"
    fi
    if [[ "$allow_sudo" == "1" ]]; then
        echo "  Sudo: passwordless (--allow-sudo; agent can also flush the firewall)"
    else
        echo "  Sudo: strict (no general root for the agent; grant for one session with: agent-sandbox sudo $container_name on)"
    fi
    [[ -n "$dhis2_broker_active" ]] && echo "  DHIS2 broker: $dhis2_broker_active (agent-scoped token)"
    [[ -n "$adb_active" ]] && echo "  Android adb: $adb_active"
    echo "  Hostname: $sandbox_hostname"
    [[ -n "$lessons_active" ]] && echo "  Lessons: $lessons_active -> /mnt/lessons (read-write)"
    [[ -n "$host_claude_md_active" ]] && echo "  CLAUDE.md addendum: $host_claude_md_active (read-only)"

    docker run -dit \
        --name "$container_name" \
        --hostname "$sandbox_hostname" \
        --label "agentic-sandbox=true" \
        --label "agentic-sandbox-agent=$agent_choice" \
        --label "agentic-sandbox-project=$project_dir" \
        "${net_args[@]+"${net_args[@]}"}" \
        "${cap_args[@]+"${cap_args[@]}"}" \
        "${port_args[@]+"${port_args[@]}"}" \
        --memory=8g \
        --cpus=4 \
        --shm-size=1g \
        "${volumes[@]}" \
        ${env_args[@]+"${env_args[@]}"} \
        "${extra_envs[@]+"${extra_envs[@]}"}" \
        "$IMAGE_NAME"

    # Attach any additional networks beyond the first.
    if ! $host_network && [[ ${#all_networks[@]} -gt 1 ]]; then
        for net in "${all_networks[@]:1}"; do
            docker network connect "$net" "$container_name"
            echo "  Attached additional network: $net"
        done
    fi

    # Wait for the firewall before anything attaches. This deliberately comes
    # after the extra-network attach above: init-firewall.sh reads `ip route`
    # to allow every attached bridge subnet, so blocking earlier would give it
    # less chance to see those networks, not more.
    wait_for_firewall "$container_name"

    # Wait for the chosen agent to be installed. The entrypoint installs
    # whichever agent matches AGENT_CHOICE; we wait for its binary on PATH.
    local check_bin
    case "$agent_choice" in
        claude|all) check_bin="claude" ;;
        copilot)    check_bin="copilot" ;;
        vibe)       check_bin="vibe" ;;
        *)          check_bin="claude" ;;
    esac
    echo -n "Installing agent ($agent_choice)..."
    local max_wait=300
    local waited=0
    local installed=false
    while [[ $waited -lt $max_wait ]]; do
        if docker exec "$container_name" bash -l -c "command -v $check_bin" &>/dev/null; then
            installed=true
            break
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    if $installed; then
        echo " done."
    else
        echo " timeout."
        echo "Install may still be running. Check with:"
        echo "  docker logs $container_name"
        echo "  docker exec $container_name ls /home/agent/.local/bin"
    fi

    # Auto-sync host skills into the sandbox if it's a claude-capable one and
    # the container's skills dir is empty. The agentic-sandbox-claude volume
    # is shared across all claude sandboxes, so this naturally only runs once
    # per machine — subsequent claude sandboxes inherit skills from the
    # already-populated volume.
    if [[ "$agent_choice" == "claude" || "$agent_choice" == "all" ]] \
            && [[ -d "$HOME/.claude/skills" ]] \
            && $installed; then
        local container_skill_count
        container_skill_count=$(docker exec "$container_name" sh -c \
            'find /home/agent/.claude/skills -mindepth 1 -maxdepth 1 2>/dev/null | wc -l' \
            2>/dev/null | tr -d ' ')
        if [[ "$container_skill_count" == "0" ]]; then
            echo "Syncing host skills into sandbox..."
            cmd_sync_skills "$container_name" push >/dev/null 2>&1 || \
                echo "  (skill sync failed; run 'agent-sandbox sync-skills push' manually)"
        fi
    fi

    echo ""
    echo "Sandbox ready. Attach with:"
    echo "  agent-sandbox shell $container_name"
}

cmd_shell() {
    local container_name="${1:-agentic-sandbox}"
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: container '$container_name' is not running"
        echo "Running containers:"
        docker ps --filter "ancestor=$IMAGE_NAME" --format "  {{.Names}}  ({{.Status}})"
        exit 1
    fi
    # Prefer the full-path mount (PROJECT_DIR); fall back to the legacy
    # /<basename> mount for containers created before PROJECT_DIR existed.
    local workdir
    workdir=$(docker exec "$container_name" printenv PROJECT_DIR 2>/dev/null || true)
    if [[ -z "$workdir" ]]; then
        local project_name
        project_name=$(docker exec "$container_name" printenv PROJECT_NAME 2>/dev/null || true)
        [[ -n "$project_name" ]] && workdir="/$project_name"
    fi
    if [[ -n "$workdir" ]]; then
        docker exec -it -w "$workdir" "$container_name" /bin/bash -l
    else
        docker exec -it "$container_name" /bin/bash -l
    fi
}

cmd_stop() {
    local container_name="${1:-agentic-sandbox}"
    echo "Stopping '$container_name'..."
    docker stop "$container_name" >/dev/null
    echo "Done. (Container preserved — use 'start' to resume, or 'remove' to delete.)"
}

cmd_remove() {
    local container_name="${1:-}"
    if [[ -z "$container_name" ]]; then
        echo "Error: container name required"
        echo "Usage: agent-sandbox remove <container-name>"
        exit 1
    fi
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: container '$container_name' does not exist"
        exit 1
    fi
    echo "Removing '$container_name'..."
    docker rm -f "$container_name" &>/dev/null
    echo "Done. (Named volumes preserved — use 'reset-config' to wipe them.)"
}

# Flip the agent's general sudo in a RUNNING sandbox, from the host. The change
# is deliberately temporary: sandbox-privileged-boot.sh re-applies the mode the
# container was created with on every `docker start`, so a grant lasts until the
# next restart and strict remains the resting state. Sticky would need a second
# source of truth for a security setting, on a filesystem the agent can write.
cmd_sudo() {
    local container_name="${1:-}" action="${2:-}"
    if [[ -z "$container_name" ]]; then
        echo "Error: container name required"
        echo "Usage: agent-sandbox sudo <container> [on|off]"
        exit 1
    fi
    case "$action" in
        ""|on|off) ;;
        *) echo "Error: expected 'on' or 'off', got '$action'"; exit 1 ;;
    esac
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: container '$container_name' does not exist"
        exit 1
    fi
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: '$container_name' is not running. Start it first — a start re-applies"
        echo "  the mode it was created with, so grant sudo after it is up."
        exit 1
    fi

    # "Created as" comes from PID 1's environment, which is what the boot script
    # re-applies on restart. Containers from before strict became the default
    # run the old boot script (image content is fixed at creation), for which
    # an absent variable meant passwordless — probe for that so the answer is
    # about the container in front of us, not the current launcher.
    local created="strict" env_dump
    env_dump=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name")
    if grep -qx 'SANDBOX_ALLOW_SUDO=1' <<<"$env_dump"; then
        created="passwordless (--allow-sudo)"
    elif ! docker exec "$container_name" grep -q SANDBOX_ALLOW_SUDO \
            /usr/local/bin/sandbox-privileged-boot.sh 2>/dev/null \
         && ! grep -qx 'SANDBOX_STRICT_SUDO=1' <<<"$env_dump"; then
        created="passwordless (pre-dates the strict default; recreate to get strict)"
    fi
    local sudoers="/etc/sudoers.d/$AGENT_USER"
    local current="strict"
    if docker exec -u root "$container_name" test -f "$sudoers"; then
        current="passwordless"
    fi

    if [[ -z "$action" ]]; then
        echo "Sudo in '$container_name': $current now; created as $created."
        return
    fi

    # Runs as root inside the container. The value and paths are passed as
    # positional arguments rather than interpolated into the script, and
    # /etc/sandbox-info is rewritten so the agent's own check stays truthful.
    docker exec -u root "$container_name" sh -c '
        user="$1"; sudoers="$2"; allow="$3"; info=/etc/sandbox-info
        if [ "$allow" = 1 ]; then
            echo "$user ALL=(ALL) NOPASSWD:ALL" > "$sudoers" && chmod 0440 "$sudoers"
        else
            rm -f "$sudoers"
        fi
        { [ -f "$info" ] && grep -v "^SANDBOX_ALLOW_SUDO=" "$info"; echo "SANDBOX_ALLOW_SUDO=$allow"; } > "$info.tmp" \
            && mv "$info.tmp" "$info" && chmod 0644 "$info"
    ' _ "$AGENT_USER" "$sudoers" "$([[ "$action" == on ]] && echo 1 || echo 0)"

    if [[ "$action" == "on" ]]; then
        echo "Sudo granted in '$container_name' until its next restart (created as $created)."
        echo "  The agent can now also flush the egress firewall. Revoke with: agent-sandbox sudo $container_name off"
    else
        echo "Sudo revoked in '$container_name' (created as $created)."
        if [[ "$created" != strict ]]; then
            echo "  It comes back on the next restart; recreate without --allow-sudo to make strict permanent."
        fi
    fi
}

cmd_reset_config() {
    echo "This will delete all agent config volumes:"
    echo "  - ${VOLUME_PREFIX}-claude   (Claude Code auth, settings, skills)"
    echo "  - ${VOLUME_PREFIX}-copilot  (Copilot config)"
    echo "  - ${VOLUME_PREFIX}-vibe     (Vibe config)"
    echo "  - ${VOLUME_PREFIX}-gh       (GitHub CLI auth)"
    echo ""
    echo "Any running sandboxes will be stopped first."
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return
    fi

    # Stop any running sandboxes
    local running
    running=$(docker ps --filter "label=agentic-sandbox=true" -q)
    if [[ -n "$running" ]]; then
        echo "Stopping running sandboxes..."
        docker rm -f $running &>/dev/null
    fi

    for vol in claude copilot vibe gh; do
        docker volume rm "${VOLUME_PREFIX}-${vol}" 2>/dev/null \
            && echo "  Removed ${VOLUME_PREFIX}-${vol}" \
            || echo "  ${VOLUME_PREFIX}-${vol} (not present)"
    done
    echo "Done."
}

cmd_list() {
    echo "Sandboxes:"
    docker ps -a --filter "label=agentic-sandbox=true" --format "  {{.Names}}\t{{.Status}}"
    local count
    count=$(docker ps -a --filter "label=agentic-sandbox=true" -q | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        echo "  (none)"
    fi
}

cmd_extend() {
    local custom_dockerfile="${1:-}"
    if [[ -z "$custom_dockerfile" || ! -f "$custom_dockerfile" ]]; then
        echo "Error: provide a valid Dockerfile path"
        echo "The Dockerfile should start with: FROM agentic-sandbox:latest"
        exit 1
    fi

    ensure_image

    local custom_name
    custom_name="agentic-sandbox-custom:$(basename "$custom_dockerfile" .Dockerfile | tr '.' '-')"

    echo "Building extended image '$custom_name' from $custom_dockerfile..."
    docker build -t "$custom_name" -f "$custom_dockerfile" "$(dirname "$custom_dockerfile")"
    echo ""
    echo "Done. Use it with:"
    echo "  docker run -dit --name my-sandbox -v /path/to/project:/workspace $custom_name"
}

cmd_sync_skills() {
    local direction=""
    local container_name=""
    local container_skills_dir="/home/agent/.claude/skills"
    local host_skills_dir="$HOME/.claude/skills"

    # Parse args: optional container name and optional direction (push/pull)
    for arg in "$@"; do
        case "$arg" in
            push|pull) direction="$arg" ;;
            *) container_name="$arg" ;;
        esac
    done

    # Auto-detect a running sandbox if none specified
    if [[ -z "$container_name" ]]; then
        container_name=$(docker ps --filter "label=agentic-sandbox=true" --format '{{.Names}}' | head -1)
        if [[ -z "$container_name" ]]; then
            echo "Error: no running sandbox found"
            exit 1
        fi
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Error: container '$container_name' is not running"
        exit 1
    fi

    # Ensure container skills dir exists
    docker exec "$container_name" mkdir -p "$container_skills_dir"

    if [[ "$direction" == "push" ]]; then
        _sync_push "$container_name" "$container_skills_dir" "$host_skills_dir"
        return
    elif [[ "$direction" == "pull" ]]; then
        _sync_pull "$container_name" "$container_skills_dir" "$host_skills_dir"
        return
    fi

    # Default: show status and offer both directions
    local host_list container_list
    host_list=$(_list_host_skills "$host_skills_dir")
    container_list=$(docker exec "$container_name" find "$container_skills_dir" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort || true)
    # Hide container skills that exist on host but aren't syncable (e.g. a
    # stray real directory) — they'd otherwise nag as "pull to sync" forever.
    if [[ -n "$container_list" ]]; then
        container_list=$(while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            if [[ -e "$host_skills_dir/$s" || -L "$host_skills_dir/$s" ]] \
                    && ! _skill_syncable "$host_skills_dir" "$s"; then
                continue
            fi
            echo "$s"
        done <<< "$container_list")
    fi

    local only_host only_container both
    only_host=$(comm -23 <(echo "$host_list") <(echo "$container_list") | grep -v '^$' || true)
    only_container=$(comm -13 <(echo "$host_list") <(echo "$container_list") | grep -v '^$' || true)
    both=$(comm -12 <(echo "$host_list") <(echo "$container_list") | grep -v '^$' || true)

    local any_diff=false

    if [[ -n "$only_host" ]]; then
        any_diff=true
        echo "Skills only on host (push to sync):"
        while IFS= read -r s; do echo "  + $s"; done <<< "$only_host"
    fi

    if [[ -n "$only_container" ]]; then
        any_diff=true
        echo "Skills only in container (pull to sync):"
        while IFS= read -r s; do echo "  + $s"; done <<< "$only_container"
    fi

    if [[ -n "$both" ]]; then
        echo "Skills in both: $(echo "$both" | wc -l | tr -d ' ')"
    fi

    if ! $any_diff; then
        echo "Skills are in sync ($(echo "$both" | wc -l | tr -d ' ') skills)."
        return
    fi

    echo ""
    echo "Options: [p]ush host→container, pu[l]l container→host, [b]oth, [s]kip"
    read -rp "Choice: " choice
    case "$choice" in
        p|P) _sync_push "$container_name" "$container_skills_dir" "$host_skills_dir" ;;
        l|L) _sync_pull "$container_name" "$container_skills_dir" "$host_skills_dir" ;;
        b|B)
            _sync_push "$container_name" "$container_skills_dir" "$host_skills_dir"
            _sync_pull "$container_name" "$container_skills_dir" "$host_skills_dir"
            ;;
        *) echo "Skipped." ;;
    esac
}

# Only symlinked skills sync into sandboxes. The ai-skills manager
# (~/Repos/AI/ai-skills/ai-skills-sync/manage.py) enables a skill by symlinking it into
# ~/.claude/skills, so a symlink means "deliberately enabled" — that includes
# direct symlinks to other repos (dhis2-instances, dhis2-android-testing).
#
# Real (non-symlink) directories are NOT synced. On the host these are
# plugin-materialized skills (e.g. the superpowers set) or strays; sandboxes
# get plugin skills natively instead — the entrypoint installs the same
# plugins via `claude plugin install` from the marketplace — so copying the
# materialized dirs would just duplicate them. See entrypoint.sh.
_skill_syncable() {
    local dir="$1" name="$2"
    [[ -L "$dir/$name" ]]
}

# List syncable skill names on host (skips hidden files and non-syncable dirs)
_list_host_skills() {
    local dir="$1"
    [[ -d "$dir" ]] || return
    for entry in "$dir"/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        local name
        name="$(basename "$entry")"
        [[ "$name" == .* ]] && continue
        _skill_syncable "$dir" "$name" || continue
        echo "$name"
    done | sort
}

# Push host skills → container (resolves symlinks via temp dir)
_sync_push() {
    local container_name="$1" container_dir="$2" host_dir="$3"
    [[ -d "$host_dir" ]] || { echo "No host skills directory."; return; }

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    local count=0
    for entry in "$host_dir"/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        local name
        name="$(basename "$entry")"
        [[ "$name" == .* ]] && continue
        _skill_syncable "$host_dir" "$name" || continue
        # cp -rL dereferences symlinks and copies content
        cp -rL "$entry" "$tmpdir/$name"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "No host skills to push."
        return
    fi

    docker cp "$tmpdir/." "$container_name:$container_dir/"
    # Fix ownership (needs sudo since container runs as non-root)
    docker exec -u root "$container_name" chown -R agent:agent "$container_dir"
    echo "Pushed $count skills to container."
}

# Pull container skills → host
_sync_pull() {
    local container_name="$1" container_dir="$2" host_dir="$3"
    mkdir -p "$host_dir"

    local skills
    skills=$(docker exec "$container_name" find "$container_dir" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null || true)

    local count=0
    while IFS= read -r skill; do
        [[ -z "$skill" || "$skill" == .* ]] && continue
        # Skip if host already has this skill (as file, dir, or symlink)
        [[ -e "$host_dir/$skill" || -L "$host_dir/$skill" ]] && continue
        docker cp "$container_name:$container_dir/$skill" "$host_dir/$skill"
        count=$((count + 1))
    done <<< "$skills"

    if [[ $count -eq 0 ]]; then
        echo "No new container skills to pull."
    else
        echo "Pulled $count new skills to host."
    fi
}

# Main dispatch
# Dispatch from a function, with `exit` on the same line as the call. Bash
# reads a script as it runs it, so editing this file while a command runs from
# it (e.g. a long `build`) would otherwise make bash resume at a stale offset
# in the new text once the command returns.
main() {
    case "${1:-}" in
        start)       shift; cmd_start "$@" ;;
        shell)       shift; cmd_shell "$@" ;;
        stop)        shift; cmd_stop "$@" ;;
        remove|rm)   shift; cmd_remove "$@" ;;
        sudo)        shift; cmd_sudo "$@" ;;
        reset-config) shift; cmd_reset_config "$@" ;;
        list)        shift; cmd_list "$@" ;;
        build)       shift; cmd_build "$@" ;;
        extend)      shift; cmd_extend "$@" ;;
        sync-skills) shift; cmd_sync_skills "$@" ;;
        -h|--help|help|"") usage ;;
        *) echo "Unknown command: $1"; usage; exit 1 ;;
    esac
}

main "$@"; exit
