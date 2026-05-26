#!/usr/bin/env bash
# agent-sandbox: wraps a command with sandbox-runtime (srt) using a resolved
# settings file. Default command is `claude`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")")" && pwd)"
BUNDLED_DEFAULT="$SCRIPT_DIR/settings/default.json"
PROFILES_DIR="$SCRIPT_DIR/settings"

usage() {
    cat <<'USAGE'
Usage: agent-sandbox [options] [COMMAND...]

Wraps COMMAND with sandbox-runtime using a resolved settings file.
With no COMMAND, launches `claude`.

Options:
  --settings PATH     Use a specific settings file (overrides resolution).
  --profile NAME      Use bundled profile <repo>/settings/NAME.json
                      (e.g. --profile strict).
  -h, --help          Show this help.

Subcommands (no settings resolution):
  init [--strict]     Copy default (or strict) profile to ./.srt-settings.json
  status              Print resolved settings path and final policy
  doctor              Check that `srt` is installed and bundled defaults exist

Settings resolution order (first match wins):
  1. --settings PATH
  2. --profile NAME  -> <repo>/settings/NAME.json
  3. ./.srt-settings.json
  4. ~/.srt-settings.json
  5. <repo>/settings/default.json (bundled)

Examples:
  agent-sandbox                          # launch claude with resolved settings
  agent-sandbox bash                     # wrap a shell instead
  agent-sandbox --profile strict         # strict allowlist
  agent-sandbox --settings ./mine.json   # explicit settings file
  agent-sandbox init                     # seed ./.srt-settings.json
  agent-sandbox status                   # show what's in effect here
USAGE
}

resolve_settings() {
    local explicit_settings="${1:-}"
    local profile="${2:-}"

    if [[ -n "$explicit_settings" ]]; then
        if [[ ! -f "$explicit_settings" ]]; then
            echo "Error: settings file not found: $explicit_settings" >&2
            exit 1
        fi
        echo "$explicit_settings"
        return
    fi

    if [[ -n "$profile" ]]; then
        local profile_path="$PROFILES_DIR/${profile}.json"
        if [[ ! -f "$profile_path" ]]; then
            echo "Error: profile '$profile' not found at $profile_path" >&2
            exit 1
        fi
        echo "$profile_path"
        return
    fi

    if [[ -f "./.srt-settings.json" ]]; then
        echo "$(pwd)/.srt-settings.json"
        return
    fi

    if [[ -f "$HOME/.srt-settings.json" ]]; then
        echo "$HOME/.srt-settings.json"
        return
    fi

    if [[ ! -f "$BUNDLED_DEFAULT" ]]; then
        echo "Error: bundled default settings missing at $BUNDLED_DEFAULT" >&2
        exit 1
    fi
    echo "$BUNDLED_DEFAULT"
}

# Build env-passthrough args. Reads passEnv from the resolved settings JSON.
# Always passes a known-safe baseline. Returns a list of NAME=VALUE pairs
# suitable for `env -i ... command`.
build_env_args() {
    local settings_file="$1"
    local -a env_args=()

    # Always-allowed baseline
    local var
    for var in HOME USER PATH SHELL TERM LANG TZ PWD OLDPWD; do
        if [[ -n "${!var:-}" ]]; then
            env_args+=("$var=${!var}")
        fi
    done
    # LC_* prefix
    for var in $(env | grep '^LC_' | cut -d= -f1); do
        env_args+=("$var=${!var}")
    done

    # Opt-in passthrough from settings.passEnv
    local pass_env
    if pass_env=$(jq -r '.passEnv[]?' "$settings_file" 2>/dev/null); then
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue

            # Special case: SANDBOX_GITHUB_TOKEN takes priority over GITHUB_TOKEN
            if [[ "$name" == "GITHUB_TOKEN" ]]; then
                local token="${SANDBOX_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
                if [[ -n "$token" ]]; then
                    env_args+=("GITHUB_TOKEN=$token")
                fi
                continue
            fi

            if [[ -n "${!name:-}" ]]; then
                env_args+=("$name=${!name}")
            fi
        done <<< "$pass_env"
    fi

    printf '%s\n' "${env_args[@]}"
}

# Inject the resolved settings file path into its own denyWrite list,
# write to a temp file, and return that temp file's path.
# This protects the policy from self-edit regardless of where it lives.
prepare_settings_file() {
    local source_file="$1"
    local resolved_abs
    resolved_abs="$(cd "$(dirname "$source_file")" && pwd)/$(basename "$source_file")"

    local tmp
    tmp=$(mktemp -t agent-sandbox-settings.XXXXXX.json)

    # Ensure denyWrite array exists and contains the resolved settings path
    jq --arg path "$resolved_abs" \
       '.denyWrite = ((.denyWrite // []) + [$path] | unique)' \
       "$source_file" > "$tmp"

    echo "$tmp"
}

require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed." >&2
        echo "Install with: brew install jq" >&2
        exit 1
    fi
}

require_srt() {
    if ! command -v srt &>/dev/null; then
        echo "Error: srt (sandbox-runtime) is not installed." >&2
        echo "Install with: npm install -g @anthropic-ai/sandbox-runtime" >&2
        exit 1
    fi
}

cmd_init() {
    local profile="default"
    if [[ "${1:-}" == "--strict" ]]; then
        profile="strict"
    fi
    local src="$PROFILES_DIR/${profile}.json"
    if [[ ! -f "$src" ]]; then
        echo "Error: bundled profile not found: $src" >&2
        exit 1
    fi
    if [[ -f "./.srt-settings.json" ]]; then
        echo "./.srt-settings.json already exists. Refusing to overwrite." >&2
        exit 1
    fi
    cp "$src" "./.srt-settings.json"
    echo "Created ./.srt-settings.json from $profile profile."
    echo "Edit to customize allowedDomains / allowRead / allowWrite for this project."
}

cmd_status() {
    require_jq
    local settings_file
    settings_file=$(resolve_settings "$@")
    echo "Resolved settings file: $settings_file"
    echo ""
    echo "--- Policy ---"
    jq . "$settings_file"
}

cmd_doctor() {
    local ok=true
    echo -n "srt installed: "
    if command -v srt &>/dev/null; then
        echo "yes ($(srt --version 2>/dev/null || echo 'version unknown'))"
    else
        echo "NO  -> npm install -g @anthropic-ai/sandbox-runtime"
        ok=false
    fi
    echo -n "jq installed: "
    if command -v jq &>/dev/null; then
        echo "yes"
    else
        echo "NO  -> brew install jq"
        ok=false
    fi
    echo -n "bundled default settings present: "
    if [[ -f "$BUNDLED_DEFAULT" ]]; then
        echo "yes ($BUNDLED_DEFAULT)"
    else
        echo "NO  -> $BUNDLED_DEFAULT missing"
        ok=false
    fi
    echo -n "claude installed: "
    if command -v claude &>/dev/null; then
        echo "yes ($(claude --version 2>/dev/null || echo 'version unknown'))"
    else
        echo "NO  -> install Claude Code (https://claude.ai/install.sh)"
    fi
    $ok && echo "" && echo "All required dependencies are present."
}

# --- Main dispatch ---

# Handle subcommands that don't go through srt
case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    init)
        shift
        cmd_init "$@"
        exit 0
        ;;
    status)
        shift
        cmd_status "$@"
        exit 0
        ;;
    doctor)
        shift
        cmd_doctor
        exit 0
        ;;
esac

# Parse --settings / --profile flags, leave remaining args as the command
explicit_settings=""
profile=""
declare -a cmd_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings)
            explicit_settings="$2"
            shift 2
            ;;
        --profile)
            profile="$2"
            shift 2
            ;;
        --)
            shift
            cmd_args=("$@")
            break
            ;;
        *)
            cmd_args+=("$1")
            shift
            ;;
    esac
done

# Default command is `claude`
if [[ ${#cmd_args[@]} -eq 0 ]]; then
    cmd_args=(claude)
fi

require_srt
require_jq

settings_file=$(resolve_settings "$explicit_settings" "$profile")
prepared_settings=$(prepare_settings_file "$settings_file")

# Clean up the temp settings file on exit
trap "rm -f '$prepared_settings'" EXIT

# Build the scrubbed env
declare -a env_pairs=()
while IFS= read -r pair; do
    [[ -n "$pair" ]] && env_pairs+=("$pair")
done < <(build_env_args "$prepared_settings")

# Hand off to srt with -i to clear env, then pass only the allowlisted vars
exec env -i "${env_pairs[@]}" srt --settings "$prepared_settings" "${cmd_args[@]}"
