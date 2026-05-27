#!/usr/bin/env bash
# sandboxed.sh — convenience launcher for agent-specific sandboxes.
#
# Invoked via one of these symlinks (the script picks behavior from $0):
#   /usr/local/bin/claude-sandboxed -> .../sandboxed.sh
#   /usr/local/bin/vibe-sandboxed   -> .../sandboxed.sh
#
# Usage:
#   <name>-sandboxed                     # list existing sandboxes for this agent
#   <name>-sandboxed -n NAME             # create-or-resume sandbox; launch agent inside
#
# For new sandboxes the current directory is used as the project mount.

set -euo pipefail

invoked_as="$(basename "$0")"

case "$invoked_as" in
    claude-sandboxed)
        AGENT="claude"
        PREFIX="claude-"
        # Use full path so we don't depend on shell alias expansion under
        # `bash -lc`. The image's user has an alias for this; the path here
        # is explicit for non-interactive exec.
        EXEC_CMD="/home/agent/.local/bin/claude --dangerously-skip-permissions"
        EXTRA_ARGS=()
        ;;
    vibe-sandboxed)
        AGENT="vibe"
        PREFIX="vibe-"
        EXEC_CMD="/home/agent/.local/bin/vibe"
        # Vibe sandboxes don't need dev-net by default.
        EXTRA_ARGS=(--no-dev-net)
        ;;
    *)
        echo "Error: this script must be invoked via claude-sandboxed or vibe-sandboxed symlink, not as $invoked_as." >&2
        exit 1
        ;;
esac

usage() {
    cat <<USAGE
Usage:
  $invoked_as              # list existing $AGENT sandboxes
  $invoked_as -n NAME      # create-or-resume "${PREFIX}NAME" and launch $AGENT

For new sandboxes the current directory ($(pwd)) is mounted as the project.
USAGE
}

name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name) name="${2:?--name requires a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            # Allow `claude-sandboxed myname` as shorthand for `claude-sandboxed -n myname`
            if [[ -z "$name" ]]; then
                name="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

# No name → list mode.
if [[ -z "$name" ]]; then
    echo "Existing $AGENT sandboxes:"
    docker ps -a \
        --filter "label=agentic-sandbox-agent=$AGENT" \
        --format "  {{.Names}}\t{{.Status}}"
    count=$(docker ps -a --filter "label=agentic-sandbox-agent=$AGENT" -q | wc -l | tr -d ' ')
    [[ "$count" -eq 0 ]] && echo "  (none)"
    exit 0
fi

container="${PREFIX}${name}"

# Helper: attach to a running container and launch the agent in the project dir.
exec_into_container() {
    local proj
    proj=$(docker exec "$container" printenv PROJECT_NAME 2>/dev/null || true)
    local -a workdir=()
    [[ -n "$proj" ]] && workdir=(-w "/$proj")
    exec docker exec -it ${workdir[@]+"${workdir[@]}"} "$container" /bin/bash -lc "exec $EXEC_CMD"
}

# Case 1: already running → exec straight in.
if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "Resuming running sandbox '$container' and launching $AGENT..."
    exec_into_container
fi

# Case 2: exists but stopped → start and exec in.
if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    echo "Starting stopped sandbox '$container' and launching $AGENT..."
    docker start "$container" >/dev/null
    exec_into_container
fi

# Case 3: doesn't exist → create using cwd, then exec in.
echo "Creating new $AGENT sandbox '$container' with $(pwd) as the project..."
agent-sandbox start "$(pwd)" -n "$container" --agent "$AGENT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
exec_into_container
