# Passing a Modern NVIDIA GPU Through to a Qubes OS HVM

*A field guide built from a real RTX 6000 Ada (48 GB) passthrough on Qubes OS / Debian 13, including the root cause of the notorious "GPU has fallen off the bus" failure that affects current NVIDIA cards under Xen — and the one-line fix.*

---

## TL;DR — the headline finding

On current Qubes OS (Xen 4.x stubdomain), a modern NVIDIA card attached to an HVM will enumerate, read its UUID/serial, then **~1 minute into driver init throw `Xid 79 — GPU has fallen off the bus`** and die — repeatably, surviving every BIOS tweak, reseat, and power check you throw at it.

It is **not** a hardware, BIOS, BAR-overlap, power, or seating fault.

It is the Xen MSI-X stubdomain rejecting the NVIDIA driver's write to **PCI config offset 4 (the Command register)**. The driver mishandles the rejection and reports the GPU as lost. A **single guard in the open-driver source** (`os-pci.c`) that declines the offset-4 write fixes it permanently.

If you only read one section, read [§6 The Fix](#6-the-fix--the-offset-4-guard).

Credit for the original diagnosis goes to **neowutran** — see <https://neowutran.ovh/qubes/articles/nvidia.html>. This guide reproduces the working path end-to-end and confirms the fix now applies to the **open** driver (610.x), which historically did not need it.

---

## 0. Tested configuration

| Component | Value |
|---|---|
| Host board | ASUS ROG Crosshair X870E (AMD X870E, AM5) |
| Passthrough GPU | NVIDIA RTX 6000 Ada Generation (AD102GL, 48 GB) |
| dom0 display GPU | AMD iGPU (Granite Ridge) |
| Hypervisor | Qubes OS 4.x / Xen |
| Guest | Debian 13 (Trixie), StandaloneVM, HVM |
| Driver | `nvidia-open` 610.43.02 (NVIDIA CUDA repo for debian13) |

The approach generalizes to any recent NVIDIA card (40-/50-series, Ada/Blackwell workstation parts) that exhibits the `Xid 79` fall-off under Qubes.

---

## 1. BIOS settings

None of these turned out to be the cause of the fall-off, but they are correct hygiene for passthrough and remove confounding variables while debugging:

- **IOMMU** → Enabled
- **SVM / virtualization** → Enabled
- **Above 4G Decoding** → Enabled
- **Re-Size BAR Support** → **Disabled** (verify the card's VRAM BAR reads its small default aperture, e.g. 256 MB, not the full 48 GB)
- **Integrated graphics** → force on / set as primary display, so dom0 drives the iGPU and leaves the NVIDIA card free
- **ASPM** (CPU PCIE ASPM, Native ASPM, ASPM Support) → Disabled
- **Clock Spread Spectrum** → Disabled

Also: physically reseat the card and confirm the 12VHPWR / 16-pin connector is fully seated. (Worth doing once to rule it out — but per the headline, it won't be your problem here.)

---

## 2. Verify IOMMU isolation and topology

**Important Qubes/Xen note:** `/sys/kernel/iommu_groups/` is **empty** on Qubes because Xen owns the IOMMU, not the Linux kernel. Don't panic — use Xen and `lspci` tools instead.

Confirm the IOMMU is on:

```bash
sudo xl dmesg | grep -i AMD-Vi      # "AMD-Vi: IOMMU 0 Enabled" — the 0 is an index, not an error
```

Inspect the topology and confirm the GPU sits on its own root port, cleanly isolated from other devices (no shared bridge with NICs, NVMe, USB, etc.):

```bash
lspci -tv
```

Identify the device IDs Qubes uses. Qubes 4.2 uses **hierarchical path notation**, not bare BDF:

```bash
qvm-pci    # or: qvm-pci ls
```

For our card the GPU and its HD-audio function showed up as:

```
dom0:00_01.1-00_00.0   # VGA (BDF 01:00.0)
dom0:00_01.1-00_00.1   # HD audio (BDF 01:00.1)
```

Your hierarchical paths and BDFs will differ; use the output of `qvm-pci` on your system.

If the GPU shares an IOMMU group with unrelated devices, you may need an ACS override — but a card on a dedicated CPU root port usually does not.

---

## 3. Hide the GPU from dom0

Add the GPU's **BDF** addresses to the dom0 kernel command line so `pciback` claims them at boot:

```bash
# /etc/default/grub  →  append to GRUB_CMDLINE_LINUX:
rd.qubes.hide_pci=01:00.0,01:00.1

sudo grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg
sudo reboot
```

After reboot, confirm both functions are held by pciback:

```bash
lspci -nnk -s 01:00.0   # "Kernel driver in use: pciback"
lspci -nnk -s 01:00.1
```

---

## 4. Build the qube

A **StandaloneVM** keeps the driver and the patch self-contained (apt/dkms changes persist without a template). Create it from your Debian 13 template (Qube Manager → New Qube → *Standalone copied from a template*), then set the passthrough properties:

```bash
qvm-prefs sys-gpu virt_mode hvm
qvm-prefs sys-gpu kernel ''        # qube boots its own in-VM kernel — critical for dkms to build the right module
qvm-prefs sys-gpu memory 3400      # deliberately under the ~3584 MB ceiling (see §10)
qvm-prefs sys-gpu maxmem 0         # disable ballooning
qvm-prefs sys-gpu qrexec_timeout 1200   # generous cushion (see §8)
```

> **Build the whole thing with NO GPU attached.** Install and patch the driver first; attach the card only at the very end (§7). This avoids the boot-wedge trap entirely (§8).

---

## 5. Install the NVIDIA open driver

Boot the (GPU-less) qube, then inside it:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install linux-headers-$(uname -r)   # so dkms has headers

# NVIDIA CUDA repo for Debian 13
wget https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install nvidia-open
```

This builds the **unpatched** module via dkms. That's expected — we patch and rebuild next.

> **dkms PATH gotcha:** the `dkms` binary lives in `/usr/sbin`, which isn't in a normal user's `$PATH` on Debian. `dkms status` → "command not found" even though it's installed. Run it through `sudo` (which includes sbin): `sudo dkms status`.

Confirm the module name/version:

```bash
sudo dkms status
# nvidia/610.43.02, <kernel>, x86_64: installed
```

---

## 6. The Fix — the offset-4 guard

This is the whole ballgame.

**Why it crashes:** During init the NVIDIA driver writes to PCI config **offset 4** (the Command register) via `os_pci_write_dword`. The Xen MSI-X stubdomain patch ("Save back data only for declared registers") rejects writes to undeclared registers, including offset 4. The driver doesn't handle the rejection and reports `Xid 79 / NV_ERR_GPU_IS_LOST` — "fallen off the bus." Historically only the *proprietary* driver made this write; **nvidia-open 610 has regressed into making it too**, so the open driver now needs the same fix.

> **Scope warning:** only apply this guard in a Qubes/Xen PCI-passthrough qube. Skipping the Command-register write on bare metal or another hypervisor would prevent the driver from enabling memory/IO/bus-master decoding via config space.

Find the source file:

```bash
find /usr/src/ /var/lib/dkms -iname 'os-pci.c' 2>/dev/null
# /usr/src/nvidia-610.43.02/kernel-open/nvidia/os-pci.c
```

Edit `os_pci_write_dword` so it declines the offset-4 write. The function returns `NV_STATUS`, so returning `NV_ERR_NOT_SUPPORTED` is valid (it mirrors the existing `NV_PCIE_CFG_MAX_OFFSET` guard right above it):

```diff
     if (offset >= NV_PCIE_CFG_MAX_OFFSET)
         return NV_ERR_NOT_SUPPORTED;

+    /* Xen stubdom rejects writes to the PCI Command register (offset 4);
+     * issuing it makes the GPU fall off the bus under passthrough. Decline it. */
+    if (offset == 4)
+        return NV_ERR_NOT_SUPPORTED;
+
     pci_write_config_dword( (struct pci_dev *) handle, offset, value);
     return NV_OK;
```

Rebuild and install the patched module for the running kernel:

```bash
sudo dkms build  nvidia/610.43.02 -k "$(uname -r)" --force
sudo dkms install nvidia/610.43.02 -k "$(uname -r)" --force
```

> **Two-kernel note:** `dkms status` may show the module built for more than one kernel (e.g. a Debian kernel and a Qubes kernel). `$(uname -r)` targets the one you're actually running, which is what boots a `kernel ''` HVM. If a reboot ever lands on the other kernel, rebuild for that string too.

---

## 7. Attach the GPU and verify

Shut the qube down, attach both functions **persistently** with `no-strict-reset` (modern NVIDIA cards don't reset cleanly), and boot:

```bash
# inside the qube:
sudo poweroff

# from dom0:
qvm-pci attach --persistent -o no-strict-reset=true sys-gpu dom0:00_01.1-00_00.0
qvm-pci attach --persistent -o no-strict-reset=true sys-gpu dom0:00_01.1-00_00.1
qvm-start sys-gpu
```

Inside the qube:

```bash
nvidia-smi
```

Success looks like the card listed at full VRAM, idle at P8, **and holding past the one-minute mark** instead of throwing `Xid 79`:

```
NVIDIA RTX 6000 Ada Generation   46068MiB   P8   13W / 300W   0%
```

---

## 8. Debugging gotchas (the stuff that costs hours)

- **You do not need a working GPU to patch the driver.** Building the module is a pure compile against kernel headers. Do all driver work with the card detached, attach last.
- **The "Transient" / qrexec trap.** If you boot with the GPU attached and an *unpatched* driver, the driver hangs init for ~50 s before the card falls off, which blows past the default 60 s qrexec timeout. The qube sits in **Transient** state — and you **cannot open a terminal** in a Transient qube. Raising `qrexec_timeout` doesn't help if the wedged init means qrexec never connects. Conclusion: patch first, attach last.
- **`qvm-pci detach` says "not attached" on a halted qube.** On a stopped qube the device is *assigned* (persistent), not *attached*; `detach` operates on live attachments. Also watch BDF (`01_00.0`) vs hierarchical (`00_01.1-00_00.0`) notation mismatches.
- **Last-resort way to free a stuck assignment:** `qvm-remove`-ing the qube releases its device assignments back to the free pool, but it also **deletes the qube and its data**. Back up anything important first; only use this if normal detach/reattach fails.
- **A wedged GPU can block domain start.** If a qube won't start because the card is in a fallen-off state, reboot dom0 to cold-reset it. After a hard kill you may also see stale `vm-*-volatile` LVs; these can be removed with `sudo lvremove -f qubes_dom0/vm-<name>-volatile`, but that is a **destructive dom0 command** — use it only as a last resort.
- **`/sys/kernel/iommu_groups` is empty on Qubes.** Xen owns the IOMMU; use `lspci -tv` and `qvm-pci`.
- **Secure Boot / module signing.** If the HVM has UEFI Secure Boot enabled, the rebuilt `nvidia` module will be rejected as unsigned. Either disable Secure Boot for the qube or sign the module with a key enrolled in the VM's MOK.

---

## 9. Maintenance

The fix patches **driver source**, so it must be re-applied and rebuilt on every driver update. Wrap it in a script:

```bash
#!/bin/bash
set -e
SRC=$(find /usr/src -iname os-pci.c -path '*kernel-open*' | head -1)
MOD=$(sudo dkms status | sed -n 's/^\(nvidia\/[0-9.]*\),.*/\1/p' | head -1)

if ! grep -q 'if (offset == 4)' "$SRC"; then
    sudo sed -i \
      's/\(\s*\)\(pci_write_config_dword(\)/\1if (offset == 4)\n\1    return NV_ERR_NOT_SUPPORTED;\n\1\2/' "$SRC"
fi

# Fail loudly if the patch landed in zero or multiple places
count=$(grep -c 'if (offset == 4)' "$SRC")
if [ "$count" -ne 1 ]; then
    echo "ERROR: found $count occurrences of the offset-4 guard; expected exactly 1." >&2
    echo "Revert $SRC and inspect it before rebuilding." >&2
    exit 1
fi

sudo dkms build  "$MOD" -k "$(uname -r)" --force
sudo dkms install "$MOD" -k "$(uname -r)" --force
```

(Always eyeball `os-pci.c` after an auto-patch before trusting it.)

---

## 10. Known remaining limits

- **~3.5 GB RAM ceiling for passthrough HVMs.** Assigning more than ~3584 MB to a GPU-passthrough qube triggers its own failure; raising it requires the stubdom `max-ram-below-4g` patch (qubes-issues #4321 / #8783). **Caveat:** that patch matches on qube name with a `gpu_*`-style pattern — a qube named `sys-gpu` won't match as-is, so either rename the qube or adjust the name check in the patch.
- **The patched driver is non-upstream**, so factor the re-patch step (§9) into your update routine.

---

## Credits

- **neowutran** — original reverse-engineering of the offset-4 / Xen-stubdom interaction: <https://neowutran.ovh/qubes/articles/nvidia.html>
- Qubes issue trackers: qubes-issues **#8783**, **#10036**, **#4321**, **#8631**; NVIDIA/open-gpu-kernel-modules **#915**.

---

## 11. Operational notes — running a GPU compute workload in the qube

Two traps surfaced *after* the card was stable, while standing up a GPU-served LLM (ollama + a ~19 GB model) inside the qube. Both masquerade as a GPU or qrexec failure but are really storage / boot-timing issues.

### Growing the qube's root volume → slow first boot → *false* qrexec timeout

After `qvm-volume resize <gpu-qube>:root <big>GiB` (to make room for model files on `/`), the **next** boot runs `qubes-rootfs-resize.service` to grow the in-VM filesystem — and on a large grow that can take a couple of **minutes**. The default `qrexec_timeout` is **60 s**, so `qvm-start` gives up with `Cannot connect to qrexec agent for 60 seconds` and `qvm-run` times out, even though the boot is healthy and finishes the resize moments later. The tell is the guest console (`/var/log/xen/console/guest-<qube>.log`) sitting on:

```
Job qubes-rootfs-resize.service/start running (NNs / no limit)
```

Fix: raise it before a big resize — `qvm-prefs <gpu-qube> qrexec_timeout 600`. One-time cost; later boots skip the resize and qrexec returns in seconds.

### `/usr/local` is on the small *private* volume — installers run out of space

Many installers (the ollama install script among them) drop their files in `/usr/local`. In Qubes that path is **bind-mounted from `/rw/usrlocal` on the private volume (`xvdb`)**, which defaults to ~2 GB — **not** the root volume you may have just grown to hundreds of GB. So you get `tar: … No space left on device` extracting a few-GB bundle while `df /` shows 200+ GB free — thoroughly confusing. (`/tmp` is a small tmpfs too, but it's a red herring here — the target is `/usr/local`.) Confirm with `df -h /usr/local` and `findmnt /usr/local`.

Two clean fixes:

- **Grow the private volume** (keeps the conventional `/usr/local`, so upgrades keep working):
  ```bash
  qvm-volume resize <gpu-qube>:private <N>GiB     # in dom0
  sudo resize2fs /dev/xvdb                         # online-grow, inside the qube
  ```
- **Install onto the root volume instead** — good for a StandaloneVM (its root is large and persistent). Point the installer at `/usr` rather than `/usr/local`. For the ollama script, trimming `/usr/local/bin` out of its `PATH` probe does it:
  ```bash
  sudo env PATH=/usr/bin:/bin:/sbin bash install.sh   # → /usr/bin/ollama + /usr/lib/ollama
  ```
  (A later `curl | sh` upgrade defaults back to `/usr/local`, so re-apply the trick or grow the private volume.)

Keep large model files off the private volume too — e.g. ollama stores models under the service user's home (`/usr/share/ollama/.ollama/models`), which is on root.
