#!/bin/bash
# init-firewall.sh — egress firewall for the agentic sandbox.
#
# Adapted from anthropics/claude-code/.devcontainer/init-firewall.sh.
# Extensions over the original:
#   - Wider domain allowlist (npm/pypi/dhis2/etc., not just claude essentials)
#   - Allows traffic to all attached Docker bridge networks (so the sandbox
#     can talk to DHIS2/dev containers on a shared user-defined network like
#     `dev-net` without the firewall getting in the way).
#   - Verification step checks both an allowed and a denied target.
#
# Runs inside the container at startup (invoked by entrypoint.sh).
# Requires NET_ADMIN and NET_RAW capabilities on the container.

set -euo pipefail
IFS=$'\n\t'

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

# --- GitHub IP ranges (dynamic) ---
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

# --- Allowlisted domains, resolved to IPs ---
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

    # Node / npm
    "registry.npmjs.org"
    "registry.yarnpkg.com"

    # Python / pypi
    "pypi.org"
    "files.pythonhosted.org"

    # Playwright (chromium download CDN, used on first install)
    "playwright.azureedge.net"
    "cdn.playwright.dev"

    # apt / Debian / Node binary distribution
    "deb.nodesource.com"
    "deb.debian.org"
    "security.debian.org"

    # VS Code marketplace (devcontainer use)
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"

    # DHIS2
    "dhis2.org"
    "www.dhis2.org"
    "docs.dhis2.org"
    "api.dhis2.org"
    "play.dhis2.org"
)

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
