# qubes-os-explorations
Explorations of the Reasonably Secure Operating System

## Agent skill

- [`qubes-setup-assistant`](skills/qubes-setup-assistant/SKILL.md) — the traps and patterns from
  these explorations (dom0 as control plane, bind-dirs persistence, template/AppVM sequencing,
  firewall-rule placement, when to push back on convenience) distilled into a loadable
  [Agent Skill](https://agentskills.io), so a coding agent helps configure Qubes without walking
  into them. Ships with `qctl.sh`, a dom0 dispatcher that turns each agent-authored step into one
  short, reviewable command whose output flows back to the agent's qube automatically.

## Guides

- [Passing a Modern NVIDIA GPU Through to a Qubes OS HVM](nvidia-gpu-passthrough.md) — the offset-4 / Xen-stubdom guard that fixes the "GPU has fallen off the bus" (Xid 79) failure on modern NVIDIA cards, reproduced end-to-end on an RTX 6000 Ada, plus operational notes (rootfs-resize vs `qrexec_timeout`, `/usr/local` on the private volume).
- [Locking Down Qube Outbound: LAN Peers Reachable Only Over the Tailnet](tailscale-lan-lockdown.md) — for app qubes running Tailscale internally: why you **block the LAN subnet** rather than whitelist the `100.x` range (the tunnel is above the firewall), the `qvm-firewall ... --before 0` placement trap that makes a plain drop silently never match, the same-LAN direct→DERP trade-off, and a verification recipe that won't chase ICMP/ACL ghosts.
- [Serving From a Qube With No Network-Facing Listener: qrexec `ConnectTCP` Instead of sshd](qrexec-connecttcp-service-qube.md) — consume a loopback-only service (worked example: an LLM server on a GPU-passthrough HVM) from another qube via a one-line dom0 policy — no sshd, no LAN/tailnet bind, ever. Covers the explicit-destination and `autostart=no` gotchas, why a passthrough qube especially should stay listener-free, and the honest cost: remote administration then needs purpose-built tooling you may deliberately choose not to run.
