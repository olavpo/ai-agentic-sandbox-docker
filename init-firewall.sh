#!/bin/bash
# init-firewall.sh — egress firewall for the agentic sandbox.
#
# Adapted from anthropics/claude-code/.devcontainer/init-firewall.sh.
# Extensions over the original:
#   - Wider domain allowlist (npm/pypi/dhis2/etc., not just claude essentials)
#   - Allows traffic to all attached Docker bridge networks (so the sandbox
#     can talk to DHIS2/dev containers on a shared user-defined network like
#     `dev-net` without the firewall getting in the way).
#   - --refresh-only mode that re-resolves DOMAINS into the existing ipset
#     without touching iptables rules. Used by entrypoint.sh's background
#     refresh loop to keep up with CDN edge IP rotation (CloudFront, etc.).
#   - Verification step checks both an allowed and a denied target.
#
# Runs inside the container at startup (invoked by entrypoint.sh).
# Requires NET_ADMIN and NET_RAW capabilities on the container.

set -euo pipefail
IFS=$'\n\t'

# --- Mode ----------------------------------------------------------------
# Default (no args): full init. Flushes iptables and the ipset, reapplies
# the default-DROP egress policy and the allow-from-ipset rule, populates
# the ipset, and verifies.
#
# --refresh-only: only re-resolves DOMAINS (and re-fetches GitHub IP ranges)
# into the existing ipset. Skips the iptables/ipset teardown so in-flight
# connections are not disrupted. Used by the background refresh loop in
# entrypoint.sh.
REFRESH_ONLY=0
if [[ "${1:-}" == "--refresh-only" ]]; then
    REFRESH_ONLY=1
fi

# --- Allowed domains (resolved to IPs and added to the ipset) ------------
DOMAINS=(
    # Anthropic
    "api.anthropic.com"
    "console.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"

    # Claude Code installer + auto-updater
    "claude.ai"
    "downloads.claude.ai"

    # Mistral (Vibe agent)
    "api.mistral.ai"

    # Node / npm
    "registry.npmjs.org"
    "registry.yarnpkg.com"

    # Python / pypi
    "pypi.org"
    "files.pythonhosted.org"

    # Playwright (chromium download CDN, used on first install)
    "playwright.azureedge.net"
    "cdn.playwright.dev"

    # apt / Node binary distribution.
    # Base image is ubuntu:24.04: arm64 builds pull from ports.ubuntu.com,
    # amd64 from archive/security.ubuntu.com. deb.debian.org stays for any
    # Debian-sourced packages (e.g. some tool repos). Without the Ubuntu
    # mirrors, runtime `apt-get install` fails inside the sandbox.
    "deb.nodesource.com"
    "deb.debian.org"
    "security.debian.org"
    "ports.ubuntu.com"
    "archive.ubuntu.com"
    "security.ubuntu.com"

    # VS Code marketplace (devcontainer use)
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"

    # DHIS2
    "dhis2.org"
    "www.dhis2.org"
    "docs.dhis2.org"
    "play.dhis2.org"
    "play.im.dhis2.org"
    "implement.im.dhis2.org"
    "research.im.dhis2.org"

    # DuckDB extension repositories
    "extensions.duckdb.org"
    "community-extensions.duckdb.org"
    "nightly-extensions.duckdb.org"
)

# --- Resolve all source-of-truth hosts into the ipset --------------------
# Idempotent: re-running only adds new IPs (existing entries are silently
# ignored). Used both by the initial full-init below and by --refresh-only.
populate_allowed_ips() {
    # GitHub IP ranges (dynamic)
    echo "Fetching GitHub IP ranges..."
    gh_ranges=$(curl -s --max-time 10 https://api.github.com/meta || true)
    if [ -z "$gh_ranges" ] || ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
        echo "WARNING: Failed to fetch GitHub IP ranges; GitHub will not be reachable from the sandbox."
    else
        echo "Processing GitHub IPs..."
        while read -r cidr; do
            [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] || continue
            ipset add allowed-domains "$cidr" 2>/dev/null || true
        done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
    fi

    # Allowlisted domains, resolved to IPs
    for domain in "${DOMAINS[@]}"; do
        echo "Resolving $domain..."
        ips=$(dig +noall +answer +time=5 +tries=2 A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            echo "  WARNING: Failed to resolve $domain (skipping)"
            continue
        fi
        while read -r ip; do
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
            ipset add allowed-domains "$ip" 2>/dev/null || true
        done < <(echo "$ips")
    done
}

# --- Refresh-only path ---------------------------------------------------
if [[ $REFRESH_ONLY -eq 1 ]]; then
    populate_allowed_ips
    exit 0
fi

# === Full init below =====================================================

# 1. Preserve internal Docker DNS rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

# Flush existing rules and ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS rules
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow DNS and localhost loopback outbound (INPUT is permissive — see below).
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create the ipset that will hold all allowed CIDRs
ipset create allowed-domains hash:net

# Populate the ipset (GitHub IP ranges + resolved DOMAINS)
populate_allowed_ips

# --- Allow ALL attached Docker bridge network subnets ---
# The container may be attached to multiple Docker networks (default bridge,
# plus user-defined networks like dev-net). Each shows up in `ip route` as a
# directly-attached subnet.
#
# We need *both* directions:
#   - Outbound (egress): added to the allowed-domains ipset so the sandbox
#     can talk to sibling containers (e.g. http://dhis2:8080).
#   - Inbound (ingress): explicit ACCEPT rule so host -> container port
#     forwarding works (the host's docker-proxy sends packets in from the
#     bridge gateway, which would otherwise be dropped by the default DROP
#     INPUT policy).
echo "Allowing attached Docker networks (outbound)..."
while read -r subnet; do
    # Skip the host loopback range and link-local
    [[ "$subnet" == "127.0.0.0/8" ]] && continue
    [[ "$subnet" == "169.254.0.0/16" ]] && continue
    echo "  Adding subnet $subnet"
    ipset add allowed-domains "$subnet" 2>/dev/null || true
done < <(ip route | awk '/proto kernel/ && /src/ {print $1}')

# Default policies.
#
# OUTPUT default DROP — this is the whole point of the firewall: prevent
# the agent from exfiltrating to arbitrary hosts on the internet.
#
# INPUT default ACCEPT — for a personal dev sandbox, inbound filtering adds
# essentially zero security (we trust the host and the local Docker network)
# and breaks the common case of the user wanting to reach a published
# container port from their host browser (Docker Desktop's port-proxy
# sources packets from an interface that's hard to predict, so source-IP
# allowlisting doesn't reliably let the traffic through). The value of the
# firewall is OUTPUT.
iptables -P INPUT  ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established/related on OUTPUT (return traffic on allowed connections)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound to any IP in the allowed-domains ipset
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# --- Pinpoint sandbox→host exemptions ---
# The host itself is not on the allowlist; the only sanctioned channels are
# single host:port exemptions for specific services the sandbox is meant to
# reach (the DHIS2 instance broker, the adb server for the Android emulator).
# agent-sandbox.sh passes the relevant env vars into the container and
# entrypoint.sh forwards them to this script.
allow_host_port() {
    local label="$1" host="$2" port="$3"
    local ips
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        ips="$host"
    else
        # host.docker.internal is served by Docker's embedded DNS
        # (127.0.0.11 in /etc/resolv.conf), so dig resolves it; getent
        # covers /etc/hosts-based setups.
        ips=$(dig +noall +answer +time=5 +tries=2 A "$host" 2>/dev/null | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            ips=$(getent hosts "$host" | awk '{print $1}')
        fi
    fi
    if [ -z "$ips" ]; then
        echo "WARNING: could not resolve $label host '$host'; it will not be reachable."
        return
    fi
    while read -r ip; do
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
        echo "Allowing $label at $ip:$port"
        iptables -A OUTPUT -d "$ip" -p tcp --dport "$port" -j ACCEPT
    done < <(echo "$ips")
}

# DHIS2 instance broker (d2-broker on the host): lets the agent manage
# disposable DHIS2 test instances while everything else on the host stays
# unreachable.
if [[ -n "${DHIS2_BROKER_URL:-}" ]]; then
    broker_hostport="${DHIS2_BROKER_URL#*://}"
    broker_hostport="${broker_hostport%%/*}"
    broker_host="${broker_hostport%%:*}"
    broker_port="${broker_hostport##*:}"
    [[ "$broker_port" == "$broker_host" ]] && broker_port=80
    allow_host_port "DHIS2 broker" "$broker_host" "$broker_port"
fi

# adb server on the host (Android emulator testing, see android-testing.md).
# ADB_SERVER_SOCKET has the form tcp:host:port and is read natively by the
# in-container adb client.
if [[ -n "${ADB_SERVER_SOCKET:-}" ]]; then
    adb_hostport="${ADB_SERVER_SOCKET#tcp:}"
    adb_host="${adb_hostport%%:*}"
    adb_port="${adb_hostport##*:}"
    [[ "$adb_port" == "$adb_host" ]] && adb_port=5037
    allow_host_port "adb server" "$adb_host" "$adb_port"
fi

# Reject everything else explicitly so apps fail fast instead of hanging
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo ""
echo "Firewall rules applied. Verifying..."

# Verify: example.com should be UNREACHABLE
if curl --connect-timeout 5 -s -o /dev/null https://example.com 2>/dev/null; then
    echo "ERROR: Firewall verification failed — example.com was reachable."
    exit 1
fi
echo "  ✓ example.com is blocked (as expected)"

# Verify: api.anthropic.com should be REACHABLE (HTTP 4xx/5xx is fine; we just need TCP+TLS)
if ! curl --connect-timeout 5 -s -o /dev/null https://api.anthropic.com 2>/dev/null; then
    echo "ERROR: Firewall verification failed — api.anthropic.com was NOT reachable."
    exit 1
fi
echo "  ✓ api.anthropic.com is reachable (as expected)"

echo "Firewall ready."
