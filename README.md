# qubes-os-explorations
Explorations of the Reasonably Secure Operating System

## Guides

- [Passing a Modern NVIDIA GPU Through to a Qubes OS HVM](nvidia-gpu-passthrough.md) — the offset-4 / Xen-stubdom guard that fixes the "GPU has fallen off the bus" (Xid 79) failure on modern NVIDIA cards, reproduced end-to-end on an RTX 6000 Ada, plus operational notes (rootfs-resize vs `qrexec_timeout`, `/usr/local` on the private volume).
- [Locking Down Qube Outbound: LAN Peers Reachable Only Over the Tailnet](tailscale-lan-lockdown.md) — for app qubes running Tailscale internally: why you **block the LAN subnet** rather than whitelist the `100.x` range (the tunnel is above the firewall), the `qvm-firewall ... --before 0` placement trap that makes a plain drop silently never match, the same-LAN direct→DERP trade-off, and a verification recipe that won't chase ICMP/ACL ghosts.
