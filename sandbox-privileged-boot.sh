#!/bin/bash
# sandbox-privileged-boot.sh — the sandbox's only general root entry point.
#
# Runs as root via sudo (see /etc/sudoers.d/agent-boot). Two fixed modes:
#
#   boot     (default)  apply the sudo policy, publish /etc/sandbox-info,
#                       initialise the egress firewall
#   refresh             re-resolve the allowlist / self-heal the firewall
#
# WHY THIS EXISTS
#
# The privileged work a sandbox needs at boot is parameterised: the firewall
# opens single host:port channels named by DHIS2_BROKER_URL and
# ADB_SERVER_SOCKET. Passing those through `sudo env VAR=... init-firewall.sh`
# means the sudoers entry has to authorise `env`, which is indistinguishable
# from full root. Passing them as script arguments is no better: the agent may
# run this script whenever it likes, so an argument-driven version would let it
# punch its own hole in the firewall (`--broker-url=http://attacker:80`).
#
# So this script takes NO instructions from its caller. Everything it needs is
# read from /proc/1/environ — PID 1's environment is fixed by `docker run` when
# the container is created and cannot be altered from inside the container.
# argv selects one of the two fixed modes above and is otherwise ignored.
#
# Running this as the agent is therefore never an escalation: every path either
# re-applies the same restrictions or, in strict mode, removes the agent's own
# root. Keep it that way — do not add anything here that acts on caller input.
#
# Must stay root-owned and not agent-writable, or the sudoers entry pointing at
# it becomes a root escalation.

set -euo pipefail

# Matches USERNAME in the Dockerfile.
AGENT_USER=agent
SUDOERS_BLANKET="/etc/sudoers.d/$AGENT_USER"

MODE=boot
if [[ "${1:-}" == "refresh" ]]; then
    MODE=refresh
fi

log() { echo "[privileged-boot] $*"; }

# Read one variable from PID 1's environment. Entries are NUL-separated, and
# only the first match is used so a repeated name cannot be used to smuggle a
# second value past this. Names are literals from this script, never input.
pid1_env() {
    local name="$1"
    tr '\0' '\n' < /proc/1/environ | sed -n "s/^${name}=//p" | head -n 1
}

ALLOW_SUDO="$(pid1_env SANDBOX_ALLOW_SUDO)"
SKIP_FIREWALL="$(pid1_env SANDBOX_SKIP_FIREWALL)"
BROKER_URL="$(pid1_env DHIS2_BROKER_URL)"
ADB_SOCKET="$(pid1_env ADB_SERVER_SOCKET)"
HOST_PORT="$(pid1_env SANDBOX_HOST_PORT)"
HOST_PORT_2="$(pid1_env SANDBOX_HOST_PORT_2)"

# --- refresh mode --------------------------------------------------------
# The host:port env is re-supplied here too, not just at boot: init-firewall.sh
# self-heals by falling through to a full re-init when it finds the rules have
# been tampered with, and without these the broker/adb channels would silently
# disappear on the heal.
if [[ "$MODE" == "refresh" ]]; then
    exec env DHIS2_BROKER_URL="$BROKER_URL" ADB_SERVER_SOCKET="$ADB_SOCKET" \
        /usr/local/bin/init-firewall.sh --refresh-only
fi

# --- boot mode -----------------------------------------------------------

# 1. Sudo policy. Deliberately first: it is cheap and security-critical, so a
#    later firewall failure can never leave a strict sandbox with root intact.
#    Strict is the default; only SANDBOX_ALLOW_SUDO=1 in PID 1's environment
#    (set by the launcher's --allow-sudo) grants the agent general root. Either
#    way the file is written or removed rather than assumed: the container
#    filesystem persists across stop/start, and the host may have granted sudo
#    temporarily (`agent-sandbox sudo <c> on`) since the last boot. Re-applying
#    the created mode here is what makes that grant expire on restart.
if [[ "$ALLOW_SUDO" == "1" ]]; then
    echo "$AGENT_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_BLANKET"
    chmod 0440 "$SUDOERS_BLANKET"
    log "passwordless sudo — the agent has general root in this sandbox (--allow-sudo)."
else
    ALLOW_SUDO=0
    rm -f "$SUDOERS_BLANKET"
    log "strict sudo — the agent has no general root in this sandbox."
fi

# 2. Record this sandbox's own facts for tools — and agents — that need them.
# Written unconditionally, unlike the ports it used to hold alone: ~/.claude
# is shared between all sandboxes, so the brief there cannot state per-sandbox
# values. This file is container-local and therefore the authoritative answer
# to "what is true of THIS sandbox".
{
    echo "SANDBOX_ALLOW_SUDO=$ALLOW_SUDO"
    [[ -n "$HOST_PORT" ]] && echo "SANDBOX_HOST_PORT=$HOST_PORT"
    [[ -n "$HOST_PORT_2" ]] && echo "SANDBOX_HOST_PORT_2=$HOST_PORT_2"
} > /etc/sandbox-info
chmod 0644 /etc/sandbox-info

# 3. Egress firewall. Skipping is an explicit opt-in from the launcher
#    (`--host-network`); the sudo policy above still applies either way.
if [[ "$SKIP_FIREWALL" == "1" ]]; then
    log "SANDBOX_SKIP_FIREWALL=1 — not installing the egress firewall."
    exit 0
fi

exec env DHIS2_BROKER_URL="$BROKER_URL" ADB_SERVER_SOCKET="$ADB_SOCKET" \
    /usr/local/bin/init-firewall.sh
