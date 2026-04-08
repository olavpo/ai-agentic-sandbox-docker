#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE_NAME="agentic-sandbox:latest"
VOLUME_PREFIX="agentic-sandbox"

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
  list                   List running sandboxes
  build                  Rebuild the sandbox image
  extend <dockerfile>    Build a custom image extending the base sandbox
  sync-skills [container] [push|pull]  Sync skills between host and container

Options:
  -n, --name NAME        Container name (default: agentic-sandbox)
  -e, --env KEY=VAL      Pass extra environment variable (repeatable)
  --no-config            Don't mount agent config directories

Examples:
  agent-sandbox start ~/projects/my-app
  agent-sandbox start ~/projects/my-app -n my-sandbox -e MY_VAR=hello
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

ensure_image() {
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "Building sandbox image..."
        docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    fi
}

cmd_build() {
    echo "Building sandbox image..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
}

cmd_start() {
    local project_dir=""
    local container_name="agentic-sandbox"
    local extra_envs=()
    local mount_config=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) container_name="$2"; shift 2 ;;
            -e|--env) extra_envs+=(-e "$2"); shift 2 ;;
            --no-config) mount_config=false; shift ;;
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

    project_dir="$(cd "$project_dir" && pwd)"

    if ! [[ -d "$project_dir" ]]; then
        echo "Error: $project_dir is not a directory"
        exit 1
    fi

    ensure_image

    # Stop existing container with same name if running
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Removing existing container '$container_name'..."
        docker rm -f "$container_name" &>/dev/null
    fi

    local project_name
    project_name="$(basename "$project_dir")"
    local volumes=(-v "$project_dir:/$project_name")

    if $mount_config; then
        # Named volumes for isolated, persistent agent config
        volumes+=(
            -v "${VOLUME_PREFIX}-claude:/home/agent/.claude"
            -v "${VOLUME_PREFIX}-copilot:/home/agent/.copilot"
            -v "${VOLUME_PREFIX}-vibe:/home/agent/.vibe"
            -v "${VOLUME_PREFIX}-gh:/home/agent/.config/gh"
        )

    fi

    # Pass through API keys if set on host
    local env_args=(-e "PROJECT_NAME=$project_name" -e "SSH_AUTH_SOCK=")
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [[ -n "${OPENAI_API_KEY:-}" ]]    && env_args+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
    [[ -n "${MISTRAL_API_KEY:-}" ]]   && env_args+=(-e "MISTRAL_API_KEY=$MISTRAL_API_KEY")
    local gh_token="${SANDBOX_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ -n "$gh_token" ]] && env_args+=(-e "GITHUB_TOKEN=$gh_token")

    echo "Starting sandbox '$container_name'..."
    echo "  Project: $project_dir → /$project_name"
    $mount_config && echo "  Agent configs: named volumes (isolated)"

    docker run -dit \
        --name "$container_name" \
        --label "agentic-sandbox=true" \
        --network=host \
        --memory=8g \
        --cpus=4 \
        "${volumes[@]}" \
        ${env_args[@]+"${env_args[@]}"} \
        "${extra_envs[@]+"${extra_envs[@]}"}" \
        "$IMAGE_NAME"

    # Wait for agents to be installed
    echo -n "Installing agents..."
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if docker exec "$container_name" bash -l -c "command -v claude" &>/dev/null; then
            break
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    echo " done."

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
    local project_name
    project_name=$(docker exec "$container_name" printenv PROJECT_NAME 2>/dev/null || true)
    if [[ -n "$project_name" ]]; then
        docker exec -it -w "/$project_name" "$container_name" /bin/bash -l
    else
        docker exec -it "$container_name" /bin/bash -l
    fi
}

cmd_stop() {
    local container_name="${1:-agentic-sandbox}"
    echo "Stopping '$container_name'..."
    docker stop "$container_name" && docker rm "$container_name"
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

# List skill names on host (resolves symlinks, skips hidden files)
_list_host_skills() {
    local dir="$1"
    [[ -d "$dir" ]] || return
    for entry in "$dir"/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        local name
        name="$(basename "$entry")"
        [[ "$name" == .* ]] && continue
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
case "${1:-}" in
    start)       shift; cmd_start "$@" ;;
    shell)       shift; cmd_shell "$@" ;;
    stop)        shift; cmd_stop "$@" ;;
    list)        shift; cmd_list "$@" ;;
    build)       shift; cmd_build "$@" ;;
    extend)      shift; cmd_extend "$@" ;;
    sync-skills) shift; cmd_sync_skills "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "Unknown command: $1"; usage; exit 1 ;;
esac
