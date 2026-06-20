---
name: qubes-setup-assistant
description: Use when working in a Qubes OS environment — running qvm-* commands, administering from dom0, provisioning AppVMs/TemplateVMs, configuring qubes-bind-dirs, qrexec, or qubes-firewall, or troubleshooting issues that span multiple qubes. Captures the non-obvious traps and patterns that distinguish vanilla-Linux instinct from Qubes-correct workflow.
---

# qubes-setup-assistant

Field-tested patterns and traps for Qubes OS provisioning and administration work. Apply these to keep a "review every step" posture intact while removing the friction that turns vanilla-Linux instincts into hours of debugging.

**Scope:** this skill collects broad patterns + traps — not a single linear recipe. They apply whether you're building an agent host, a minimal-surface DB qube, or anything in between. Pair them with whatever phased provisioning procedure you use for a specific qube type.

## Workstation defaults vs. infrastructure defaults — what we're doing differently

Qubes' canonical user is a security-aware human at a workstation: interactive sessions, the human as the actor, "rebuild the qube" as a reasonable recovery. Defaults are tuned for that — most notably *passwordless sudo for the user* (because sudo prompts get trained into click-through-yes habituation in that flow).

A different shape uses Qubes for long-running services, autonomous agents holding shells, no human on the keyboard between admin sessions, `/rw/config` explicitly used for boot-time persistence (bind-dirs, rc.local, firewall scripts). That makes the "VM is the boundary, reboot resets everything, root vs user inside doesn't matter" frame leak: the persistence IS the point, and the human-as-the-only-actor assumption breaks.

The toolkit is right for this; the defaults need conscious re-tuning. This skill captures the re-tuning. None of it is fighting Qubes — all of it uses Qubes-provided mechanisms (`/rw/config`, bind-dirs, qubes-firewall-user-script, sudoers drop-ins, rc.local). Each is reversible.

## Operating principles

1. **The user reviews every script.** That is the Qubes posture — don't try to short-circuit it. Generate small, reviewable chunks. Echo what's about to happen before doing it. Print verification output the user can sanity-check. If your instinct is to bundle five phases into one push-button script, split them.
2. **dom0 is the control plane.** Long sessions of admin work should flow from a single dom0 terminal using `qvm-run --pass-io`. Don't direct the user into VM terminals (small fonts, sudo prompts on templates, paste limits) when dom0 + qvm-run does the same job.
3. **Trust boundaries are real.** TemplateVMs, AppVMs, dom0, sys-firewall, sys-net, DispVMs each have distinct properties. When suggesting a command, name the VM it runs in and *why* that VM.
4. **Push back on convenience-driven decisions that pre-empt architecture decisions.** See "When to push back" section below.

## The control-plane pattern

Run scripts in target VMs from a single dom0 terminal. Two flavors:

**Stream a script from one qube into another (no `qvm-copy` needed):**
```bash
qvm-run --pass-io <source-vm> 'cat /path/to/script.sh' \
  | qvm-run --pass-io --user root <target-vm> 'bash'
```
Output streams back to dom0. No `~/QubesIncoming/` path-tracking, no SRC variable juggling.

**Capture output to a tmpfile then ship to an extraction VM (for secrets / long logs):**
```bash
... | qvm-run --pass-io --user root <target-vm> 'bash' | tee /tmp/out.txt
qvm-run --pass-io <dest-vm> 'cat > /home/user/QubesIncoming/dom0/out.txt' < /tmp/out.txt
# Extract in <dest-vm>, then:
shred -u /tmp/out.txt   # dom0 copy
# and in <dest-vm>:
shred -u /home/user/QubesIncoming/dom0/out.txt
```

### The `qctl` helper — scripted control-plane (agent-driven)

When an **agent in an app qube** is driving the work (it can't reach dom0 at all, and dom0 has no clipboard in or out), wrap the streaming pattern in a tiny dom0 helper so every step is one short, reviewable command and results flow back to the agent automatically. See [`qctl.sh`](qctl.sh) in this skill folder.

Model:
- The agent stages files into `/tmp/qctl/` on its **work qube**: `qctl.sh` itself **once** (so the install one-liner below can pull it), then each `<step>.sh`. Run `mkdir -p /tmp/qctl && chmod 1777 /tmp/qctl` once. The sticky-bit `1777` only makes the *directory* writable across users — it does **not** make the files inside readable across users; that depends on each file's own mode. It works because the default umask (022) writes world-readable `0644` files (and `qctl` chmods the output back `0644` explicitly); under a restrictive agent umask, write `<step>.sh` mode `0644` so dom0's `qvm-run` — running as the qube's *default* user — can read it.
- The human installs `qctl` in dom0 once (pull it, no clipboard needed):
  ```bash
  qvm-run --pass-io <work-qube> 'cat /tmp/qctl/qctl.sh' </dev/null > ~/qctl && chmod +x ~/qctl
  export QCTL_WORK=<work-qube>
  ```
- Thereafter each step is `bash ~/qctl <target-vm|dom0> <step-name>`. `qctl` pulls the script to a **dom0 tmpfile**, runs it from there (staged into a tmpfile inside the target VM and run as root, or directly in dom0 for `dom0`), then streams the combined output back to `/tmp/qctl/<step>.out` on the work qube for the agent to read (dom0 copy kept at `/tmp/qctl-<step>.out`). `qctl` exits with the **step's own status**, so a failed step is detectable rather than silently reported as success.

Why run from a tmpfile, not `… | bash`: a step that contains a heredoc or a nested `qvm-run --pass-io` would otherwise drain the script stream off stdin. `qctl` does this on **both** execution paths — the dom0 path runs `bash <tmpfile>`, and the in-VM path stages the script into a tmpfile inside the target VM (`cat > "$T"; bash "$T"`) rather than `qvm-run … 'bash' < script` — each with the step's own stdin redirected from `/dev/null`. When a step *needs* to feed a script into a nested VM, redirect that nested `qvm-run` from a file/pipe — never from the inherited stdin.

Keep the **review discipline** (Operating principle 1): the agent pastes each `<step>.sh` in chat before the human runs it; scripts stay small and single-purpose; secret-bearing steps print nothing sensitive and shred their copies (Pattern C). This pattern was field-tested driving a database-qube migration end-to-end from an app-qube agent.

## Traps

### Trap 1 — TemplateVMs have no DNS / general outbound

`apt-get update` works (routed through `qubes-updates-proxy` on port 8082), but `curl https://...` fails with "Could not resolve host" — there's no general DNS resolution. Anything that fetches a key, tarball, or installer from the network has to come in via `qvm-copy` from a net-enabled AppVM.

**Check before suggesting a script for a template:** if it does `curl ... | gpg --dearmor`, that won't work. Pre-fetch in an AppVM, `qvm-copy` in, install with `cp` / `install`.

### Trap 2 — TemplateVMs don't have passwordless sudo

`qubes-core-agent-passwordless-root` ships on AppVMs by default, **not** on templates. Don't direct the user to open a template terminal and run `sudo`. Run as root from dom0 instead:
```bash
qvm-run --pass-io --user root <template-vm> 'bash /path/to/script'
```
When you're already root via `--user root`, any `sudo <cmd>` prefix in the script is redundant — the command still executes, but there's no password prompt and no privilege change. `sudo -u <other-user>` semantics are unaffected (still meaningful for user-switching).

### Trap 3 — Clipboard ↔ dom0 is blocked both ways

By design. Both **VM → dom0** and **dom0 → VM** clipboard transfer are blocked.

- **VM → dom0** (paste a script into dom0): pull via `qvm-run --pass-io <vm> 'cat /path' > /tmp/script.sh` instead.
- **dom0 → VM** (extract a password from a script's stdout to a password manager in another qube): redirect into the target VM via stdin:
  ```bash
  qvm-run --pass-io <dest-vm> 'cat > /home/user/QubesIncoming/dom0/x.txt' < /tmp/x.txt
  ```

Never say "copy the output and paste it into your password manager" without acknowledging this trap and giving the workaround.

### Trap 4 — `qubes-bind-dirs` requires BOTH a config file AND a backing dir

The bind silently no-ops if either is missing. Both must exist in `/rw`:

```
/rw/config/qubes-bind-dirs.d/50_<name>.conf             # declares paths
/rw/bind-dirs/var/lib/<service>                          # backing dir for /var/lib/<service> (mirror the absolute path WITHOUT the leading /)
/rw/bind-dirs/etc/<service>                              # backing dir for /etc/<service>, same rule
```

Config syntax (bash array append; `qubes-bind-dirs.sh` sources it):
```bash
binds+=( "/var/lib/postgresql" )
binds+=( "/etc/postgresql" )
```

Create the backing dir with the ownership/perms the service expects *before* the AppVM reboot that activates the bind. `qubes-bind-dirs.sh` seeds the backing dir from the template's path on first boot if it's empty.

### Trap 5 — Persisting `/etc/<service>` matters as much as `/var/lib/<service>`

Common mistake: bind-dir only the data path (`/var/lib/postgresql`) and forget the config path (`/etc/postgresql`). Result: edits to `pg_hba.conf` / `postgresql.conf` silently reset on every reboot. **No error, just lost security posture.**

If you intend the user to modify any config under `/etc/<service>` in an AppVM, bind-dir the whole config dir too. Verify after reboot with `findmnt <path>`.

### Trap 6 — Debian minimal templates ship `LANG=en_US.UTF-8` but don't generate it

Perl scripts (`pg_createcluster` and friends) bail with `Error: The locale requested by the environment is invalid: LANG: en_US.UTF-8`. `locale-gen` was never run for that locale.

**Fix:** install `locales-all` in the template (one apt-get, ~12 MB, generates every locale at install time). Recommended default for any minimal-template-based qube that runs Perl- or locale-sensitive tools.

### Trap 7 — Template edits don't reach AppVMs until BOTH the template shuts down AND the AppVM next boots

Sequence after editing a template:
```bash
qvm-shutdown --wait <template>        # template must be off
qvm-shutdown --wait <appvm> && qvm-start <appvm>   # appvm picks up the new snapshot
```

If a template change "isn't taking" in an AppVM, this is almost always why.

## Patterns

### Pattern A — Clone the template before installing service-specific software

If the target template is shared (`debian-13-minimal`, `fedora-minimal`), **clone it** before adding service binaries:
```bash
qvm-clone debian-13-minimal debian-13-postgres
```
Otherwise every AppVM off the shared template inherits the service binaries and config — surface you didn't intend.

### Pattern B — Initialize service state in the AppVM, not the template

For services like Postgres where package install creates an empty state dir: drop the auto-created state in the template (`pg_dropcluster --stop 17 main`) and let the AppVM run the fresh init (`pg_createcluster ...`) after bind-dirs are active. Empty `/etc/<service>` and `/var/lib/<service>` become the AppVM's bind sources.

### Pattern C — Secrets generated in the target VM, extracted via ship-to-trusted-VM

When a script must generate a secret (random password, key) inside a target qube and surface it for the user to store:
1. Generate inside the target. Don't pass secrets across qrexec on the command line.
2. Stream output to dom0 via `qvm-run --pass-io | tee /tmp/x.txt`.
3. Ship `/tmp/x.txt` to a trusted extraction VM via redirect-into-qvm-run (see Trap 3 workaround).
4. Extract there into the password manager.
5. `shred -u` both copies.

### Pattern D — Build-time firewall ≠ steady-state firewall

For any AppVM that needs net only for installation: open a narrow allowlist (mirror hostnames only) + drop, do the install, then `qvm-firewall reset` + `add --action=drop` for steady state. Don't leave the install-time allowlist behind.

### Pattern E — When troubleshooting "did the script actually take," verify state directly

Before re-running, check whether the failed step left partial state. Useful one-liners:

```bash
# config file landed?
qvm-run --pass-io <vm> 'cat /rw/config/qubes-bind-dirs.d/50_x.conf 2>&1'

# backing dir present?
qvm-run --pass-io <vm> 'ls -la /rw/bind-dirs/'

# binds active after boot?
qvm-run --pass-io <vm> 'findmnt /var/lib/<service>; findmnt /etc/<service>'

# fresh boot vs stale?
qvm-run --pass-io <vm> 'uptime'
```

Pasting state output beats guessing about idempotency.

### Pattern F — Sudo password on any AppVM holding non-trivial value

Default is passwordless sudo (`qubes-core-agent-passwordless-root`). Re-enable a password for any AppVM that:

- Holds data worth defending past the current session (DBs, keys, secrets store), **OR**
- Has agents / autonomous processes that hold a shell inside it, **OR**
- Has any inbound shell vector (SSH, even VPN/tailnet-scoped).

Why this matters even on a qube with no remote shell vector: in-qube `user`-shell compromise + sudo escalation enables persistent backdoors via `/rw/config/rc.local` and `qubes-firewall-user-script`, direct PGDATA reads (bypassing Postgres auth), pg_hba.conf rewrites, and LAN-pivot raw-socket primitives. Without sudo, the same compromise is bounded to the current session and the user-readable surface — a real boundary, not security theater.

Procedure (sketch): set a password for `user` and remove the passwordless grant — either delete/override the drop-in that `qubes-core-agent-passwordless-root` installs, or add your own `/etc/sudoers.d/` drop-in requiring authentication for `user`. **Both** halves live under `/etc`, which is reset from the template on every AppVM boot: the password hash in `/etc/shadow` *and* the sudoers drop-in in `/etc/sudoers.d/`. Neither persists by default — a common trap is to set the password, reboot, and find it gone. Make them stick by one of: setting the password in the **template** (AppVMs then inherit `/etc/shadow`), re-applying on each boot from `/rw/config/rc.local` (e.g. `chpasswd` from a stored hash + re-dropping the sudoers file), or bind-dir'ing the relevant `/etc` paths. Steps are the same whether the value being defended is "agent has the shell" or "DB has the data." Compatible with `qvm-run --user root` from dom0 (which bypasses sudo entirely — daily admin flow unchanged).

**Don't skip this on the reasoning "but it has no network listener."** Defense in depth here is about *what an in-qube escalation gets you*, not the probability of getting in.

## When to push back on the user

These are the convenience-driven calls that quietly undo architecture decisions. Don't refuse — surface the tradeoff and let the user decide:

- **"Let's install a VPN/Tailscale on the DB qube for SSH access."** This pre-empts qrexec-vs-tailnet transport decisions for the app→DB path. Ask whether that decision has been made deliberately. If interactive admin from another qube on the same host is the actual goal, `qvm-run --auto <vm> xterm` gives the ergonomics without the listener (`--auto` auto-starts the qube if not running; the short form `-a` is the same flag but less self-evident in docs).
- **"Just open port 22 on the AppVM for now, we'll harden later."** Harden-later doesn't tend to happen. Suggest the xterm-via-qvm-run path instead.
- **"Can you just automate the whole provisioning?"** Suggest chunked scripts the user can review between phases. Echo what's about to happen at each phase. Print verification output. Build-in idempotency at chunk boundaries, not "atomic-or-bust" macros.
- **"Use the shared template, save disk."** If the service you're installing isn't already intended for that template, clone first. Disk is cheap; surface from leaking service binaries into unrelated AppVMs isn't.
- **"Add a `host` line to pg_hba.conf temporarily for debugging."** TCP listeners on AppVMs that were scoped to Unix-socket-only are how the security posture slips away one debug session at a time. Suggest `qvm-run -u root <vm> 'sudo -u postgres psql ...'` instead.

## Final note on automation

Build helper scripts that *support* the user as a step-by-step reviewer — not scripts that take the user out of the loop. The Qubes audience trusts what they can audit; design for that. If a script's behavior isn't visible from reading it in 30 seconds, split it.

When you're about to write a 200-line "do everything" script, ask: would the user be happier with this as five 40-line scripts they can run in sequence, each with an `echo` of what it's about to do?
