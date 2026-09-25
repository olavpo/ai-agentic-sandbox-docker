# Changes to consider replicating in the Apple Container port

Companion to `UPSTREAM-DOCKER-IMPROVEMENTS.md`, going the other way: that doc
carried findings from `olavpo/ai-sandbox-container` (Apple Container) into this
repo; this one summarises what changed here as a result, and which of it is
worth replicating there.

Written 2026-08-14, against port commit `c641b2a`. The port's code was read but
**nothing was run there** — every "already done" below is from reading
`agent-sandbox-apple/{Dockerfile,entrypoint.sh,init-firewall.sh,sandbox}`, so
confirm before trusting it. Everything claimed about *this* repo was executed
and verified.

The short version: the port is ahead of where this repo was, and most of the
findings it raised are already fixed there. Two things are genuinely worth
backporting, one is a design choice, and there are two corrections to the
original findings doc.

---

## Summary

| # | Change here | Status in the port | Action |
|---|---|---|---|
| 1 | Self-healing firewall (verify rules, re-apply on tamper) | **Missing** | **Replicate** |
| 2 | Launcher skips the readiness wait for pre-existing sandboxes | **Likely missing** | **Replicate** |
| 3 | Drop the image a rebuild replaces | **Missing** | Optional |
| 4 | Sudo mode configurable per sandbox (`--strict-sudo`; since 2026-09-18 strict by default, `--allow-sudo` to opt in) | Strict unconditionally | Judgement call |
| 5 | DNS pinned to the container's resolvers | Already done (and better — also IPv6) | None |
| 6 | Firewall fails closed | Already done | None |
| 7 | Readiness handshake before attach | Already done | None |
| 8 | Agent-writable npm prefix | Already done (predates this repo's) | None |

---

## 1. Self-healing firewall — the main one to replicate

**Where here:** `init-firewall.sh` (`firewall_intact`, `PRESERVE_IPSET`),
`entrypoint.sh` (refresh loop).

The port's refresh loop, like this repo's before the change, only re-resolves
the allowlist — `init-firewall.sh --refresh-only` never looks at the iptables
rules. So a sandbox whose firewall has been removed stays open until it is next
recreated, with nothing in the logs.

The fix verifies the load-bearing pieces on every refresh pass and re-applies
the full policy when any is missing:

```bash
firewall_intact() {
    iptables -C OUTPUT -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || return 1
    iptables -C OUTPUT -m set --match-set allowed-domains dst -j ACCEPT 2>/dev/null || return 1
    [[ "$(iptables -S 2>/dev/null | awk '/^-P OUTPUT/ {print $3}')" == "DROP" ]] || return 1
    ipset list allowed-domains >/dev/null 2>&1 || return 1
    return 0
}
```

The port's REJECT rule uses `icmp-host-unreachable` on v4 (`init-firewall.sh:292`),
not `icmp-admin-prohibited`, so the `-C` spec has to match its own rule exactly
or the check will report tampering on every pass. If you extend this to IPv6,
add the `ip6tables` equivalents.

**The non-obvious part.** A repair must *not* re-resolve from scratch. Resolution
needs working egress, which is exactly what is broken at that moment — GitHub's
ranges come from an HTTPS call that is itself blocked — so a from-scratch repair
"heals" into a firewall that denies the hosts the sandbox needs. I hit this on
the first version: the heal succeeded but left the allowlist gutted. Preserve
the existing ipset and let the next scheduled refresh top it up.

Two consequences worth carrying over:

- Skip the `ipset destroy` and the `populate_allowed_ips` call when repairing
  and the set is already populated.
- The repair re-runs full init, which re-derives the single host:port exemptions
  from the environment. Whatever supplies those (here it is the privileged-boot
  wrapper re-reading PID 1's environment) has to supply them on the repair path
  too, or the broker/adb channels silently vanish on a heal.

Verify (adapt to `container exec`):

```bash
container exec -u agent <name> sudo iptables -P OUTPUT ACCEPT   # if the agent has sudo
container exec <name> curl -s -o /dev/null -w '%{http_code}\n' https://example.com/   # 200 = open
# wait one refresh interval
container exec <name> curl -s -o /dev/null -w '%{http_code}\n' https://example.com/   # want 000
container exec <name> ipset list allowed-domains | grep -c '^[0-9]'   # want the pre-tamper count
```

Here, with the interval set to 15 s, the sandbox was re-fenced unattended and
all 137 allowlist entries survived, with the broker rule and the `DROP` policy
restored.

Note this is a backstop, not a boundary: an agent with root can flush it again
immediately. It buys detection and recovery, not prevention.

---

## 2. Pre-existing sandboxes and the readiness wait

**Where here:** `sbx` and `agent-sandbox.sh` (`wait_for_firewall`).

The port already has the handshake (`READY_MARKER=/run/sandbox-firewall-ready`,
`sandbox:500`, `ensure_ready`). The problem is what it does to sandboxes created
*before* the handshake existed.

The launcher is a host-side script, so it starts gating immediately — but the
marker is written by the entrypoint baked into the container's image, and image
content is fixed at creation. Old containers never write it and cannot be made
to. Here, every one of 14 existing sandboxes would have blocked for the full 90 s
timeout and then refused to attach. Verified on a three-week-old container: old
entrypoint, no marker after 12 s.

The fix probes the container's own entrypoint for the capability instead of
assuming it:

```bash
if ! docker exec "$c" grep -q sandbox-firewall-ready \
        /usr/local/bin/entrypoint.sh 2>/dev/null; then
    echo "Note: '$c' predates the firewall readiness handshake; attaching without it."
    echo "  Recreate it to pick those up: agent-sandbox remove $c"
    return 0
fi
```

Whether this bites in the port depends on whether any sandbox created before
commit `769fca2` still exists. If they were all recreated, this is moot — but
the same trap applies to *any* future change gated on something the container
must provide.

---

## 3. Dropping the image a rebuild replaces

**Where here:** `agent-sandbox.sh` (`build_image`, `prune_previous_image`).

Rebuilding moves the tag to the new image and leaves the old one untagged and
on disk — ~2.7 GB each, accumulating invisibly. The launcher now records the
image id before building and removes it after, but only when no container
references it, and scoped to this image rather than a blanket prune that would
also delete unrelated dangling images.

Worth knowing before implementing: **stopped sandboxes count as users**, and
since the launcher stops rather than removes containers so sessions stay
resumable, old sandboxes pin the image they were built from indefinitely. That
is the usual reason a rebuild cannot reclaim the space, so the skipped case
should name the holders rather than failing silently.

Whether the Apple `container` CLI leaves untagged images the same way is worth
checking before porting any of this — `container images list` after two builds
answers it.

---

## 4. Sudo mode as a per-sandbox choice

*Update 2026-09-18: the default flipped to strict, matching the port. `--allow-sudo` opts a sandbox in at creation, and `agent-sandbox sudo <c> on` grants sudo to a running sandbox until its next restart. The rest of this section is as written at the time.*

The port removed general sudo outright (`Dockerfile:39-52`), keeping only the
targeted `init-firewall.sh` entry. This repo went a different way: passwordless
sudo stays the default, and `--strict-sudo` (or `SANDBOX_STRICT_SUDO=1` in
`.env`) removes it per sandbox.

That is a judgement call, not a finding — the port's posture is the safer one.
The argument for making it optional is that the cost falls entirely on runtime
package installs, and how much that hurts depends on the work: a sandbox doing
DHIS2 app development rarely needs `apt-get`, one doing exploratory tooling
work needs it constantly. A curated sudo allowlist is not available as a middle
ground, since `apt-get install` runs maintainer scripts as root.

**What is worth taking from here regardless of that choice** is the agent brief.
The in-container `CLAUDE.md` now has a different Permissions section per mode.
An agent told it has root that it doesn't will spend turns on `sudo apt-get` and
misread the failures as something else; if the port is unconditionally strict,
its brief should say so plainly and point at the host-side
`container exec -u root` path instead.

**Do not port this repo's `/proc/1/environ` wrapper.** It exists only because
the entrypoint here runs as `agent` and needs a root action parameterised by
values the agent must not control — authorising `sudo env VAR=…` is equivalent
to authorising root, and accepting the values as arguments would let the agent
open its own egress hole. The port does not have that problem: its Dockerfile
has no `USER` directive, so the entrypoint runs as root and does its privileged
setup directly, then drops with `runuser -u agent` (`entrypoint.sh:79`). That is
the cleaner architecture and needs no wrapper.

It has its own failure mode, though, and it is worth an audit. Because the image
has no `USER`, the default user for an exec is **root** — so *every* exec path
must pass `-u agent` explicitly. `sandbox:500` is one that does not —

```bash
container exec "$name" test -f /run/sandbox-firewall-ready
```

— harmless in itself (a `test -f`), but it shows how easily the flag is omitted,
and here the consequence is not cosmetic: a missed `-u agent` on an interactive
path hands the agent a root shell, silently undoing the sudo removal that is the
port's main protection. A `grep -n 'container exec' sandbox | grep -v '\-u agent'`
sweep is cheap insurance, and worth a test that asserts it.

---

## Corrections to `UPSTREAM-DOCKER-IMPROVEMENTS.md`

Both were found while implementing its recommendations here.

**§1's repro does not hold where the OUTPUT policy is DROP.** `iptables -F OUTPUT`
alone does not open the sandbox: flushing the rules leaves the policy denying
everything, which locks the sandbox *down* rather than opening it. The working
escape needs the policy flip as well:

```bash
iptables -P OUTPUT ACCEPT && iptables -F OUTPUT
```

The port sets `-P OUTPUT DROP` at `init-firewall.sh:270`, so if that reflects
the state at the time of the original review, the "flush → 200" observation
recorded there needs re-checking. The conclusion is unchanged — an agent with
root defeats the firewall — but a test that only flushes will wrongly report
the sandbox as safe.

**§2's suggested rule is partly redundant and Docker-specific.** Pinning
`-d 127.0.0.11 --dport 53` would not have matched anyway: on a Docker
user-defined network the embedded resolver is reached over loopback (already
covered by the `-o lo` rule) and the restored NAT rules rewrite the port before
the filter table sees it. This does not affect the port, which has no equivalent
of `127.0.0.11` — and its implementation, reading nameservers from
`/etc/resolv.conf` for both v4 and v6, is the right shape regardless.

---

## Things the port does better (candidates for the reverse direction)

| Port approach | Why it is better |
|---|---|
| `ip6tables` rules alongside `iptables` | This repo has **no IPv6 rules at all**. Currently latent — a container here has no global IPv6 address or default route, so there is nothing to leak through — but the allowlist would be bypassable the moment IPv6 is enabled on the Docker network. The port already handles both families. |
| Agent-writable `NPM_CONFIG_PREFIX` set in the image | The port has had this since before this repo did; it only arrived here because strict sudo forced it. It is good practice on its own — runtime `npm install -g` should never need root. |
| DNS fallback covers TCP as well as UDP | The port's no-nameserver fallback opens both; this repo's opens UDP only. Minor, since the fallback is a last resort, but the port's is more correct. |
| Explicit `-u agent` on exec | Makes the privilege boundary visible at each call site rather than implicit in the image's `USER`. |

The IPv6 gap is the one I would act on here.
