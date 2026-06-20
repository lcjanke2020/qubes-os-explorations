#!/bin/bash
# qctl — dom0 control-plane helper for agent-driven Qubes work.
#
#   qctl <target-vm|dom0> <step-name>
#
# Pulls /tmp/qctl/<step>.sh from the WORK qube (where the agent writes scripts),
# runs it — as root inside <target-vm> (auto-starting it), or directly in dom0
# when the target is the literal word "dom0" — and streams the combined output
# back to /tmp/qctl/<step>.out on the WORK qube so the agent can read the result.
# A dom0 copy is left at /tmp/qctl-<step>.out (mode 0600 — dom0 artifacts hold the
# combined output of root-executed steps and stay private; the work-qube copy is
# chmodded 0644 for the agent). qctl exits with the STEP's own exit status, so a
# failed step is detectable when chaining many of them. Other exit codes are
# distinct so $? is unambiguous: 1 = couldn't stage/pull the step script;
# 2 = bad VM/step/work-qube name; 3 = ran the step but couldn't deliver output
# back to the work qube (contract breach); 4 = refused to write through a symlink
# at the dom0 output path.
#
# Why this exists: dom0 has no clipboard in or out, and an agent in an app qube
# can't reach dom0 at all. This turns every step into one short, reviewable
# command the human runs in dom0, with results flowing back to the agent's qube
# automatically — no hand-typing long `qvm-run` pipes, no transcribing output.
#
# Install once in dom0 (pull from the work qube; no clipboard needed). The agent
# stages qctl.sh into /tmp/qctl/qctl.sh first, alongside its step scripts:
#   qvm-run --pass-io <work-qube> 'cat /tmp/qctl/qctl.sh' </dev/null > ~/qctl && chmod +x ~/qctl
# Set the work qube (defaults to QCTL_WORK or 'work-qube'):
#   export QCTL_WORK=<work-qube>
#
# Cross-user /tmp hand-off: the agent runs `mkdir -p /tmp/qctl && chmod 1777
# /tmp/qctl` once. Note the sticky bit (1777) only makes the *directory* writable
# across users — it does NOT make the files inside readable across users; that
# depends on each file's own mode. It works in practice because the default umask
# (022) writes world-readable 0644 step files, and qctl chmods the output file
# 0644 explicitly (below). If the agent runs with a restrictive umask it must
# write <step>.sh mode 0644 so dom0's qvm-run — running as the qube's *default*
# user — can read it.
#
# Review discipline: the agent pastes each <step>.sh in chat before you run it.
# The script is executed from a tmpfile (in dom0, AND staged into a tmpfile
# inside the target VM) with the step's own stdin redirected from /dev/null —
# never piped to `bash` over stdin — so a heredoc or nested `qvm-run --pass-io`
# inside a step can't drain the rest of the script stream.
set -uo pipefail
umask 077   # dom0-created files (the tmpfile + /tmp/qctl-<step>.out) hold root
            # step output; keep them private. The shipped-back work-qube copy is
            # chmodded 0644 explicitly below, so this doesn't affect the agent.

WORK="${QCTL_WORK:-work-qube}"
VM="${1:?usage: qctl <target-vm|dom0> <step-name>}"
S="${2:?usage: qctl <target-vm|dom0> <step-name>}"

# WORK, VM, and step name are all interpolated into paths, into mktemp patterns,
# and into shell commands sent over qvm-run. Restrict them to a safe set so a
# stray '/', quote, or whitespace can't break quoting or produce an invalid
# mktemp template. WORK comes from the environment, so validate it too.
case "$S"    in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad step name '$S' (allowed: A-Za-z0-9._-)"; exit 2 ;; esac
case "$VM"   in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad VM name '$VM' (allowed: A-Za-z0-9._-)"; exit 2 ;; esac
case "$WORK" in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad work qube '$WORK' (set QCTL_WORK; allowed: A-Za-z0-9._-)"; exit 2 ;; esac

SRC="/tmp/qctl/${S}.sh"
WORK_OUT="/tmp/qctl/${S}.out"
DOM0_TMP="$(mktemp "/tmp/qctl-${S}.XXXXXX.sh")" || { echo "[qctl] ERROR: mktemp failed in dom0"; exit 1; }
DOM0_OUT="/tmp/qctl-${S}.out"

echo "[qctl] pulling ${WORK}:${SRC}"
# --pass-io propagates the remote `cat` exit status, so a non-zero here means the
# pull itself failed (work qube down, qrexec denied, or the file doesn't exist) —
# distinct from "pulled fine but the file was empty". Report the two separately so
# the error isn't the misleading "did the agent write it yet?" in the wrong case.
pull_rc=0
qvm-run --pass-io "$WORK" "cat '$SRC'" </dev/null > "$DOM0_TMP" || pull_rc=$?
if [ "$pull_rc" -ne 0 ]; then
    echo "[qctl] ERROR: could not pull ${SRC} from ${WORK} (qvm-run exit $pull_rc): is ${WORK} running, is qrexec allowed, and does the file exist?"
    rm -f "$DOM0_TMP"; exit 1
fi
if [ ! -s "$DOM0_TMP" ]; then
    echo "[qctl] ERROR: ${SRC} is present but empty on ${WORK}. Did the agent finish writing it?"
    rm -f "$DOM0_TMP"; exit 1
fi

# The dom0 output copy uses a predictable path so re-running a step overwrites in
# place. Refuse to follow a symlink planted there, and remove any stale file first
# so the redirect creates fresh under umask 077 — truncating a pre-existing
# loose-perms file would leave it readable. chmod 600 after the write makes the
# documented mode explicit regardless. dom0 is single-trusted-user, so this closes
# the realistic cases without chasing a TOCTOU race.
if [ -L "$DOM0_OUT" ]; then
    echo "[qctl] ERROR: $DOM0_OUT is a symlink; refusing to write through it"
    rm -f "$DOM0_TMP"; exit 4
fi
rm -f "$DOM0_OUT"

rc=0
if [ "$VM" = "dom0" ]; then
    echo "[qctl] running in dom0"
    bash "$DOM0_TMP" </dev/null > "$DOM0_OUT" 2>&1 || rc=$?
else
    echo "[qctl] starting $VM if needed"
    qvm-start --skip-if-running "$VM" 2>/dev/null || true
    echo "[qctl] running in $VM (as root)"
    # Stage into a tmpfile INSIDE the target VM and run it from there with the
    # step's stdin off /dev/null — same anti-stdin-drain reasoning as the dom0
    # path. `qvm-run ... 'bash' < script` (the obvious form) would let a nested
    # `qvm-run --pass-io` inside the step consume the rest of the script.
    # --pass-io propagates the remote command's exit status, so $? here is the
    # step's own exit code.
    qvm-run --pass-io --user root "$VM" \
        'T=$(mktemp /tmp/.qctl-step.XXXXXX.sh); cat > "$T"; bash "$T" </dev/null; rc=$?; rm -f "$T"; exit $rc' \
        < "$DOM0_TMP" > "$DOM0_OUT" 2>&1 || rc=$?
fi
chmod 600 "$DOM0_OUT" 2>/dev/null || true

echo "[qctl] shipping output back to ${WORK}:${WORK_OUT}"
# `cat && chmod` (not `;`) so a failed/partial write isn't masked by a successful
# chmod; chmod 0644 lets the agent read it regardless of the work qube default
# user's umask (the cross-user hand-off caveat in the header). Capture the ship
# status — delivery is qctl's contract, so a failure here must not look like success.
ship_rc=0
qvm-run --pass-io "$WORK" "cat > '$WORK_OUT' && chmod 0644 '$WORK_OUT'" < "$DOM0_OUT" || ship_rc=$?
rm -f "$DOM0_TMP"
if [ "$ship_rc" -ne 0 ]; then
    echo "[qctl] ERROR: failed to ship output back to ${WORK}:${WORK_OUT} (rc=$ship_rc); step rc was $rc. dom0 copy: ${DOM0_OUT}"
    exit 3
fi
if [ "$rc" -ne 0 ]; then
    echo "[qctl] step FAILED (exit $rc). output at ${WORK}:${WORK_OUT}  (dom0 copy: ${DOM0_OUT})"
else
    echo "[qctl] done. agent reads ${WORK}:${WORK_OUT}  (dom0 copy: ${DOM0_OUT})"
fi
exit "$rc"
