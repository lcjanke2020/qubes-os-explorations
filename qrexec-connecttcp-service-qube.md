# Serving From a Qube With Zero Inbound Surface: qrexec `ConnectTCP` Instead of sshd

*A field guide for consuming a service from a qube that has **no inbound network
listener at all** — the service binds to `127.0.0.1` and stays there. Other qubes reach
it over Qubes' own RPC (`qubes.ConnectTCP`), gated by a one-line dom0 policy. Worked
end-to-end on Qubes OS 4.x with an LLM server (ollama, port `11434`) on a GPU-passthrough
HVM, consumed by an app qube; the pattern is service-agnostic — substitute your port.*

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
service qube's **loopback** port — and nothing else. The service qube's inbound surface
is zero: no open ports other than loopback-bound ones, no key material, no admin channel
riding along with the service path.

Our reference GPU qube has **never had sshd installed or enabled at any point in its
life**. Not "locked down later," not "temporarily open during the migration" — never
present. That is the posture this pattern makes practical.

## Why you'd want this

The vanilla-Linux reflex for "qube B needs to talk to qube A's service" is to make the
service reachable: bind it to the LAN or tailnet address, or install sshd for tunnels and
admin while you're at it. Every one of those is a standing listener — surface that exists
around the clock so that a request can arrive occasionally.

`qubes.ConnectTCP` inverts that:

- **Zero listeners on the service qube.** The service binds `127.0.0.1` only. Verify with
  `ss -ltn` — every socket should show a loopback address. There is nothing for a network
  scanner (or a compromised LAN/tailnet peer) to even connect to.
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
way: the more a qube touches, the stronger the case for keeping its inbound surface at
zero. With this pattern the GPU qube serves a multi-gigabyte model to another qube while
exposing **no port beyond loopback**.

## The honest tradeoffs

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
default). Verify: `ss -ltn` inside the service qube shows only loopback listeners.

**3. Client side** — a process that can exec `qrexec-client-vm` can connect directly. A
consumer that can't (a container, a runtime that only speaks TCP) needs a small host-side
forwarder in the client qube:

```bash
socat TCP-LISTEN:11434,fork,reuseaddr,bind=<local-bind-ip> \
  EXEC:'/usr/bin/qrexec-client-vm <service-qube> qubes.ConnectTCP+11434'
```

Where `<local-bind-ip>` is scoped as tightly as the consumer allows — for a docker-compose
container that's the project's own bridge gateway (**not** `docker0`; inter-bridge
isolation blocks that), plus an nft `custom-input` accept, plus `rc.local` persistence.
That fully-worked production case — compose-gateway bind, Qubes firewall rule, reboot
persistence, fallback wiring — is documented in the
[OB1 GPU-offload transport doc](https://github.com/lcjanke2020/ob1-selfhosted/blob/main/deploy/qubes/gpu-offload-transport.md).

## Verification recipe

1. **Zero-listener check** (service qube): `ss -ltn` — loopback binds only.
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
