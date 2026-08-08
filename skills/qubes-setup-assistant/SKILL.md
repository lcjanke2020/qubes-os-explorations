---
name: qubes-setup-assistant
description: Use when working in a Qubes OS environment — running qvm-* commands, administering from dom0, provisioning AppVMs/TemplateVMs, configuring qubes-bind-dirs, qrexec, or qubes-firewall, or troubleshooting issues that span multiple qubes. Captures the non-obvious traps and patterns that distinguish vanilla-Linux instinct from Qubes-correct workflow.
---

# qubes-setup-assistant

Field-tested patterns and traps for Qubes OS provisioning and administration work. Apply these to keep a "review every step" posture intact while removing the friction that turns vanilla-Linux instincts into hours of debugging.

**Scope:** this skill collects broad patterns + traps — not a single linear recipe. They apply whether you're building an agent host, a minimal-surface DB qube, or anything in between. Pair them with whatever phased provisioning procedure you use for a specific qube type.

## Choosing a control path (read this first)

This skill is one of several ways to get admin work done on a qube. Which is right depends on the work at hand — and on how much agent involvement your threat model tolerates. The honest comparison:

**Typing commands directly** (dom0 terminal, or a terminal in the target qube). The baseline Qubes posture, and the right call for short commands — `qvm-prefs`, a one-line firewall rule, a package query. Zero agent exposure. The honest cost: humans typo, and the longer the command, the worse the odds — a mistyped multi-line config edit can wreck a service as surely as a wrong script. Keeping dom0 input to short commands is the ideal; complex work is exactly where hand-typing breaks down, and it's what pushes people toward scripted help in the first place.

**This skill** (agent drafts → human reviews → human dispatches via `qctl` from dom0). No new listeners, no open ports, no credentials added to any qube. dom0 stays the human choke point: every step is a small reviewable artifact the human runs deliberately, with output captured for the agent. The risks, stated plainly: an agent can generate a wrong-but-plausible script, and reviewing step 14 of 20 tests anyone's attention — review habituation is real. The target guard (below) removes the wrong-qube dispatch failure class; it does nothing about wrong *content*. That's what the review discipline — small single-purpose steps, echo-before-do — is for.

**SSH into the target qube** (agent works over ssh from its own qube). Where SSH access already exists — or the qube is one you've deliberately decided should have it — prefer it. Standard tooling, fully interactive, dom0 out of the workflow entirely. The costs: an sshd running on the qube, an open port (even tailnet- or LAN-scoped), key material to manage, and teardown that reliably never happens ("we'll close it after the migration"). Every listener is surface, and standing surface runs against the Qubes minimal-surface grain. **This skill's actual niche is qubes you deliberately keep SSH-free** — don't reach for it as a lazy substitute on qubes that have, or should have, SSH.

**qrexec direct exec — no sshd, no open port, ever.** Qubes' own inter-qube RPC can give an agent qube a path into a target qube with no network listener at all: `qubes.ConnectTCP` forwards a TCP port qube-to-qube over qrexec (to reach a service bound to localhost on the target), and a VMShell-style qrexec service provides command execution the same way. Both are gated by explicit dom0 policy, scoped per source→target pair, and the policy can be set to `ask` so every invocation raises a dom0 prompt. Setup is a few short dom0 policy lines — the good kind of dom0 typing. The tradeoff, stated honestly: an `allow` policy grants the agent *standing* exec rights on the target — you've traded per-step human review for a one-time channel approval. `ask` restores a per-call human decision, but the prompt shows the channel, not the command about to run.

There is no universally right choice among those four paths; it's the user's risk decision, made per qube. The job of this skill is to make the tradeoffs visible, not to make the choice.

**One position worth naming outright:** some Qubes users will conclude that no LLM should control — or even draft commands for — any part of their Qubes installation. Given what Qubes is for, that can be a perfectly sound assessment of their own situation, and nothing in this skill argues with it. Everything here is for users who have consciously decided otherwise and want the residual risk structured, reviewable, and minimized.

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
- Every step opens with the **target-guard preamble** and its `QCTL_TARGET=` declaration (see "Target guard" below). `qctl` hard-refuses to dispatch a step whose declaration is missing, malformed, or doesn't match the CLI target (exit 5) — undeclared steps don't run, period.

Why run from a tmpfile, not `… | bash`: a step that contains a heredoc or a nested `qvm-run --pass-io` would otherwise drain the script stream off stdin. `qctl` does this on **both** execution paths — the dom0 path runs `bash <tmpfile>`, and the in-VM path stages the script into a tmpfile inside the target VM (`cat > "$T"; bash "$T"`) rather than `qvm-run … 'bash' < script` — each with the step's own stdin redirected from `/dev/null`. When a step *needs* to feed a script into a nested VM, redirect that nested `qvm-run` from a file/pipe — never from the inherited stdin.

Keep the **review discipline** (Operating principle 1): the agent pastes each `<step>.sh` in chat before the human runs it; scripts stay small and single-purpose; secret-bearing steps print nothing sensitive and shred their copies (Pattern C). This pattern was field-tested driving a database-qube migration end-to-end from an app-qube agent.

### Target guard — making sure a step runs where it was meant to

A step written for one qube and dispatched to another is the nastiest failure mode of this pattern: `bash ~/qctl <wrong-qube> app-cutover` happily tears down services on the wrong qube if nothing checks. Two layers close it:

**Layer 1 — qctl refuses bad dispatch (exit 5).** Every step declares its target as the **first executable line** of the file — shebang, comments, and blank lines may precede it, code may not:

```bash
QCTL_TARGET=<target-vm>    # or: dom0 | generic
```

`qctl` hard-refuses to dispatch when the declaration is missing, not in first position, duplicated, malformed, or doesn't match the `<target-vm>` CLI argument. The target is thereby stated twice — in the reviewed script and on the command line — and the two must agree, so a typo in either place stops the run before anything executes. The rules are deliberately rigid, because a guard that "repairs" its input can be repaired into the wrong answer: exactly **one** line beginning with `QCTL_TARGET=` in the whole file (shell honors a *later* reassignment, so a duplicate means dispatch could validate one value while the runtime guard sees another); the value is a **bare token** — no quotes, no embedded whitespace; and first-position means a declaration buried mid-file (after side effects) never passes. A trailing comment is allowed only in the form the shell itself treats as one — whitespace before the `#` (`QCTL_TARGET=web # prod` is fine; `QCTL_TARGET=web#bad` assigns `web#bad` at runtime, so qctl refuses it as malformed rather than "helpfully" reading it as `web`). The exactly-one count is a line-start scan, not a shell parse, so heredoc payload counts too — fail-closed by design. A step that legitimately needs to *emit* a declaration (this skill generates steps, after all) should assemble the token instead of writing it literally, e.g. `printf 'QCTL_%s=%s\n' TARGET "$T"`. `generic` steps (safe on any app qube: recon, `uptime`, disk checks) skip the name match but are refused on infrastructure qubes — TemplateVMs, `sys-*`, and net-providing qubes (checked in dom0 via `qvm-prefs`). Declaring an infrastructure qube *explicitly* is allowed — template work is a normal part of this skill — but qctl announces it with an `INFRA TARGET` banner before running.

**Layer 2 — the step guards itself (exit 9).** The same `QCTL_TARGET` line feeds a short runtime preamble, so the script is self-defending even outside qctl (bare `qvm-run`, copied elsewhere, some future flow). The canonical preamble — emit it at the top of **every** generated step:

```bash
# --- target guard ---
QCTL_TARGET=<target-vm>            # or: dom0 | generic
if [ "$QCTL_TARGET" = "dom0" ]; then
  [ ! -f /usr/share/qubes/marker-vm ] || { echo "[guard] expected dom0, found a VM — aborting"; exit 9; }
else
  [ -f /usr/share/qubes/marker-vm ] || { echo "[guard] not inside a Qubes VM — aborting"; exit 9; }
  command -v qubesdb-read >/dev/null || { echo "[guard] qubesdb-read missing — aborting"; exit 9; }
  SELF="$(qubesdb-read /name 2>/dev/null)"
  TYPE="$(qubesdb-read /qubes-vm-type 2>/dev/null)"
  { [ -n "$SELF" ] && [ -n "$TYPE" ]; } || { echo "[guard] cannot read qube identity from qubesdb — aborting"; exit 9; }
  if [ "$QCTL_TARGET" = "generic" ]; then
    case "$SELF" in sys-*) echo "[guard] generic step on infrastructure qube '$SELF' — aborting"; exit 9;; esac
    [ "$TYPE" != "TemplateVM" ] || { echo "[guard] generic step on a TemplateVM — aborting"; exit 9; }
  else
    [ "$SELF" = "$QCTL_TARGET" ] || { echo "[guard] running on '$SELF', expected '$QCTL_TARGET' — aborting"; exit 9; }
  fi
fi
# --- end guard ---
```

Facts the guard relies on (verified on Qubes 4.3): `qubesdb-read /name` returns the qube's own name from inside any VM; `qubesdb-read /qubes-vm-type` returns `AppVM`/`TemplateVM`/`StandaloneVM`/`DispVM`; `/usr/share/qubes/marker-vm` exists in every VM and never in dom0. If qubesdb answers empty (service trouble), the guard aborts rather than classifying blind.

**The two layers are not equivalent — know what Layer 2 can't see.** `provides_network` is a dom0 preference with no reliable in-VM signal, so the net-provider refusal exists **only at dispatch** (Layer 1). A `generic` step run *outside* qctl on a net-providing qube that is neither a TemplateVM nor named `sys-*` (say, a custom `corp-vpn`) passes the runtime preamble — Layer 2's denylist is the name + type heuristics only. For targeted steps the layers agree (an exact name match doesn't care about klass); the asymmetry only affects `generic` steps on unconventionally-named infrastructure. If that gap matters for a qube, name it `sys-*` or dispatch through qctl.

Exit codes are deliberately distinct: **5** = qctl refused at dispatch (nothing ran); **9** = the step's own preamble fired at runtime. Anything else is the step's own status.

**dom0 steps get weaker protection — compensate with visibility.** A `QCTL_TARGET=dom0` step acts on *other* qubes via `qvm-*` commands, and no name check can verify those are the qubes you meant. Convention: a dom0 step sets the qubes it touches in one variable block at the top (where review catches them), `echo`s them before acting, and prints an explicit `ROLLBACK:` line for anything it changed.

### Step-script conventions

Codified from steps that drove real migrations. Every generated step should:

1. **Open with the target-guard preamble** (above). The `QCTL_TARGET=` declaration is the *first executable line* of the file — qctl enforces this — with the guard immediately after. The guard doesn't depend on shell options, so `set -u` comes after the preamble, not before.
2. **`set -u`** at minimum; `set -uo pipefail` when pipes carry the result.
3. **Echo state before and after every mutation** — `== BEFORE ==` / `== AFTER ==` blocks around the change, so the human sees what was and what is, not just "ok".
4. **Verify positively AND negatively.** After a change, show the intended thing working and the removed/blocked thing actually gone — a firewall step should show the blocked path timing out, not only the allowed path succeeding.
5. **Print a `ROLLBACK:` line** for any state-changing step — the exact command to undo it, echoed at the end where it's on screen the moment something looks wrong.
6. **No silent privilege.** Steps run as root via `--user root`; a `sudo` prefix in-script is redundant there (Trap 2) and only misleads a reviewer about where privilege comes from. If a step must switch users (`sudo -u postgres`), that's meaningful — keep it, and only it.
7. **Idempotent at the step boundary, or say so.** Re-running a step should be safe; if it isn't, the header comment says "run once" and why.
8. **Secrets never in output.** Follow Pattern C: generate inside the target, ship via file redirect, shred both copies. A step's `.out` lands back on the work qube where the agent reads it — treat everything a step prints as agent-visible by design.

## Traps

### Trap 1 — TemplateVMs have no DNS / general outbound

`apt-get update` works (routed through `qubes-updates-proxy` on port 8082), but `curl https://...` fails with "Could not resolve host" — there's no general DNS resolution. Anything that fetches a key, tarball, or installer from the network has to come in via `qvm-copy` from a net-enabled AppVM.

**Check before suggesting a script for a template:** if it does `curl ... | gpg --dearmor`, that won't work. Pre-fetch in an AppVM, `qvm-copy` in, install with `cp` / `install`.

### Trap 2 — *Minimal* templates don't have passwordless sudo

Full templates ship `qubes-core-agent-passwordless-root`, and an AppVM's `/etc` comes from its template — so a default AppVM has passwordless sudo *because its template does*. **Minimal** templates (`debian-13-minimal`, `fedora-<release>-minimal`) omit the package, so the minimal template itself and any qube based on it will prompt for a password that was never set. Don't direct the user to open a terminal there and run `sudo`. Run as root from dom0 instead:
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

### Trap 8 — On `lvm_thin`, a volume's `usage` is blocks *allocated*, not filesystem usage

`qvm-volume info <vm>:private` reports `usage` straight from the thin LV's allocation. That is **not** how full the filesystem is. Without periodic `fstrim`, deleted files keep their thin blocks allocated indefinitely, so the number ratchets upward and never comes back down — a qube that has churned through a few GB of browser cache reads as nearly full while its filesystem is mostly empty.

Seen in practice on a browser AppVM: dom0 reported `usage 1988140361` of `size 2147483648` — 92.6%, which reads as "out of space". Booting the qube and running `df` showed **797 MiB of live data**, about 40%. The ~1.1 GiB difference was untrimmed deleted blocks.

Both numbers are correct; they answer different questions:

| Question | Ask | Why |
|---|---|---|
| Is this qube running out of room? | `df -h /rw` **inside the running qube** | Live file data is what fills a filesystem |
| How much pool space is committed? | `qvm-volume info <vm>:private` in dom0 | Allocated blocks are unavailable to other qubes until discarded |

So don't size a volume off the dom0 figure alone. Reclaim with `fstrim -v /rw` inside the qube (online and safe — it discards only blocks the filesystem already treats as free). Expect less back than the gap suggests at first: `revisions_to_keep` snapshots still reference the pre-trim blocks, and those can't return to the pool until the revisions rotate out.

**Why this one bites harder than a mis-read number usually would:** the misleading value feeds a decision that is *one-way*. `qvm-volume resize` grows only — there is no supported shrink, and `qvm-volume revert` restores a volume's **content** from a revision, not its size. Undoing an oversize means backup and recreate. Check `df` inside the qube before picking a number.

While you're in that operation, two related facts worth having:

- **The filesystem follows on the next boot, automatically.** After `qvm-volume resize <vm>:private <bytes>`, `qubes-core-agent`'s `mount-dirs.sh` runs `resize2fs` during startup ("Private device size management: enlarging /dev/xvdb"). Don't write a manual `resize2fs` into a resize procedure — resize, boot, then verify with `df -h /rw` or the `EXT4-fs (xvdb): resized filesystem` line in `journalctl -b`. Only if the filesystem did *not* follow does a manual `resize2fs /dev/xvdb` belong, in its own reviewed step.
- **For an AppVM, `private` is the volume to grow.** Its `root` is a `snap_on_start` view of the template (`usage 0`, `save_on_stop False`); growing it per-qube accomplishes nothing. Grow the template's `root` if the *template* needs more space.

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

For any AppVM that needs net only for installation: open a narrow allowlist (mirror hostnames only) + drop, do the install, then switch to deny-all for steady state. Don't leave the install-time allowlist behind.

The switch has a trap: `qvm-firewall <vm> reset` does **not** leave an empty ruleset — it saves a single `action=accept` rule (its own help text: "reset to default (accept all connections)"). A later `add` is a separate save, so `reset && add ...` creates an unrestricted-egress window and strands the qube in accept-all if the second command is interrupted or fails. Avoid `reset` entirely: install the deny-all first, verify it, and only then remove the now-unreachable install-time accepts.

```bash
# 1. BEFORE the transition, from inside the qube: prove the test path works.
curl --max-time 5 https://deb.debian.org

# 2. In dom0: make the first state change fail closed.
qvm-firewall <vm> add --before 0 action=drop
qvm-firewall <vm> list   # the all-destination drop must be rule 0

# 3. From inside the qube: repeat the same probe; it must now fail.
curl --max-time 5 https://deb.debian.org

# 4. Back in dom0: delete every obsolete install-time accept by its full rule spec.
qvm-firewall <vm> del action=accept dsthost=<mirror-host>
qvm-firewall <vm> list   # confirm only the intended steady-state policy remains
```

(`action=drop` is a positional rule expression — there is no `--action` option.) Qubes implements `drop` as an ICMP administrative reject, so the negative probe may fail immediately with an unreachable/prohibited error rather than time out; either is a pass. The pre-change success is what prevents a DNS or endpoint outage from false-passing the negative check. This is the same placement trap [tailscale-lan-lockdown.md](../../tailscale-lan-lockdown.md) documents — a drop that sits after an accept "looks applied" in the list output and never matches.

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

### Pattern F — Remove passwordless root on any AppVM holding non-trivial value

Default is passwordless root access (`qubes-core-agent-passwordless-root`). Remove that access from any AppVM that:

- Holds data worth defending past the current session (DBs, keys, secrets store), **OR**
- Has agents / autonomous processes that hold a shell inside it, **OR**
- Has any inbound shell vector (SSH, even VPN/tailnet-scoped).

Why this matters even on a qube with no remote shell vector: in-qube `user`-shell compromise + passwordless escalation enables persistent backdoors via `/rw/config/rc.local` and `qubes-firewall-user-script`, direct PGDATA reads (bypassing Postgres auth), pg_hba.conf rewrites, and LAN-pivot raw-socket primitives. Without passwordless escalation, the same compromise is bounded to the current session and the user-readable surface unless the attacker also defeats the configured authentication boundary — a real boundary, not security theater.

Procedure — the passwordless grant is not one file. `qubes-core-agent-passwordless-root` installs **three** grants, all keyed on membership of group `qubes`. The main `qubes-core-agent` package — not the passwordless-root subpackage — adds the default user to that group during install and upgrade:

- `/etc/sudoers.d/qubes` — `%qubes ALL=(ALL) ROLE=unconfined_r TYPE=unconfined_t NOPASSWD: ALL` on Fedora and Debian
- `/etc/polkit-1/rules.d/00-qubes-allow-all.rules` — allows **any** polkit action for group `qubes`, so `pkexec bash` is instant root
- `/etc/pam.d/su.qubes` (plus the Debian pam-config) — `su` with no password

A countermeasure that touches only the sudoers half leaves root one `pkexec` away. And adding your own `/etc/sudoers.d/` drop-in does not even close the sudoers half: `#includedir` reads files lexically and **the last match wins**, so `10-require-auth` (or `00-`, or `50-` — any conventional prefix) sorts *before* `qubes`, whose `NOPASSWD: ALL` then matches last and wins. Nothing errors and `visudo -c` passes; sudo stays passwordless.

Close all three paths at once using one of these deliberately different scopes:

- **Preferred, durable, template-wide:** remove the package in a dedicated template, using purge on Debian:
  ```bash
  apt-get purge qubes-core-agent-passwordless-root   # Debian
  dnf remove qubes-core-agent-passwordless-root     # Fedora
  ```
  On Debian, plain `apt-get remove` is insufficient: `/etc/sudoers.d/qubes` and `/etc/polkit-1/rules.d/00-qubes-allow-all.rules` are conffiles, so ordinary removal preserves both active root grants. Purge removes them. This is [Qubes' documented package-removal route](https://doc.qubes-os.org/en/latest/user/security-in-qubes/vm-sudo.html#replacing-passwordless-root-access); it changes every qube that shares that template.

  After taking this package route, verify that no distro-specific grant file remains:
  ```bash
  remaining=0
  for grant in \
      /etc/sudoers.d/qubes \
      /etc/polkit-1/rules.d/00-qubes-allow-all.rules \
      /etc/pam.d/su.qubes \
      /usr/share/pam-configs/su.qubes; do
      if [ -e "$grant" ]; then
          printf 'grant remains: %s\n' "$grant" >&2
          remaining=1
      fi
  done
  test "$remaining" -eq 0
  ```
  This must print nothing. Still perform the behavioral checks below: package/file state alone does not prove the three escalation paths are closed.
- **Per-qube, with maintenance required:** leave the package in the shared template and run `gpasswd -d user qubes` from `/rw/config/rc.local` on every boot. Every grant keys on the group, so this closes all three without changing sibling qubes.

Do **not** treat a one-time group edit in the template as durable. In the Qubes 4.3 Fedora packaging, the main core-agent package's `%pre` runs `usermod -a ... --groups qubes` even on upgrades, before its update-only early exit, so a later template update silently re-adds the user and revives all three grants. The group also owns the UpdateVM's `/var/lib/qubes/dom0-updates` staging directory; removing membership can break dom0 update downloads. Do not use the group-removal route on a qube that is, or may become, the UpdateVM.

If you want an authenticated in-qube admin path rather than refusal, set the required password and configure that path explicitly after removing the passwordless grants. An AppVM's `/etc/shadow` and `/etc/group` reset from its template on every boot: put template-wide state in a dedicated template, or re-apply per-qube state from `/rw/config/rc.local` (`chpasswd` from a stored hash + `gpasswd -d user qubes`). Root administration from dom0 via `qvm-run --user root` remains available either way.

**Verify by negation — all three doors, not just the first:**

```bash
sudo -k; sudo id   # must prompt or refuse
pkexec id          # must prompt (or fail without an authentication agent)
su -c id           # must prompt or refuse
```

None may reach `uid=0` without authentication; prompting or refusing is safe. Repeat this check after every boot when using the per-qube route and after every template/core-agent update. Steps are the same whether the value being defended is "agent has the shell" or "DB has the data."

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
