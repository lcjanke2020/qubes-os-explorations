#!/bin/bash
# qctl — dom0 control-plane helper for agent-driven Qubes work.
#
#   qctl <target-vm|dom0> <step-name>
#   qctl --version | -V          print the helper version and exit 0
#   qctl --help | -h             print usage and exit 0
#
# Pulls <staging-dir>/<step>.sh from the WORK qube (where the agent writes
# scripts; default staging dir /tmp/qctl, see QCTL_SRC_DIR below), runs it — as
# root inside <target-vm> (auto-starting it), or directly in dom0 when the
# target is the literal word "dom0" — appends a one-line completion footer, and
# ships the combined output back to <staging-dir>/<step>.out on the WORK qube so
# the agent can read the result. Delivery goes to <step>.out.part first; the
# byte count is checked against the dom0 copy and the file is then renamed into
# place, so <step>.out is never partial (a failed or short delivery removes the
# .part and exits 3 with nothing published).
# A dom0 copy is left at /tmp/qctl-<step>.out (mode 0600 — dom0 artifacts hold
# the combined output of root-executed steps and stay private; the work-qube
# copy is chmodded 0644 for the agent in the default layout, 0600 under
# QCTL_WORK_USER). qctl exits with the STEP's own exit status, so a failed step
# is detectable when chaining many of them. Other exit codes are distinct so $?
# is unambiguous: 1 = couldn't reach the work qube to prepare the staging
# directory or pull the step script; 2 = wrong number of arguments, bad
# VM/step/work-qube name, bad QCTL_SRC_DIR/QCTL_WORK_USER (or no such qube);
# 3 = ran the step but couldn't deliver output back to the work qube (contract
# breach); 4 = refused to write through a symlink at the dom0 output path;
# 5 = target-guard refusal at dispatch (QCTL_TARGET declaration missing,
# malformed, or not matching the dispatch target). By convention the in-script
# runtime guard aborts with 9 (see SKILL.md "Target guard"), so a dispatch
# refusal (5 — nothing ran) is distinguishable from a runtime mismatch (9 — the
# step's own preamble fired).
#
# Previous output: qctl's first action on the work qube moves an existing
# <step>.out to <step>.out.prev (one generation kept) and removes a stale
# <step>.out.part, before the pull. After any dispatch that reached the work
# qube, <step>.out therefore holds the new result or nothing — a re-dispatched
# step, or one the target guard refused, never leaves an older run's footer
# under the name the agent reads. (An agent that arms a watcher on the path
# clears it itself first; see SKILL.md "Waiting for a step".)
#
# Completion footer: the last line of every shipped <step>.out is
#   [qctl] END step=<step> target=<vm> rc=<n> version=<QCTL_VERSION> finished=<UTC>
# The agent never sees qctl's exit status (that goes to the dom0 terminal), so
# the footer carries rc into the file. It is also a uniform "the step is over"
# marker: the file is shipped whole after the step exits, so on the work qube
# <step>.out is either absent or complete — watch for the file, then read the
# footer. No footer in the dom0 copy means the step is still running or was
# interrupted.
#
# Why this exists: dom0 has no clipboard in or out, and an agent in an app qube
# can't reach dom0 at all. This turns every step into one short, reviewable
# command the human runs in dom0, with results flowing back to the agent's qube
# automatically — no hand-typing long `qvm-run` pipes, no transcribing output.
#
# Environment (read in dom0; each value is validated before use):
#   QCTL_WORK       the work qube (default: work-qube)
#   QCTL_SRC_DIR    staging directory on the work qube holding <step>.sh and
#                   receiving <step>.out (default: /tmp/qctl; an absolute path,
#                   A-Za-z0-9._/-, no "..")
#   QCTL_WORK_USER  if set, every qvm-run against the work qube (the prepare
#                   step that moves the previous output aside, the pull and the
#                   ship-back) runs `--user <this user>`; the account must own
#                   the staging directory (default: unset — the qube's default
#                   user)
#
# Install once in dom0 (pull from the work qube; no clipboard needed). The agent
# stages qctl.sh into the staging dir first, alongside its step scripts.
# Single-account work qube (agent = the qube's default user), default layout:
#   qvm-run --no-gui --pass-io <work-qube> 'cat /tmp/qctl/qctl.sh' </dev/null > ~/qctl && chmod +x ~/qctl
#   export QCTL_WORK=<work-qube>
# Multi-account work qube (agent has its own 0700 home and is not the default
# user) — stage in the agent's home and act as the agent; the install pull needs
# the --user too because the helper itself sits in that home:
#   export QCTL_WORK=<work-qube> QCTL_WORK_USER=<agent-user> QCTL_SRC_DIR=/home/<agent-user>/<project>/qctl
#   qvm-run --no-gui --pass-io --user <agent-user> <work-qube> "cat $QCTL_SRC_DIR/qctl.sh" </dev/null > ~/qctl && chmod +x ~/qctl
# Then `bash ~/qctl --version` and compare with QCTL_VERSION in the skill's copy.
#
# Cross-user /tmp hand-off (the default layout): the agent runs `mkdir -p
# /tmp/qctl && chmod 1777 /tmp/qctl` once. Note the sticky bit (1777) only makes
# the *directory* writable across users — it does NOT make the files inside
# readable across users; that depends on each file's own mode. It works in
# practice because the default umask (022) writes world-readable 0644 step
# files, and qctl chmods the output file 0644 explicitly (below). If the agent
# runs with a restrictive umask it must write <step>.sh mode 0644 so dom0's
# qvm-run — running as the qube's *default* user — can read it. /tmp is cleared
# when the work qube restarts, taking every <step>.out with it; agent-home
# staging (QCTL_SRC_DIR + QCTL_WORK_USER) avoids both the world-readable
# directory and the loss.
#
# Review discipline: the agent shows each <step>.sh (file or paste) before you
# run it. The script is executed from a tmpfile (in dom0, AND staged into a
# tmpfile inside the target VM) with the step's own stdin redirected from
# /dev/null — never piped to `bash` over stdin — so a heredoc or nested
# `qvm-run --pass-io` inside a step can't drain the rest of the script stream.
#
# Target guard (v2): every step must declare its intended target as the FIRST
# executable line of the file (shebang/comments/blanks may precede it):
#   QCTL_TARGET=<qube-name>    # or: dom0 | generic
# Exactly one declaration, bare unquoted value (a trailing comment is fine).
# qctl refuses to dispatch (exit 5) when the declaration is missing, not in
# first position, duplicated, malformed, or doesn't match the <target-vm>
# argument. The target is thereby stated twice — once in the reviewed script,
# once on the command line — and the two must agree; that is what catches a
# fat-fingered `qctl <wrong-vm> <step>` before anything runs.
# `generic` steps (safe on any app qube) skip the name match but are refused on
# infrastructure targets: TemplateVMs, sys-* qubes, and net-providing qubes.
# Naming an infrastructure qube explicitly IS allowed (template work is a
# normal part of this skill) — qctl just announces it loudly before running.
#
# Changelog
#   1.1.0  QCTL_SRC_DIR (absolute) and QCTL_WORK_USER (agent-home staging on
#          multi-account work qubes; output shipped 0600 under a work user);
#          --no-gui on every qvm-run (a qube whose X server is stuck, or a
#          headless work qube, no longer hangs a step); --version/--help, exit 2
#          on a usage error; BEGIN banner in dom0 and END footer in the shipped
#          output; delivery via <step>.out.part with a byte-count check and
#          rename, so <step>.out is never partial; the previous output moves to
#          <step>.out.prev before each run; tests/qctl-shim-test.sh.
#   1.0.0  The script as shipped before versioning: target guard v2, tmpfile
#          execution on both paths, distinct exit codes 1-5.
QCTL_VERSION="1.1.0"

usage() {
    cat <<EOF
usage: qctl <target-vm|dom0> <step-name>
       qctl --version | -V
       qctl --help | -h
env:   QCTL_WORK=<work-qube>            (default: work-qube)
       QCTL_SRC_DIR=<dir on work qube>  (default: /tmp/qctl)
       QCTL_WORK_USER=<user on work qube>  (default: the qube's default user)
EOF
}
case "${1:-}" in
    --version|-V) echo "qctl $QCTL_VERSION"; exit 0 ;;
    --help|-h)    usage; exit 0 ;;
esac

set -uo pipefail
umask 077   # dom0-created files (the tmpfile + /tmp/qctl-<step>.out) hold root
            # step output; keep them private. The shipped-back work-qube copy is
            # chmodded explicitly below (OUT_MODE), so this doesn't affect the agent.

WORK="${QCTL_WORK:-work-qube}"
SRC_DIR="${QCTL_SRC_DIR:-/tmp/qctl}"
WORK_USER="${QCTL_WORK_USER:-}"
if [ "$#" -ne 2 ]; then usage >&2; exit 2; fi
VM="$1"
S="$2"

# WORK, VM, and step name are all interpolated into paths, into mktemp patterns,
# and into shell commands sent over qvm-run. Restrict them to a safe set so a
# stray '/', quote, or whitespace can't break quoting or produce an invalid
# mktemp template. WORK, SRC_DIR and WORK_USER come from the environment, so
# validate them too: SRC_DIR must be absolute (a relative value would resolve
# against whatever directory qrexec starts the remote shell in, silently), may
# contain '/', and refuses '..'; WORK_USER may be empty (meaning: the work
# qube's default user).
case "$S"         in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad step name '$S' (allowed: A-Za-z0-9._-)"; exit 2 ;; esac
case "$VM"        in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad VM name '$VM' (allowed: A-Za-z0-9._-)"; exit 2 ;; esac
case "$WORK"      in *[!A-Za-z0-9._-]*|'') echo "[qctl] ERROR: bad work qube '$WORK' (set QCTL_WORK; allowed: A-Za-z0-9._-)"; exit 2 ;; esac
case "$SRC_DIR"   in *[!A-Za-z0-9._/-]*|''|*..*|[!/]*) echo "[qctl] ERROR: bad QCTL_SRC_DIR '$SRC_DIR' (must be an absolute path on the work qube; allowed: A-Za-z0-9._/-, no '..')"; exit 2 ;; esac
case "$WORK_USER" in *[!A-Za-z0-9._-]*) echo "[qctl] ERROR: bad QCTL_WORK_USER '$WORK_USER' (allowed: A-Za-z0-9._-)"; exit 2 ;; esac

# Every qvm-run against the WORK qube (prepare, pull and ship-back) goes
# through this array, so --user lands on all of them or none. --no-gui: these calls need no GUI
# session, and qvm-run's default wait (qubes.WaitForSession) is keyed on the
# qube's *default* user regardless of --user (qubesadmin/tools/qvm_run.py sends
# vm.default_user), so without the flag a headless work qube, or one whose GUI
# agent is mid-restart, would hang the pull.
WORK_RUN=(qvm-run --no-gui --pass-io)
[ -n "$WORK_USER" ] && WORK_RUN+=(--user "$WORK_USER")
WORK_RUN+=("$WORK")
# Mode of the shipped <step>.out: 0644 in the default layout, where the work
# qube's default user writes a file that the agent (possibly another account)
# must read; 0600 when QCTL_WORK_USER is set, since the agent then writes its
# own file and nothing else needs to read it.
OUT_MODE=0644
[ -n "$WORK_USER" ] && OUT_MODE=0600

SRC="${SRC_DIR}/${S}.sh"
WORK_OUT="${SRC_DIR}/${S}.out"
DOM0_TMP="$(mktemp "/tmp/qctl-${S}.XXXXXX.sh")" || { echo "[qctl] ERROR: mktemp failed in dom0"; exit 1; }
DOM0_OUT="/tmp/qctl-${S}.out"

# One line stating the effective configuration before anything runs, so a wrong
# QCTL_* export is visible in the terminal rather than inferred from a failed pull.
echo "[qctl] BEGIN v${QCTL_VERSION} target=${VM} step=${S} work=${WORK} user=${WORK_USER:-default} src=${SRC_DIR}"
# Move this step's previous output aside before anything else happens on the
# work qube (see header, "Previous output"). Done before the pull so that even a
# dispatch that fails at the pull or at the target guard leaves no stale
# <step>.out behind. `a || b && c` groups as `(a || b) && c`, so a failed mv
# fails the whole command and is reported.
if ! "${WORK_RUN[@]}" "[ ! -e '${WORK_OUT}' ] || mv -f '${WORK_OUT}' '${WORK_OUT}.prev' && rm -f '${WORK_OUT}.part'" </dev/null; then
    echo "[qctl] ERROR: could not prepare ${WORK}:${SRC_DIR} (move a previous ${S}.out aside): is ${WORK} running, is qrexec allowed, and does ${WORK_USER:-the default user} own that directory?"
    rm -f "$DOM0_TMP"; exit 1
fi
echo "[qctl] pulling ${WORK}:${SRC}"
# --pass-io propagates the remote `cat` exit status, so a non-zero here means the
# pull itself failed (work qube down, qrexec denied, or the file doesn't exist) —
# distinct from "pulled fine but the file was empty". Report the two separately so
# the error isn't the misleading "did the agent write it yet?" in the wrong case.
pull_rc=0
"${WORK_RUN[@]}" "cat '$SRC'" </dev/null > "$DOM0_TMP" || pull_rc=$?
if [ "$pull_rc" -ne 0 ]; then
    echo "[qctl] ERROR: could not pull ${SRC} from ${WORK} (qvm-run exit $pull_rc): is ${WORK} running, is qrexec allowed, does the file exist, and can ${WORK_USER:-the default user} read it?"
    rm -f "$DOM0_TMP"; exit 1
fi
if [ ! -s "$DOM0_TMP" ]; then
    echo "[qctl] ERROR: ${SRC} is present but empty on ${WORK}. Did the agent finish writing it?"
    rm -f "$DOM0_TMP"; exit 1
fi

# ---- target guard ----------------------------------------------------------
# The declaration is the FIRST executable line of the step (shebang, comments
# and blank lines skipped) — not merely present somewhere in the file. A
# declaration buried mid-file would pass a grep but let side effects run
# before the runtime guard. It also doubles as the variable the step's own
# guard preamble reads (SKILL.md "Target guard"), so dispatch-time and
# runtime read the same line.
FIRST_CODE=""
while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"      # ltrim
    [ -z "$line" ] && continue                    # blank
    case "$line" in '#'*) continue ;; esac        # comment / shebang
    FIRST_CODE="$line"
    break
done < "$DOM0_TMP"
case "$FIRST_CODE" in
    QCTL_TARGET=*) ;;
    *)
        echo "[qctl] TARGET GUARD: the first executable line of ${S}.sh is not a QCTL_TARGET declaration — refusing to dispatch."
        echo "[qctl] Every step must open with the guard preamble (QCTL_TARGET=<qube>|dom0|generic before"
        echo "[qctl] any other code; see SKILL.md 'Target guard'). Regenerate the step and retry."
        rm -f "$DOM0_TMP"; exit 5 ;;
esac
# Exactly one QCTL_TARGET= line in the whole file: the runtime guard is plain
# shell and would honor a later reassignment, so a second bare declaration
# means dispatch could validate one value while the step runs under another.
# The count is a plain line-start grep, NOT a shell parse — heredoc payload
# and other non-executable occurrences count too, deliberately: refusing to
# parse shell means failing closed (see SKILL.md for the printf workaround
# when a step must legitimately EMIT a declaration). Prefixed reassignments
# (export/readonly) aren't counted, but can't repoint the dispatch either:
# the CLI target stays authoritative and the runtime guard re-validates, so
# the worst case there is an exit-9 abort, never a wrong-qube run.
if [ "$(grep -cE '^[[:space:]]*QCTL_TARGET=' "$DOM0_TMP")" -ne 1 ]; then
    echo "[qctl] TARGET GUARD: ${S}.sh has more than one line beginning with QCTL_TARGET= — refusing to dispatch."
    echo "[qctl] (Heredoc/example content counts. A step that must emit a declaration should"
    echo "[qctl] assemble the token instead — see SKILL.md 'Target guard'.)"
    rm -f "$DOM0_TMP"; exit 5
fi
# Bare value only: strip an optional trailing comment and trailing whitespace,
# then hold the value to the same safe charset as the CLI names above. No
# quote-stripping or whitespace-deletion — a normalizer that "repairs" a
# malformed declaration can silently turn it into a different valid qube
# name, which is exactly what a guard must not do. Anything but a clean bare
# token fails closed.
TGT="${FIRST_CODE#QCTL_TARGET=}"
# Strip a trailing comment only where bash itself would start one: '#' opens
# a comment at the beginning of a word (after whitespace), never inside the
# assignment value. QCTL_TARGET=web#bad assigns 'web#bad' at runtime —
# parsing it as 'web' here would re-open the dispatch/runtime divergence this
# guard exists to close, so the '#' falls through to the charset check below
# and is refused as malformed instead.
case "$TGT" in
    *[[:space:]]"#"*) TGT="${TGT%%[[:space:]]"#"*}" ;;
esac
TGT="${TGT%"${TGT##*[![:space:]]}"}"              # rtrim
case "$TGT" in
    *[!A-Za-z0-9._-]*|'')
        echo "[qctl] TARGET GUARD: malformed QCTL_TARGET in ${S}.sh (expected a bare qube name, 'dom0', or 'generic' — no quotes or whitespace)"
        rm -f "$DOM0_TMP"; exit 5 ;;
esac

# Classify the dispatch target once (dom0 aside): klass + provides_network via
# qvm-prefs, plus the sys-* naming convention. Both reads hard-fail: qvm-prefs
# can fail for more reasons than "no such qube" (qubesd down, permissions), so
# surface its actual stderr instead of guessing — and a guard that can't
# classify the target must not fall through to "not infrastructure".
IS_INFRA=0
if [ "$VM" != "dom0" ]; then
    KLASS="$(qvm-prefs "$VM" klass 2>/dev/null)" || {
        echo "[qctl] ERROR: qvm-prefs klass failed for '${VM}' (no such qube, or qubesd unavailable):"
        qvm-prefs "$VM" klass 2>&1 >/dev/null | head -3
        rm -f "$DOM0_TMP"; exit 2; }
    PROVNET="$(qvm-prefs "$VM" provides_network 2>/dev/null)" || {
        echo "[qctl] ERROR: qvm-prefs provides_network failed for '${VM}':"
        qvm-prefs "$VM" provides_network 2>&1 >/dev/null | head -3
        rm -f "$DOM0_TMP"; exit 2; }
    case "$VM" in sys-*) IS_INFRA=1 ;; esac
    [ "$KLASS" = "TemplateVM" ] && IS_INFRA=1
    [ "$PROVNET" = "True" ] && IS_INFRA=1
fi

if [ "$TGT" = "dom0" ] || [ "$VM" = "dom0" ]; then
    # dom0 steps must be declared dom0 AND dispatched to dom0 — no drift in
    # either direction.
    if [ "$TGT" != "$VM" ]; then
        echo "[qctl] TARGET GUARD: step '${S}' declares QCTL_TARGET=${TGT} but was dispatched to '${VM}' — refusing."
        rm -f "$DOM0_TMP"; exit 5
    fi
elif [ "$TGT" = "generic" ]; then
    if [ "$IS_INFRA" -eq 1 ]; then
        echo "[qctl] TARGET GUARD: generic step '${S}' refused on infrastructure qube '${VM}' (klass=${KLASS}, provides_network=${PROVNET})."
        echo "[qctl] If this is deliberate, declare QCTL_TARGET=${VM} explicitly in the step."
        rm -f "$DOM0_TMP"; exit 5
    fi
elif [ "$TGT" != "$VM" ]; then
    echo "[qctl] TARGET GUARD: step '${S}' declares QCTL_TARGET=${TGT} but was dispatched to '${VM}' — refusing."
    rm -f "$DOM0_TMP"; exit 5
elif [ "$IS_INFRA" -eq 1 ]; then
    # Explicitly declared infrastructure target: template/sys work is a normal
    # part of this skill — allowed, but never silent.
    echo "[qctl] *** INFRA TARGET (deliberate): '${VM}' klass=${KLASS}, provides_network=${PROVNET} — declared explicitly, proceeding ***"
fi
# ---- end target guard -------------------------------------------------------

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
    # --no-gui: do not wait for the qube's X session first. qvm-run's default
    # WaitForSession blocks until the in-qube X server is up, which never
    # happens on a qube whose X server is stuck (e.g. a GPU qube whose modeset
    # init failed); the step would then hang forever with no output, looking
    # like a dead qrexec. A root shell running a script needs no session.
    qvm-run --no-gui --pass-io --user root "$VM" \
        'T=$(mktemp /tmp/.qctl-step.XXXXXX.sh); cat > "$T"; bash "$T" </dev/null; rc=$?; rm -f "$T"; exit $rc' \
        < "$DOM0_TMP" > "$DOM0_OUT" 2>&1 || rc=$?
fi
chmod 600 "$DOM0_OUT" 2>/dev/null || true

# Completion footer (see header). Written into the dom0 copy before shipping so
# both copies carry it. If the step's last line had no trailing newline, start
# the footer on its own line rather than gluing it to the step's output.
if [ -s "$DOM0_OUT" ] && [ "$(tail -c1 "$DOM0_OUT" | wc -l)" -eq 0 ]; then
    echo >> "$DOM0_OUT"
fi
echo "[qctl] END step=${S} target=${VM} rc=${rc} version=${QCTL_VERSION} finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DOM0_OUT"

echo "[qctl] shipping output back to ${WORK}:${WORK_OUT}"
# Deliver into a sibling .part file, verify its byte count against the dom0 copy,
# set the mode, then rename into place. rename(2) is atomic within one
# filesystem, so <step>.out never exists in a partial state and a watcher that
# wakes on its creation reads the complete file. The size check, not cat's exit
# status, decides publication: cat exits 0 on a stream cut short (EOF is EOF),
# e.g. when qctl is interrupted mid-transfer. A failed or short delivery removes
# the .part and leaves nothing under the watched name. `umask 077` runs on the
# work qube first, so the .part is private from the moment it exists — dom0's
# umask does not cross qrexec, and a chmod after the bytes cannot revoke a read
# that already happened. `set -C` (noclobber) makes the create exclusive: if
# something planted a file under the predictable .part name after the prepare
# step removed it, cat refuses rather than writing into a file that carries
# someone else's mode, and the ship fails closed (exit 3, dom0 copy kept). The
# explicit chmod (OUT_MODE, above) then publishes the documented mode, 0644 in
# the default layout.
# Capture the ship status — delivery is qctl's contract, so a failure here must
# not look like success.
OUT_SIZE="$(wc -c < "$DOM0_OUT")"
ship_rc=0
"${WORK_RUN[@]}" "umask 077; set -C; cat > '${WORK_OUT}.part' && [ \"\$(wc -c < '${WORK_OUT}.part')\" -eq ${OUT_SIZE} ] && chmod ${OUT_MODE} '${WORK_OUT}.part' && mv -f '${WORK_OUT}.part' '${WORK_OUT}' || { rm -f '${WORK_OUT}.part'; exit 1; }" < "$DOM0_OUT" || ship_rc=$?
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
