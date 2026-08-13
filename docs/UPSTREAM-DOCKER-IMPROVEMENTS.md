# Suggested improvements for `olavpo/ai-agentic-sandbox` (Docker)

This repo is the Apple Container port of the Docker-based
[ai-agentic-sandbox](https://github.com/olavpo/ai-agentic-sandbox). A security
review of the port (2026-08-11/12) found four issues in the egress firewall.
All four are inherited from the Docker parent and still present there, so the
fixes below apply upstream largely unchanged.

Each was reproduced empirically in the Apple port; the Docker code paths are
cited by file and line from `main` at the time of review.

Ordered by severity.

---

## 1. Passwordless sudo makes the egress firewall unenforceable

**Where:** `Dockerfile:35`

```dockerfile
RUN echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
```

The firewall is the sandbox's primary security control, and the confined agent
can remove it in one command. Two independent routes, both verified:

```bash
sudo iptables -F OUTPUT      # flushes the REJECT rule -> unrestricted internet
sudo ipset add allowed-domains <ip>   # allowlist any single host on demand
```

After `iptables -F OUTPUT`, `curl https://example.com` and
`curl https://www.cloudflare.com` both returned 200. Setting the policy alone
(`-P OUTPUT ACCEPT`) is *not* sufficient — the explicit `-j REJECT` rule
survives — but flushing is equally available.

The Dockerfile already carries a narrower entry with a comment anticipating
this:

```dockerfile
# ... provides a deny-other-root path if the broader rule is later tightened.
RUN echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > ...
```

**Suggested fix:** drop the blanket rule and keep only the targeted one.

Note that a *curated* sudo allowlist does not work as a middle ground:
`sudo apt-get install` runs maintainer scripts as root, so any package-manager
entry is equivalent to full root. The realistic options are all-or-nothing.

**Consequences to plan for** (both hit us in the port):

- No runtime `apt-get` for the agent. Whatever the agent may need has to be in
  the image, which raises the value of the already-rich Docker base image.
- Privileged fixes move to the host: `docker exec -u root <container> ...`.
  **This only works if the distro mirrors are allowlisted** — see §5.

Verify the fix:

```bash
docker exec -u agent <c> sudo -n iptables -F OUTPUT   # expect: a password is required
docker exec -u agent <c> curl -s -o /dev/null -w '%{http_code}\n' https://example.com/  # expect 000
```

Check too that `/usr/local/bin/init-firewall.sh` is root-owned and not
agent-writable, or the remaining sudo entry is itself a root escalation. In the
port it is `-rwxr-xr-x root root`, and `/usr/local/bin` is not agent-writable.

---

## 2. DNS is an unrestricted egress channel

**Where:** `init-firewall.sh:162`

```bash
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
```

The rule matches on port only, with no destination. Any process — no sudo, no
privileges — can reach any nameserver on the internet and tunnel data out past
the allowlist. Verified in the port that arbitrary resolvers were reachable on
port 53 while everything else was correctly blocked.

Docker's version is slightly narrower than ours was (UDP only, no TCP 53), but
UDP is the usual DNS-tunnel transport, so the channel is open.

**Suggested fix:** pin the rule to the resolvers the container actually uses.
Docker publishes its embedded DNS at `127.0.0.11`, and the existing code
already preserves those NAT rules, so the container's own resolver is the right
destination:

```bash
# Allow DNS only to the configured resolver(s).
found=false
while read -r ns; do
    [[ -z "$ns" ]] && continue
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    found=true
done < <(awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' /etc/resolv.conf | sort -u)

# Never leave the container unable to resolve anything.
if [[ "$found" == false ]]; then
    echo "WARNING: no nameserver in /etc/resolv.conf; allowing DNS to any host"
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
fi
```

**Residual risk, worth stating in the README:** the configured resolver is
recursive, so queries for an attacker-controlled domain are still forwarded
upstream. Pinning the destination removes the trivial channel, not DNS
tunnelling in general. Closing that needs a filtering resolver, not iptables.

---

## 3. A startup race gives every new sandbox unfiltered network

**Where:** `entrypoint.sh:16-44` (firewall init) together with
`sbx:149` (`docker start`) and `sbx:167` (`docker exec -it`).

`docker run` / `docker start` return as soon as the container is up, but the
firewall is configured asynchronously by the entrypoint. `docker exec` attaches
immediately and **bypasses the entrypoint's ordering entirely**, so a session
can be live while egress is still unrestricted.

Measured in the port by polling a fresh container:

```
t= 2s example.com=200   <-- unfiltered
t= 4s example.com=000
t= 6s example.com=000   (blocked from here on)
```

Two to four seconds in the common case, but the window is bounded only by how
long setup takes: a `curl` to `api.github.com/meta` plus a DNS lookup for every
allowlisted domain. With ~40 domains and slow DNS, worst case is tens of
seconds. It recurs on every `start`, not just first creation.

This is easy to misread as "the firewall runs before the privilege drop, so
there is no window". That ordering is real but governs only processes the
entrypoint itself starts — not `docker exec`.

**Suggested fix:** a readiness handshake. In `entrypoint.sh`, clear a marker
before setup and create it after:

```bash
rm -f /run/sandbox-firewall-ready
# ... firewall init + refresh loop ...
: > /run/sandbox-firewall-ready
chmod 0644 /run/sandbox-firewall-ready
```

and in `sbx` / `agent-sandbox.sh`, block before attaching:

```bash
wait_for_firewall() {
    local c="$1" i
    for ((i = 0; i < 90; i++)); do
        docker exec "$c" test -f /run/sandbox-firewall-ready 2>/dev/null && return 0
        sleep 1
    done
    echo "Error: firewall did not come up within 90s; refusing to attach." >&2
    echo "Inspect with: docker logs $c" >&2
    exit 1
}
```

Clearing the marker on start matters: without it a restarted container reuses a
stale one and the wait is a no-op.

---

## 4. The firewall fails open

**Where:** `entrypoint.sh:38-41`

```bash
else
    echo "[entrypoint] WARNING: firewall init failed. Container may have unrestricted egress."
    echo "[entrypoint]   To run without firewall on purpose, pass --host-network ..."
fi
```

`init-firewall.sh` correctly `exit 1`s when verification fails, but the
entrypoint catches that and boots anyway with unrestricted egress. A transient
DNS failure or a GitHub API hiccup therefore produces a silently unprotected
sandbox — one warning line, scrolled past in the boot output, and the agent runs
with full internet access.

This is partly deliberate: there is a `--host-network` opt-out, and refusing to
boot is a worse experience when someone is mid-task. But an explicit opt-out is
exactly what makes failing *closed* affordable: the user who wants no firewall
already has a supported way to say so.

**Suggested fix:** treat firewall failure as fatal unless the user opted out.

```bash
if [[ "${SANDBOX_SKIP_FIREWALL:-}" != "1" ]]; then
    if ! sudo -n env ... /usr/local/bin/init-firewall.sh; then
        echo "[entrypoint] FATAL: firewall init failed; refusing to start unprotected." >&2
        echo "[entrypoint] To run without a firewall on purpose: agent-sandbox start --host-network" >&2
        exit 1
    fi
    # ... refresh loop ...
fi
```

Combined with §3, the marker should still be written in the `SANDBOX_SKIP_FIREWALL=1`
path, or the launcher's wait will time out on a deliberately unfirewalled sandbox.

---

## 5. Corollary: the host-side `apt` escape hatch needs the mirrors allowlisted

Not a pre-existing bug upstream — Docker's `DOMAINS` list already includes
`ports.ubuntu.com`, `archive.ubuntu.com`, `security.ubuntu.com`,
`deb.debian.org`, `security.debian.org` and `deb.nodesource.com`. Flagged here
because it is a trap when adopting §1.

Once the agent loses general sudo, "install it from the host with
`docker exec -u root`" becomes the documented workaround — and that still goes
through the same egress firewall. We removed sudo in the port before checking,
and `apt-get update` failed against every Ubuntu mirror. Keep those entries when
tightening, and verify:

```bash
docker exec -u root <c> apt-get update
```

---

## Not applicable upstream

Two further findings from the port were introduced during porting and do not
affect the Docker repo:

- **Wrong PyPI package.** The port installed `vibe-cli` (an unrelated Web3
  trading CLI that also ships a `vibe` binary, so `command -v vibe` succeeded and
  the failure was silent). Docker's `entrypoint.sh:204` correctly installs
  `mistral-vibe`. A `--version` smoke test after install would have caught the
  slip in either repo.
- **`container ls --format json` schema drift** between Apple Container CLI
  0.12.x and 1.2.x, which silently broke four helper functions. Docker's JSON
  output is stable; no action needed.

---

## Things the Docker repo does better

Recorded here so the improvement flow is not one-directional. The port has
adopted, or is adopting, all of these:

| Upstream approach | Why it is better |
|---|---|
| Named volumes for agent config | Container-local `~/.claude` etc. instead of bind-mounting the host's real config. Avoids exposing host credentials and, critically, avoids the agent writing host Claude Code hooks — which execute on the host. |
| `allow_host_port()` | Sanctioned single host:port channels (d2-broker, adb) instead of all-or-nothing host access. |
| `aggregate` on GitHub CIDRs | Collapses ranges before `ipset add`; fewer entries, less refresh churn. |
| Documented `INPUT ACCEPT` rationale | The permissive INPUT policy is a reasoned threat-model decision, written down, rather than an oversight. |
| In-container `CLAUDE.md` brief | Marker-delimited environment brief so the agent knows its own constraints instead of discovering them by trial and error. |
| Unit tests for pure helpers | `SBX_TEST=1 source` guard lets naming logic be tested without Docker. |
| Reproducible bug-verification command | `sandbox-runtime/KNOWN-ISSUES.md` ships a one-liner to re-test whether an upstream bug is still present. Far better than a prose claim — the Apple port's TTY "limitation" was a misdiagnosis that a command like that would have caught immediately. |
