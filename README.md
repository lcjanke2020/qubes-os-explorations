# qubes-os-explorations
Explorations of the Reasonably Secure Operating System

## Guides

- [Passing a Modern NVIDIA GPU Through to a Qubes OS HVM](nvidia-gpu-passthrough.md) — the offset-4 / Xen-stubdom guard that fixes the "GPU has fallen off the bus" (Xid 79) failure on modern NVIDIA cards, reproduced end-to-end on an RTX 6000 Ada, plus operational notes (rootfs-resize vs `qrexec_timeout`, `/usr/local` on the private volume).
