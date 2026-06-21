# Locking Down Qube Outbound: LAN Peers Reachable Only Over the Tailnet

*A field guide for Qubes OS app qubes that run Tailscale **inside** the qube. Goal: other
devices on the physical LAN can be reached **only** over the tailnet (the `100.x` CGNAT range),
never via their raw LAN IPs — so no plaintext LAN path exists and all peer traffic rides
authenticated, encrypted WireGuard. Verified end-to-end on Qubes OS 4.x with Tailscale running
in Debian- and Fedora-based app qubes.*

---

## TL;DR — the headline

You harden these qubes by **blocking the physical LAN subnet** in the per-qube Qubes firewall
and leaving the rest of the internet open — **not** by whitelisting the tailnet range:

```bash
# in dom0 — substitute YOUR real LAN CIDR (see §2; do not assume /24):
qvm-firewall <qube> add --before 0 action=drop dsthost=192.168.1.0/24
qvm-firewall <qube> list      # confirm the drop is rule 0, ahead of the accept-all
```

Two things trip people up, and they're the whole reason this guide exists:

1. **Whitelisting `100.64.0.0/10` would kill Tailscale**, not lock it down (§1).
2. **A plain `qvm-firewall add` puts the drop in the wrong place** and it silently never
   matches — you need `--before 0` (§3).

---

## 1. Why "block the LAN," not "whitelist the tailnet"

Tailscale runs **inside** the qube. `tailscaled` encapsulates your `100.x` traffic as WireGuard
**before** it ever leaves the qube's `eth0`. So what the Qubes firewall (enforced in
`sys-firewall`) actually sees is **not** `100.x` packets — it sees the WireGuard **underlay**:

- UDP to peers' real endpoints (public IPs, and `192.168.x` for same-LAN peers), and
- HTTPS to the Tailscale control plane and DERP relays (public IPs).

The tunnel does its work *above* the firewall. Consequences:

- **Whitelisting `100.64.0.0/10` and dropping the rest would break Tailscale entirely** — the
  firewall never sees `100.x` on the wire, and you'd have blocked the public-internet underlay
  the tunnel depends on.
- The correct lever is the inverse: **drop the one physical LAN subnet** (so no qube process can
  open a plaintext socket to a LAN neighbor) while leaving general internet egress open (so the
  WireGuard underlay, control plane, and DERP keep working).

Everything a locked-down qube reaches on the LAN must therefore go by its tailnet address
(`100.x`) or MagicDNS name, which resolves to `100.x` — the raw LAN path is simply absent.

---

## 2. Find your real LAN CIDR (don't assume)

The qube itself sits on a Qubes-internal `10.137.x/10.138.x` network behind `sys-net`'s NAT, so
the physical LAN subnet isn't visible from inside the qube. Read it from `sys-net`'s upstream
(WAN) interface in dom0:

```bash
qvm-run --pass-io --user root sys-net 'ip -4 route show default; ip -4 -o addr show'
# default via 192.168.1.1 dev ens6 ...
# ens6  inet 192.168.1.10/24 ...     <-- CIDR = 192.168.1.0/24
```

The LAN CIDR is the WAN interface's address with its network prefix (e.g. `192.168.1.10/24`
→ `192.168.1.0/24`). **Don't hard-code `/24`** — read the actual prefix. If your edge device is
in bridge/AP mode, the relevant subnet is the *upstream* router's, which is what `sys-net`'s
lease shows.

---

## 3. Apply the drop — and why `--before 0` matters

A fresh qube's firewall is a **single `accept`-all rule at position 0** (this is what "allow all
network access" looks like under the hood). Qubes evaluates rules top-to-bottom, first match
wins, with an implicit drop only *after* the last rule.

So if you run the obvious command:

```bash
qvm-firewall <qube> add action=drop dsthost=192.168.1.0/24      # WRONG placement
```

…the drop is appended **after** the accept-all. The accept-all matches every packet first, and
**your drop never runs.** `qvm-firewall list` will happily show the rule — it just sits behind a
catch-all and does nothing. This is the trap: it *looks* applied.

Insert it **ahead** of the accept-all instead:

```bash
qvm-firewall <qube> add --before 0 action=drop dsthost=192.168.1.0/24
```

Confirm the ordering — the drop must be rule `0`, the accept-all rule `1`:

```text
NO  ACTION  HOST            ...
0   drop    192.168.1.0/24      <-- LAN traffic hits this first
1   accept  -                   <-- everything else (internet + WireGuard underlay)
```

If a qube has extra accept rules (e.g. a leftover install-time mirror allowlist), `--before 0`
still does the right thing: the LAN drop jumps to the very top and the rest are unaffected.

Rules are enforced in `sys-firewall` and take effect **immediately — no reboot.** Rollback is one
command:

```bash
qvm-firewall <qube> del --rule-no 0
```

---

## 4. Gotchas

- **Never blanket-block `10.0.0.0/8` or `172.16.0.0/12`.** Qubes' own gateway, inter-qube NAT,
  and DNS live in `10.137.x` / `10.138.x` / `10.139.x`. Block **only** the specific physical LAN
  subnet from §2. (DNS keeps working: a qube's resolvers are the Qubes `10.139.x` addresses, not
  the LAN router.)

- **Same-LAN tailnet peers lose their *direct* path → fall back to DERP.** Tailscale's fast
  direct route to a peer that's on the same physical LAN uses that peer's `192.168.x` endpoint as
  the WireGuard underlay. Dropping the LAN subnet drops that too, so traffic to same-LAN peers
  reroutes through a DERP relay — still encrypted and "over the tailnet," but with added latency
  and a dependence on reaching the relay. This is the **perf-vs-purity trade-off**: it's the
  intended cost of guaranteeing no plaintext LAN path. (Allowing a specific peer's LAN IP back in
  would restore direct speed but reopens a plaintext route — don't, unless you mean to.)

- **Complement it on the *inbound* side.** The outbound drop stops the qube from *reaching* the
  LAN; it does nothing about what the qube *exposes*. Bind listeners to the tailnet interface /
  loopback rather than `0.0.0.0`, and/or restrict inbound to the tailnet interface in the qube's
  own firewall (a `qubes-firewall-user-script` nft rule like
  `iifname "tailscale0" tcp dport <port> accept`, with no LAN-facing accept). App qubes behind
  `sys-net`'s NAT have no inbound LAN path anyway, but binding to the tailnet interface makes
  "nothing is listening on the LAN side even if reached" explicit, and layering Tailscale ACLs on
  top controls *who* may connect.

---

## 5. The enforcement lives in `sys-firewall` — mind the template-upgrade window

The drop is enforced in `sys-firewall` (the NetVM), **not inside the locked-down qube itself.**
That's normal for Qubes, but it has a consequence worth internalizing: the protection is only as
continuous as `sys-firewall`'s own uptime.

`sys-firewall` is built from a template that is typically **shared** with other qubes. When you
update that template, you have to **cycle `sys-firewall`** to pick up the change — it goes down
and comes back. Around that restart there is a window where the per-qube LAN drop is **not in
force**: as `sys-firewall` re-initializes and the connected qubes' uplinks return, the raw LAN
path can be momentarily reachable again before the rules are re-applied.

If a qube is already compromised, an attacker-controlled process can simply **wait** for exactly
that window — a template upgrade, a `sys-firewall` restart — and make its LAN reach-out then. Even
a brief opening can be enough if there is a soft target elsewhere on the LAN.

**So don't treat this as a hermetic seal.** It meaningfully raises the bar — there is no standing
plaintext LAN path during normal operation — but it does not *eliminate* the risk. The honest
framing is defense-in-depth: assume the boundary can have gaps, and don't let anything else on the
LAN depend on this single control.

**To close the window during maintenance:** shut down the locked-down qubes (in practice, the ones
routing through `sys-firewall`) *before* you cycle `sys-firewall` for the template update, and
start them again only **after** `sys-firewall` is fully back up with its rules re-applied. A qube
that isn't running can't exploit the gap. The cost is real — downtime plus a deliberate, ordered
start/restart sequence instead of a casual update — so weigh it against how much you distrust the
qubes in question.

---

## 6. Verification

From the locked-down qube (run via `qvm-run --user root <qube> '...'` from dom0):

**Negative — the raw LAN path must be gone.** A LAN neighbor's raw IP (and the LAN gateway)
should time out:

```bash
# both should fail after the drop:
timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.1.50/22'   # a LAN device
ping -c1 -W3 192.168.1.1                                # the LAN gateway
```

**Positive — the tailnet still works.** Use `tailscale ping` for liveness and a real TCP service
for the actual path:

```bash
tailscale ping --until-direct=false <peer>     # expect a pong "via DERP(...)" for same-LAN peers
timeout 5 bash -c 'exec 3<>/dev/tcp/<peer-100.x>/<port>'   # a service the ACL permits
getent hosts <peer>            # MagicDNS still resolves the name to 100.x
curl -sS -m6 -o /dev/null -w '%{http_code}\n' https://1.1.1.1/   # internet still up
getent hosts example.com       # DNS still resolves
```

**Two ways the verification misleads you — don't chase ghosts:**

- **Kernel ICMP to `100.x` is not a reliable signal.** Plain `ping 100.x.y.z` may fail even when
  the tunnel is perfectly healthy — many tailnets don't permit ICMP between nodes, and right
  after you apply the drop there's a brief direct→DERP failover window. Trust
  `tailscale ping --until-direct=false` (the disco layer) for liveness, not kernel ping.
- **A "not reachable" TCP result can be a Tailscale ACL, not your firewall.** If `tailscale ping`
  to a peer pongs but a TCP connection to one of its ports fails, that port is almost certainly
  gated by your **tailnet ACL policy** (or the peer's own host firewall), not by the LAN drop you
  just made. Confirm by testing a port/peer the ACL is known to allow.

A clean result: raw-LAN targets time out; `tailscale ping` pongs (via DERP for same-LAN peers);
an ACL-permitted tailnet service connects; MagicDNS resolves to `100.x`; and general internet +
DNS are unaffected.

---

## 7. Scope — what this was tested on

- Qubes OS 4.x, firewall enforced in `sys-firewall`, rules set with `qvm-firewall` from dom0.
- Tailscale installed and running **inside** the app qubes (Debian- and Fedora-based), not on a
  dedicated network qube. The "tunnel is above the firewall" reasoning in §1 is specific to that
  topology.
- MagicDNS enabled (so tailnet names resolve to `100.x` and the raw LAN path is simply absent).

If you instead run Tailscale on a sys-net/sys-vpn–style network qube, the trust boundaries and
the interface the firewall sees are different — the §1 reasoning would need to be re-derived for
that layout.
