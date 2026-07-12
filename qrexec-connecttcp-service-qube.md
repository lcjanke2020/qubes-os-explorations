# Serving From a Qube With No Network-Facing Listener: qrexec `ConnectTCP` Instead of sshd

*A field guide for consuming a service from a qube that has **no network-facing
listener at all** — the service binds to `127.0.0.1` and stays there. Other qubes reach
it over Qubes' own RPC (`qubes.ConnectTCP`), gated by a one-line dom0 policy. Worked
end-to-end on Qubes OS 4.1+ (the `/etc/qubes/policy.d` policy format) with an LLM server
(ollama, port `11434`) on a GPU-passthrough HVM, consumed by an app qube; the pattern is
service-agnostic — substitute your port.*

---

## TL;DR — the headline

You do **not** need sshd, a tailnet listener, or any LAN-facing bind to consume a service
hosted in another qube on the same Qubes host. One dom0 policy line:

```
# /etc/qubes/policy.d/30-connecttcp.policy
qubes.ConnectTCP +11434 <client-qube> <service-qube> allow autostart=no
```

and a client-side call (`qrexec-client-vm <service-qube> qubes.ConnectTCP+11434`, or a
small `socat` wrapper when the consumer is a container) gives the client TCP to the
service qube's **loopback** port — and nothing else. (`+11434` is the **port argument**
to `qubes.ConnectTCP`: substitute your service's port there and in every client-side
call.) The service qube has **no network-facing listener**: no open ports other than
loopback-bound ones, no key material, no admin channel riding along with the service
path. What remains inbound is exactly what the policy says — a qrexec channel to that
one port, from that one client qube.

Our reference GPU qube has **never had sshd installed or enabled at any point in its
life**. Not "locked down later," not "temporarily open during the migration" — never
present. That is the posture this pattern makes practical.

## Why you'd want this

The vanilla-Linux reflex for "qube B needs to talk to qube A's service" is to make the
service reachable: bind it to the LAN or tailnet address, or install sshd for tunnels and
admin while you're at it. Every one of those is a standing listener — surface that exists
around the clock so that a request can arrive occasionally.

`qubes.ConnectTCP` inverts that:

- **No network listeners on the service qube.** The service binds `127.0.0.1` only.
  Verify with `ss -ltnu` — every socket (UDP included) should show a loopback address.
  There is nothing for a network scanner (or a compromised LAN/tailnet peer) to even
  connect to.
- **Per-pair, per-port grant.** The policy names one port, one source qube, one
  destination qube. It's auditable in a single line, and it grants exactly *TCP to that
  port* — not exec, not a shell, not a tunnel-anything sshd. (Contrast a standing sshd:
  key management, version exposure, and an admin-grade channel bundled into what should
  have been a data path.)
- **No teardown debt.** There is no "we'll close port 22 after the migration" task that
  never happens, because nothing was opened.

### The GPU-passthrough angle

This pattern was built around a GPU-passthrough HVM (see
[the passthrough guide](nvidia-gpu-passthrough.md)), and that's not incidental. A
passthrough qube is a **more privileged neighbor** than a plain AppVM: it owns real
hardware behind the IOMMU, runs a large vendor driver stack, and tends to become a
long-lived pet with expensive state (driver builds, model files) — exactly the kind of
qube people bolt sshd onto "for convenience." Its privileged position argues the other
way: the more a qube touches, the stronger the case for keeping it off the network
entirely. With this pattern the GPU qube serves a multi-gigabyte model to another qube
while exposing **no port beyond loopback**.

## The honest tradeoffs

- **The service itself is still attack surface — to exactly one client.** `ConnectTCP`
  removes *network reachability*; it does not harden the application behind it. The
  client qube named in the policy gets a raw TCP path to the service's protocol parser,
  so a compromised client qube can attack the service directly, same as any consumer
  could. What you've removed is everyone else — plus the admin channel a listener like
  sshd would have bundled in.
- **An `allow` policy is standing access.** The client qube can reach that one loopback
  port whenever the service qube is running — you've traded a per-connection human
  decision for a one-time, narrowly-scoped grant. (You can write `ask` instead of `allow`
  to get a dom0 prompt per connection; for a machine-to-machine data path that's usually
  impractical.) The grant is still port-scoped TCP, not exec.
- **No sshd means no remote administration — by design, and it costs you.** The service
  qube is administered from the host only: dom0 `qvm-run`, a console, or a
  reviewed-script control-plane flow. If you ever want off-host admin of a Qubes machine,
  that becomes purpose-built territory (management-qube tooling over the Qubes Admin API
  — itself qrexec, not ssh), which you would have to set up deliberately. We run none of
  it; that's a conscious trade of convenience for surface. If your operating model
  genuinely requires remote administration, this pattern will chafe — decide with eyes
  open rather than defaulting into sshd.
- **qrexec adds a hop.** Throughput is fine for request/response workloads (LLM inference
  calls, database queries); if you need line-rate bulk transfer, measure first.

## The recipe

Two gotchas below cost a debugging round each — they're the reason this section exists.

**1. dom0 policy** — one line in `/etc/qubes/policy.d/30-connecttcp.policy` (shown in the
TL;DR). Two things to get right:

- **Explicit destination, not `@default`.** A client that names its target
  (`qrexec-client-vm <service-qube> …`) does **not** match a rule written with `@default`
  + `target=` — the request is refused with no useful hint. Name the destination qube in
  the rule.
- **`autostart=no` unless you truly want boot-on-demand.** qrexec **auto-starts a halted
  target qube** by default. That means an innocent service call can *boot* the service
  qube as a side effect — startling at best, dangerous if the qube is halted for a
  reason (ours once was: a dom0 regression made starting it crash the host). With
  `autostart=no`, a call against a halted qube fails immediately and cleanly. We've
  verified the full degradation live: service qube halted → client's call fails fast →
  client falls back → `qvm-ls` confirms the qube **stayed halted**.

**2. Serving side** — bind the service to `127.0.0.1` only (for ollama that's the
default). Verify: `ss -ltnu` inside the service qube shows only loopback-bound sockets.

**3. Client side** — the qrexec call carries the TCP stream over stdio, so an ordinary
HTTP client can't invoke it directly; something must bridge TCP to `qrexec-client-vm`.
Qubes ships that bridge: `qvm-connect-tcp ::11434` binds `localhost:11434` in the client
qube and forwards over qrexec — sufficient when the consumer runs directly on the client
qube. A **containerized** consumer can't reach the client qube's localhost, though, so it
needs a forwarder bound to an address the container can route to:

```bash
socat TCP-LISTEN:11434,fork,reuseaddr,bind=<local-bind-ip> \
  EXEC:'/usr/bin/qrexec-client-vm <service-qube> qubes.ConnectTCP+11434'
```

Where `<local-bind-ip>` is scoped as tightly as the consumer allows — for a docker-compose
container that's the project's *own* bridge gateway (e.g. `172.20.0.1`; **not** `docker0`,
which inter-bridge isolation blocks), plus an nft `custom-input` accept, plus `rc.local`
persistence.
That fully-worked production case — compose-gateway bind, Qubes firewall rule, reboot
persistence, fallback wiring — is documented in the
[OB1 GPU-offload transport doc](https://github.com/lcjanke2020/ob1-selfhosted/blob/main/deploy/qubes/gpu-offload-transport.md).

## Verification recipe

1. **No-listener check** (service qube): `ss -ltnu` — loopback binds only (UDP included;
   the claim is *no network-facing sockets*, not just no TCP listeners).
2. **Path check** (client qube): `curl http://<local-bind-ip>:11434/v1/models` returns the
   service's response through qrexec.
3. **Negative check** (dom0 + client): halt the service qube, repeat the curl — it must
   fail *fast* (connection closed, not a hang), and `qvm-ls <service-qube>` must still
   show `Halted`. If the qube started, you forgot `autostart=no`.

## Related

- [Passing a Modern NVIDIA GPU Through to a Qubes OS HVM](nvidia-gpu-passthrough.md) —
  the GPU qube this pattern was built around.
- [Locking Down Qube Outbound](tailscale-lan-lockdown.md) — the egress-side counterpart.
- The [`qubes_setup_assistant` skill](skills/qubes_setup_assistant/SKILL.md) — "Choosing a
  control path" weighs ConnectTCP against dom0 dispatch and ssh for *admin* work; this
  guide is the *service-path* case.
