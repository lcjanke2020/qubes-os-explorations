# Locking Down Qube Outbound: LAN Peers Reachable Only Over the Tailnet

*A field guide for Qubes OS app qubes that run Tailscale **inside** the qube. Goal: other
devices on the physical LAN can be reached **only** over the tailnet (the `100.64.0.0/10` CGNAT
range, i.e. `100.x`), never via their raw LAN IPs — so no plaintext LAN path exists and all peer traffic rides
authenticated, encrypted WireGuard. Reproduced end-to-end on Qubes OS 4.x with Tailscale running
in Debian- and Fedora-based app qubes. The drop recipe below is **IPv4**; IPv6 is handled
explicitly in §4.*

---

## TL;DR — the headline

You harden these qubes by **blocking the physical LAN subnet** in the per-qube Qubes firewall
and leaving the rest of the internet open — **not** by whitelisting the tailnet range:

```bash
# in dom0 — substitute YOUR real LAN CIDR (see §2; do not assume /24):
qvm-firewall <qube> add --before 0 action=drop dsthost=192.168.1.0/24
qvm-firewall <qube> list      # confirm the drop is rule 0, ahead of the accept-all
```

Three things trip people up, and they're the whole reason this guide exists:

1. **Whitelisting `100.64.0.0/10` would kill Tailscale**, not lock it down (§1).
2. **A plain `qvm-firewall add` puts the drop in the wrong place** and it silently never
   matches — you need `--before 0` (§3).
3. **The rule is IPv4-only.** If your qubes also route IPv6 to the LAN, that path stays open until
   you handle it — check and, if needed, drop the v6 LAN prefixes too (§4).

This assumes the qube is in Qubes' default **allow-all** network posture (§3).

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

The qube sits on a Qubes-internal `10.137.x` network behind its netvm's NAT (`sys-firewall` by
default), which in turn reaches the physical LAN through `sys-net`. So the physical LAN subnet
isn't visible from inside the qube — read it from `sys-net`'s upstream
(WAN) interface — run the following from dom0 (the `ip` commands execute *inside* `sys-net` via
`qvm-run`), deriving the WAN interface from the default route so you don't guess among
loopback/Qubes-internal interfaces:

```bash
qvm-run --pass-io --user root sys-net '
  IFACE=$(ip -4 route show default | awk "{print \$5; exit}")
  echo "WAN iface: $IFACE"
  ip -4 -o addr show dev "$IFACE"
  ip -4 route show dev "$IFACE" scope link'
# WAN iface: ens6
# ens6  inet 192.168.1.10/24 ...
# 192.168.1.0/24 dev ens6 proto kernel scope link src 192.168.1.10   <-- the LAN CIDR, authoritative
```

The `scope link` route line **is** your LAN CIDR (`192.168.1.0/24` above) — read it directly rather
than hand-deriving the network address from the interface IP, which is error-prone for non-`/24`
prefixes (a `/23` host like `192.168.1.34/23` sits on `192.168.0.0/23`, not `192.168.1.0/23`).
**Don't hard-code `/24`.** If your edge device is
in bridge/AP mode, the relevant subnet is the *upstream* router's, which is what `sys-net`'s
lease shows.

---

## 3. Apply the drop — and why `--before 0` matters

**This assumes the qube is in allow-all posture.** A fresh qube's firewall is a **single
`accept`-all rule at position 0** ("allow all network access" checked) — that's what this guide
targets. If you've already set the qube to **deny-by-default** (allow-all unchecked, only specific
`accept` rules), the LAN is already unreachable and you don't need this drop; adding one ahead of
your allowlist would just be redundant.

Qubes evaluates rules top-to-bottom, first match wins, with an implicit drop only *after* the last
rule. So if you run the obvious command:

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

Rules are enforced in `sys-firewall` and take effect **immediately — no reboot.** Roll back by
**rule spec**, not `--rule-no 0`: if you later add the §4 IPv6 drops at `--before 0` they shift this
rule's number down, so matching the spec removes exactly the LAN drop regardless of position:

```bash
qvm-firewall <qube> del action=drop dsthost=192.168.1.0/24   # position-independent; repeat per prefix for any v6 drops
```

---

## 4. IPv6 — check whether it's even in play, then cover it

The drop in §3 matches **IPv4 only**. The guide's promise ("reachable only over the tailnet") is
false if a qube can also reach the LAN over **IPv6**, so handle v6 explicitly. Good news: in
**default Qubes, IPv6 is not forwarded to qubes**, so most setups have *no* v6 LAN path to close —
check before you act.

**Check (dom0 + the qube):**

```bash
# 1) Is IPv6 forwarding to qubes even enabled? Empty output = feature off = no v6 LAN path.
qvm-features sys-firewall ipv6 ; qvm-features sys-net ipv6

# 2) AUTHORITATIVE signal: does the qube have a v6 DEFAULT ROUTE? If it does, Qubes is routing v6
#    to it — whether or not ICMPv6 happens to be permitted.
qvm-run --pass-io --user root <qube> 'ip -6 route show default'

# 3) Confirm egress with a TCP (not ICMP) probe — ICMPv6 may be filtered while TCP/UDP v6 still
#    routes, so don't decide on a v6 ping alone. NB: pass the IPv6 literal WITHOUT brackets —
#    bash's /dev/tcp rejects the bracketed [..] form (it fails name resolution before connecting,
#    so a bracketed probe would always print "no" even with v6 egress). Port 443 dodges TCP/53
#    filtering:
qvm-run --pass-io --user root <qube> \
  'timeout 5 bash -c "exec 3<>/dev/tcp/2606:4700:4700::1111/443" && echo "v6 egress: YES" || echo "v6 egress: no"'
```

**If the qube has no v6 default route** (the Qubes default): its only non-link-local IPv6 is
Tailscale's ULA range (`fd7a:115c:a1e0::/48`, carried inside `tailscale0`); everything else is
link-local (`fe80::`) on the netvm link. **There is no raw IPv6 LAN path, and the §3 IPv4 drop is
sufficient.** (`sys-net` itself often *does* have full IPv6 from the router — that's fine; what
matters is whether the *qube* routes it.) This is contingent on the `ipv6` feature staying off —
**re-check if you ever enable Qubes IPv6.**

**If the qube does route IPv6**, discover the LAN's v6 prefix(es) on `sys-net` and drop the
**specific** ones, mirroring §3:

```bash
qvm-run --pass-io --user root sys-net 'ip -6 -o addr show scope global'
# a delegated GUA prefix (e.g. 2001:db8:abcd:1234::/64) and/or a ULA (e.g. fd12:3456:789a::/64)

qvm-firewall <qube> add --before 0 action=drop dsthost=2001:db8:abcd:1234::/64
qvm-firewall <qube> add --before 0 action=drop dsthost=fd12:3456:789a::/64

qvm-firewall <qube> list   # confirm the v6 drops landed at the top, ahead of the accept-all
```

**Do not** blanket-drop `fd00::/8` or `::/0`. Tailscale's tunnel range (`fd7a:115c:a1e0::/48`)
lives inside `fd00::/8`, and `::/0` would kill v6 internet (and the v6 underlay) — it's the same
"drop the LAN, not everything" rule as IPv4. A delegated GUA prefix can rotate when the ISP changes
it, so pin the rule to the stable ULA and re-check the GUA after prefix changes.

**And do not drop `fe80::/10`.** In the standard routed Qubes topology a qube's link-local only
reaches its netvm — not LAN neighbors (same as the multicast note in §5) — so there's nothing to
gain; meanwhile the qube's own v6 default gateway is typically a link-local address on the netvm
link, so a `fe80::/10` drop would blackhole the gateway (and NDP) and break v6 entirely. (A qube
*bridged* directly onto the LAN is a different topology — analyze it separately; a blanket
`fe80::/10` drop still isn't the right tool.)

---

## 5. Gotchas

- **Never blanket-block `10.0.0.0/8` or `172.16.0.0/12`.** Qubes' own gateway, inter-qube NAT,
  and DNS live in `10.137.x` / `10.138.x` / `10.139.x`. Block **only** the specific physical LAN
  subnet from §2. (DNS keeps working: a qube's resolvers are the Qubes `10.139.x` addresses, not
  the LAN router.)

- **Same-LAN tailnet peers lose their *direct* path → fall back to DERP.** Tailscale's fast
  direct route to a peer that's on the same physical LAN uses that peer's address inside your
  physical LAN CIDR (e.g. `192.168.1.x`) as the WireGuard underlay. Dropping the LAN subnet drops that too, so traffic to same-LAN peers
  reroutes through a DERP relay — still encrypted and "over the tailnet," but with added latency
  and a dependence on reaching the relay. This is the **perf-vs-purity trade-off**: it's the
  intended cost of guaranteeing no plaintext LAN path. (Allowing a specific peer's LAN IP back in
  would restore direct speed but reopens a plaintext route — don't, unless you mean to.)

- **Multicast/broadcast discovery is link-scoped — and in standard Qubes it doesn't reach the
  LAN.** mDNS (`224.0.0.251`, `ff02::fb`), SSDP/WS-Discovery (`239.255.255.250`) and friends are
  link-local, and a unicast LAN drop doesn't stop a qube from *emitting* them. But a qube's only
  link is the point-to-point connection to its netvm — **not** the physical LAN segment — and
  Qubes doesn't forward that multicast onward, so it never reaches LAN devices. Worth knowing only
  if you ever bridge a qube directly onto the LAN; not a leak in the normal
  routed-through-`sys-firewall` topology.

- **Complement it on the *inbound* side.** The outbound drop stops the qube from *reaching* the
  LAN; it does nothing about what the qube *exposes*. Bind listeners to the tailnet interface /
  loopback rather than `0.0.0.0` (or `::`), and/or restrict inbound to the tailnet interface in the
  qube's own firewall (a `qubes-firewall-user-script` nft rule like
  `iifname "tailscale0" tcp dport <port> accept`, with no LAN-facing accept). App qubes behind
  the `sys-firewall`→`sys-net` NAT chain have no inbound LAN path anyway, but binding to the
  tailnet interface makes
  "nothing is listening on the LAN side even if reached" explicit, and layering Tailscale ACLs on
  top controls *who* may connect.

---

## 6. The enforcement lives in `sys-firewall` — don't assume it's continuous

The drop is enforced in `sys-firewall` (the NetVM), **not inside the locked-down qube itself.**
Qubes implements firewall rules in the net qube, so the protection is only as continuous as that
qube — and its firewall service — being up.

`sys-firewall` is built from a template typically **shared** with other qubes; updating that
template means **cycling `sys-firewall`**. Two things are worth knowing about that window:

- A qube **started while its netvm isn't applying rules fails *closed*** — it simply has no
  networking. That's the safe direction.
- The case to think about is a qube that is **already running** through a netvm that briefly
  cycles. Don't *assume* the per-qube policy is continuous across that event; treat the boundary as
  potentially open while the net qube or its firewall service is down/restarting. How wide that
  window is — or whether it opens at all on a given Qubes version — depends on netvm start ordering;
  this is a risk to design around, not a measured gap.

Why it matters: a qube that is *already compromised* could wait for exactly such a maintenance
window to make a LAN reach-out. So treat this as **defense-in-depth, not a hermetic seal** — it
removes the standing plaintext LAN path in normal operation, but don't let anything else on the LAN
depend on this single control.

**To close the window during maintenance:** shut the locked-down qubes down *before* you cycle
`sys-firewall`, and start them again only **after** the netvm is back up with rules applied. A qube
that isn't running can't exploit the gap — at the cost of downtime and a deliberate restart order.

---

## 7. Verification

Run these from the locked-down qube (`qvm-run --user root <qube> '...'` from dom0).

### Establish a baseline first (or the negative test can false-pass)

A LAN probe that fails *after* the drop only proves something if it **succeeded before** it. If the
target host was off, had no listener, or firewalled the port anyway, the probe fails identically
with or without your rule — and you'd wrongly conclude "locked down." Pick a LAN `host:port` you
know is up (another box's SSH, a NAS UI, the router) and confirm it's reachable **before** applying
the drop:

```bash
# BEFORE the --before 0 drop — should SUCCEED (proves there's a real path to test):
timeout 5 bash -c 'exec 3<>/dev/tcp/<lan-host>/<port>' && echo "reachable (baseline ok)"
```

### Negative — the raw LAN path must be gone

After the drop, the same probe should **fail** (a blocked path may present as a timeout *or* an
immediate "unreachable/prohibited" — either counts):

```bash
timeout 5 bash -c 'exec 3<>/dev/tcp/<lan-host>/<port>' || echo "blocked (good)"
ping -c1 -W3 <lan-gateway>    # informational only — see the ICMP note below
```

The **TCP `/dev/tcp` probe is the authoritative test.** ICMP can be filtered or handled differently
from TCP/UDP by the firewall or the target, so a `ping` result either way isn't conclusive on its
own.

### Positive — the tailnet still works

The clean criterion is: **the raw LAN path fails AND `tailscale ping` reaches the peer over the
tunnel.** Don't require a specific underlay path:

```bash
tailscale ping --until-direct=false <peer>   # --until-direct=false = report the first pong and
                                             # stop, instead of retrying to upgrade to a direct path
timeout 5 bash -c 'exec 3<>/dev/tcp/<peer-100.x>/<port>'   # a service the tailnet ACL permits
getent hosts <peer>          # MagicDNS still resolves the name to 100.x
curl -sS -m6 -o /dev/null -w '%{http_code}\n' http://1.1.1.1/    # internet still up (plain HTTP; any code — e.g. 301 — means reachable)
getent hosts example.com     # DNS still resolves
```

Reading the `tailscale ping` line — **any** of these means the tunnel is healthy:

```text
pong from <peer> (100.x.y.z) via DERP(nyc) in 22ms          # relayed — common for same-LAN peers now
pong from <peer> (100.x.y.z) via <public-ip>:41641 in 9ms   # direct via a NON-LAN endpoint — also fine
```

A direct path can still form over a non-LAN endpoint (NAT hairpin, another discovered address), so
**DERP is the *likely* fallback for same-LAN peers, not a required outcome.** The one line you do
*not* want is a direct pong via an address inside your **blocked LAN CIDR** (e.g. `192.168.1.x`, or
whatever §2 gave you) — that would mean the LAN underlay is still open and the drop didn't fully
take.

### Two ways the verification misleads you — don't chase ghosts

- **Kernel ICMP to `100.x` is not a reliable signal.** Plain `ping 100.x.y.z` may fail even when
  the tunnel is healthy — many tailnets don't permit ICMP between nodes, and there's a brief
  direct→DERP failover window right after the drop. Trust `tailscale ping` (the disco layer) for
  liveness.
- **A "not reachable" TCP result can be a Tailscale ACL, not your firewall.** If `tailscale ping`
  pongs but a TCP connection to one of the peer's ports fails, that port is almost certainly gated
  by your **tailnet ACL policy** (or the peer's host firewall), not by the LAN drop. Confirm with a
  port/peer the ACL is known to allow.

---

## 8. Scope — what this was tested on

- Qubes OS 4.x, firewall enforced in `sys-firewall`, rules set with `qvm-firewall` from dom0.
- **IPv4** drop recipe. In default Qubes (IPv6 not forwarded to qubes) there is no raw IPv6 LAN
  path and the IPv4 rule is sufficient; if you enable Qubes IPv6, add the v6 prefix drops from §4.
- Tailscale installed and running **inside** the app qubes (Debian- and Fedora-based), not on a
  dedicated network qube. The "tunnel is above the firewall" reasoning in §1 is specific to that
  topology.
- MagicDNS enabled (so tailnet names resolve to `100.x` and the raw LAN path is simply absent).
- Rules are enforced by whatever netvm the qube **currently** uses (`sys-firewall` here). If you
  route the qube through a VPN qube or a custom netvm, confirm that netvm actually applies
  `qvm-firewall` rules before relying on this.

If you instead run Tailscale on a sys-net/sys-vpn–style network qube, the trust boundaries and
the interface the firewall sees are different — the §1 reasoning would need to be re-derived for
that layout.

---

*Part of [qubes-os-explorations](README.md) — see the Guides list there for related field notes.*
