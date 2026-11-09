#!/bin/bash
# Dry run of qctl.sh against fake qvm-run / qvm-prefs / qvm-start commands.
#
#   bash skills/qubes-setup-assistant/tests/qctl-shim-test.sh        # KEEP=1 keeps the scratch dir
#
# Nothing here touches a real qube or dom0. The shims record their argv and
# execute the remote command string locally, so the "work qube" and the
# "target qube" are directories under a scratch dir. The copy under test is the
# repo's qctl.sh with exactly one change: the dom0 "/tmp/qctl-" prefix is
# redirected into the scratch dir, so the test can run where /tmp is not
# writable and never leaves files in a shared /tmp.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_QCTL="$HERE/../qctl.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/qctl-shim-test.XXXXXX")" || exit 1
# The scratch path becomes QCTL_SRC_DIR, which qctl holds to A-Za-z0-9._/-. A
# TMPDIR with a '+', '=', '@' or space would make every case exit 2 and look
# like a helper regression, so say what is wrong instead.
case "$T" in *[!A-Za-z0-9._/-]*)
    echo "scratch path '$T' has characters outside qctl's path charset (A-Za-z0-9._/-); point TMPDIR at a plain path" >&2
    rm -rf "$T"; exit 1 ;;
esac
mkdir -p "$T/bin" "$T/faketmp" "$T/work/proj/qctl" "$T/work/tmp-qctl"
sed -e "s#/tmp/qctl-#$T/faketmp/qctl-#g" "$REPO_QCTL" > "$T/qctl-under-test.sh"
echo "scratch: $T"
echo "lines differing from the repo copy: $(diff "$REPO_QCTL" "$T/qctl-under-test.sh" | grep -c '^>')"

# ---- shims --------------------------------------------------------------------
# qvm-run: log argv, then run the last argument (the remote command) locally with
# the shim's stdin. Two knobs simulate delivery faults on the ship-back only
# (the command that writes the .part file): SHIM_SLOW_SHIP=1 delivers the stream
# in two chunks 0.6 s apart; SHIM_TRUNCATE_SHIP=1 delivers only the first 5 bytes.
cat > "$T/bin/qvm-run" <<EOF
#!/bin/bash
printf '%s\n' "qvm-run \$*" >> "$T/argv.log"
cmd="\${@: -1}"
cmd="\${cmd//\/tmp\/.qctl-step/$T/faketmp/.qctl-step}"
case "\$cmd" in
  *".part'"*)
    if [ "\${SHIM_SLOW_SHIP:-0}" = 1 ]; then { head -c 4; sleep 0.6; cat; } | bash -c "\$cmd"; exit \$?; fi
    if [ "\${SHIM_TRUNCATE_SHIP:-0}" = 1 ]; then head -c 5 | bash -c "\$cmd"; exit \$?; fi ;;
esac
exec bash -c "\$cmd"
EOF
cat > "$T/bin/qvm-prefs" <<EOF
#!/bin/bash
printf '%s\n' "qvm-prefs \$*" >> "$T/argv.log"
case "\$2" in klass) echo AppVM ;; provides_network) echo False ;; esac
EOF
cat > "$T/bin/qvm-start" <<EOF
#!/bin/bash
printf '%s\n' "qvm-start \$*" >> "$T/argv.log"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# ---- harness ------------------------------------------------------------------
pass=0; fail=0
check() { # check <label> <command...>   (pass when the command exits 0)
  local label=$1; shift
  if "$@"; then echo "PASS $label"; pass=$((pass+1)); else echo "FAIL $label"; fail=$((fail+1)); fi
}
runq() { # runq <label> <expected-rc> [VAR=value ...] -- <qctl args...>
  local label=$1 want=$2; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  : > "$T/argv.log"
  # Start from a clean helper configuration: the SKILL tells people to export
  # QCTL_* in their shells, and an inherited value would turn a default-layout
  # case into an agent-home one. The shim fault knobs are cleared the same way.
  env -u QCTL_WORK -u QCTL_SRC_DIR -u QCTL_WORK_USER -u SHIM_SLOW_SHIP -u SHIM_TRUNCATE_SHIP \
      "${envs[@]}" bash "$T/qctl-under-test.sh" "$@" > "$T/$label.stdout" 2>&1; rc=$?
  if [ "$rc" -eq "$want" ]; then echo "PASS $label (rc=$rc)"; pass=$((pass+1))
  else echo "FAIL $label rc=$rc want=$want"; fail=$((fail+1)); sed 's/^/    /' "$T/$label.stdout"; fi
}
footer_re='^\[qctl\] END step=%s target=%s rc=%s version=[0-9.]+ finished=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'
has_footer() { tail -n 1 "$1" | grep -Eq "$(printf "$footer_re" "$2" "$3" "$4")"; }
mode_is() { [ "$(stat -c %a "$1")" = "$2" ]; }
lines_eq() { [ "$(wc -l < "$1")" -eq "$2" ]; }
first_line_is() { [ "$(sed -n 1p "$1")" = "$2" ]; }
absent() { [ ! -e "$1" ]; }

WQ="$T/work/tmp-qctl"      # default layout (agent = default user)
AH="$T/work/proj/qctl"     # agent-home layout

echo "== A: --version / --help / usage =="
runq version 0 -- --version
check "version text" grep -qx 'qctl 1.1.0' "$T/version.stdout"
runq version-short 0 -- -V
runq help 0 -- --help
check "help names the three variables" bash -c "grep -q QCTL_WORK= '$T/help.stdout' && grep -q QCTL_SRC_DIR '$T/help.stdout' && grep -q QCTL_WORK_USER '$T/help.stdout'"
runq noargs 2 --
check "noargs prints usage" grep -q '^usage: qctl' "$T/noargs.stdout"
runq onearg 2 -- dom0

echo "== B: environment validation =="
runq bad-srcdir-dotdot 2 QCTL_SRC_DIR=/a/../b -- dom0 s1
check "dotdot message" grep -q 'bad QCTL_SRC_DIR' "$T/bad-srcdir-dotdot.stdout"
runq bad-srcdir-space 2 "QCTL_SRC_DIR=/x y" -- dom0 s1
runq bad-srcdir-relative 2 QCTL_SRC_DIR=proj/qctl -- dom0 s1
check "relative message says absolute" grep -qi 'absolute' "$T/bad-srcdir-relative.stdout"
runq bad-user 2 "QCTL_WORK_USER=bad user" -- dom0 s1
check "bad-user message" grep -q 'bad QCTL_WORK_USER' "$T/bad-user.stdout"
runq bad-step 2 -- dom0 'a/b'

echo "== C: dom0 step, default layout, step output without trailing newline =="
printf 'QCTL_TARGET=dom0\nprintf "hello"\n' > "$WQ/s-dom0.sh"
runq dom0-step 0 QCTL_WORK=wq QCTL_SRC_DIR="$WQ" -- dom0 s-dom0
check "BEGIN banner" grep -q "^\[qctl\] BEGIN v1.1.0 target=dom0 step=s-dom0 work=wq user=default src=$WQ$" "$T/dom0-step.stdout"
check "archive call: --no-gui, no --user, moves old .out aside" grep -q "^qvm-run --no-gui --pass-io wq \[ ! -e '$WQ/s-dom0.out' \] || mv -f '$WQ/s-dom0.out' '$WQ/s-dom0.out.prev'" "$T/argv.log"
check "pull: --no-gui, no --user" grep -q "^qvm-run --no-gui --pass-io wq cat '$WQ/s-dom0.sh'$" "$T/argv.log"
check "ship writes .part, checks size, renames" grep -q "^qvm-run --no-gui --pass-io wq cat > '$WQ/s-dom0.out.part' && \[ \"\$(wc -c < '$WQ/s-dom0.out.part')\" -eq [0-9]* \] && chmod 0644 '$WQ/s-dom0.out.part' && mv -f '$WQ/s-dom0.out.part' '$WQ/s-dom0.out' || { rm -f '$WQ/s-dom0.out.part'; exit 1; }$" "$T/argv.log"
check ".out exists" test -s "$WQ/s-dom0.out"
check ".out line 1 = hello" first_line_is "$WQ/s-dom0.out" hello
check "footer on its own line" has_footer "$WQ/s-dom0.out" s-dom0 dom0 0
check ".out has exactly 2 lines" lines_eq "$WQ/s-dom0.out" 2
check "no .part left behind" absent "$WQ/s-dom0.out.part"
check "no .prev on a first run" absent "$WQ/s-dom0.out.prev"
check ".out mode 644 (default layout)" mode_is "$WQ/s-dom0.out" 644
check "dom0 copy mode 600" mode_is "$T/faketmp/qctl-s-dom0.out" 600
printf 'QCTL_TARGET=dom0\necho done\n' > "$WQ/s-nl.sh"
runq dom0-step-nl 0 QCTL_WORK=wq QCTL_SRC_DIR="$WQ" -- dom0 s-nl
check "newline-terminated output gains no blank line" lines_eq "$WQ/s-nl.out" 2

echo "== D: VM step, agent-home layout (--user agent), step exits 7 =="
printf 'QCTL_TARGET=myvm\necho first-run; exit 7\n' > "$AH/s-vm.sh"
runq vm-step 7 QCTL_WORK=wq QCTL_WORK_USER=agent QCTL_SRC_DIR="$AH" -- myvm s-vm
check "BEGIN shows user" grep -q "^\[qctl\] BEGIN v1.1.0 target=myvm step=s-vm work=wq user=agent src=$AH$" "$T/vm-step.stdout"
check "archive call uses --user agent" grep -q "^qvm-run --no-gui --pass-io --user agent wq \[ ! -e '$AH/s-vm.out' \]" "$T/argv.log"
check "pull uses --user agent" grep -q "^qvm-run --no-gui --pass-io --user agent wq cat '$AH/s-vm.sh'$" "$T/argv.log"
check "in-VM run is --no-gui --pass-io --user root" grep -q "^qvm-run --no-gui --pass-io --user root myvm T=" "$T/argv.log"
check "ship uses --user agent and mode 0600" grep -q "^qvm-run --no-gui --pass-io --user agent wq cat > '$AH/s-vm.out.part' && .* chmod 0600 '$AH/s-vm.out.part' && mv -f" "$T/argv.log"
check "qvm-start called" grep -q '^qvm-start --skip-if-running myvm$' "$T/argv.log"
check "footer rc=7" has_footer "$AH/s-vm.out" s-vm myvm 7
check "step output present" grep -qx first-run "$AH/s-vm.out"
check ".out mode 600 (work user set)" mode_is "$AH/s-vm.out" 600
check "FAILED message" grep -q '^\[qctl\] step FAILED (exit 7)' "$T/vm-step.stdout"

echo "== E: rerun archives the previous output; a refused dispatch leaves no stale .out =="
printf 'QCTL_TARGET=myvm\necho second-run\n' > "$AH/s-vm.sh"
runq vm-rerun 0 QCTL_WORK=wq QCTL_WORK_USER=agent QCTL_SRC_DIR="$AH" -- myvm s-vm
check "rerun: .out is the new run" grep -qx second-run "$AH/s-vm.out"
check "rerun: .prev is the previous run" grep -qx first-run "$AH/s-vm.out.prev"
check "rerun: .prev kept the old footer" has_footer "$AH/s-vm.out.prev" s-vm myvm 7
printf 'QCTL_TARGET=othervm\necho nope\n' > "$AH/s-vm.sh"
runq guard-mismatch 5 QCTL_WORK=wq QCTL_WORK_USER=agent QCTL_SRC_DIR="$AH" -- myvm s-vm
check "guard refused before run" bash -c "! grep -q -- '--user root' '$T/argv.log'"
check "refused dispatch: no .out under the watched name" absent "$AH/s-vm.out"
check "refused dispatch: previous output archived as .prev" grep -qx second-run "$AH/s-vm.out.prev"
printf 'echo early\nQCTL_TARGET=myvm\n' > "$AH/s-late.sh"
runq guard-late 5 QCTL_WORK=wq QCTL_WORK_USER=agent QCTL_SRC_DIR="$AH" -- myvm s-late

echo "== F: pull failure =="
runq pull-missing 1 QCTL_WORK=wq QCTL_WORK_USER=agent QCTL_SRC_DIR="$AH" -- myvm s-none
check "pull error names the user" grep -q 'can agent read it' "$T/pull-missing.stdout"

echo "== G: atomic publication under slow delivery (the documented watcher) =="
printf 'QCTL_TARGET=dom0\necho RESULT: OK\n' > "$WQ/s-slow.sh"
rm -f "$WQ/s-slow.out"                                     # the recipe: clear the watched path first
# The watcher is bounded: if publication regresses, it must fail the suite, not
# hang it in `wait`.
timeout 30 bash -c 'until [ -f "$1" ]; do sleep 0.05; done; tail -n 1 "$1"' _ "$WQ/s-slow.out" > "$T/watch.txt" &
wpid=$!
runq slow-ship 0 QCTL_WORK=wq QCTL_SRC_DIR="$WQ" SHIM_SLOW_SHIP=1 -- dom0 s-slow
wait "$wpid"; wrc=$?
check "watcher returned before its 30 s deadline" [ "$wrc" -eq 0 ]
check "watcher saw a complete file (footer is its last line)" grep -Eq "$(printf "$footer_re" s-slow dom0 0)" "$T/watch.txt"
check "no .part left behind" absent "$WQ/s-slow.out.part"

echo "== H: truncated delivery is not published =="
runq truncated-ship 3 QCTL_WORK=wq QCTL_SRC_DIR="$WQ" SHIM_TRUNCATE_SHIP=1 -- dom0 s-slow
check "exit 3 message names the dom0 copy" grep -q 'failed to ship output back' "$T/truncated-ship.stdout"
check "no .out published" absent "$WQ/s-slow.out"
check "no .part left behind" absent "$WQ/s-slow.out.part"
check "previous output archived as .prev" has_footer "$WQ/s-slow.out.prev" s-slow dom0 0
check "dom0 copy still complete" has_footer "$T/faketmp/qctl-s-slow.out" s-slow dom0 0

echo
echo "RESULT: pass=$pass fail=$fail"
if [ "${KEEP:-0}" != 1 ]; then rm -rf "$T"; fi
[ "$fail" -eq 0 ]
