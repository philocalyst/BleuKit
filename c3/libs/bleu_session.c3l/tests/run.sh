#!/usr/bin/env bash
# Live test of the logind backend of bleu_session against a mock systemd-logind on a private bus.
#
#   libs/bleu_session.c3l/tests/run.sh
#
# 1. starts a private dbus-daemon and exports DBUS_SYSTEM_BUS_ADDRESS to it;
# 2. starts mock_logind.py (python-dbus-next), which owns org.freedesktop.login1 there;
# 3. runs logind_live.c3 (the backend reads, locks, unlocks, sleeps and follows the mock);
# 4. checks the calls the mock logged;
# 5. runs logind_late.c3 against a mock whose session appears two seconds late (the session is found later);
# 6. stops the mock and runs logind_absent.c3 (the backend must refuse without the name).
#
# Needs dbus-daemon, c3c, python3. Set BLEU_SESSION_PYTHON to a python that has dbus-next;
# otherwise a virtual environment is created in the work directory (needs pypi access).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d)"
pids=()

cleanup() {
  set +e  # a process that already exited makes kill fail; that is not an error here
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

if [ -n "${BLEU_SESSION_PYTHON:-}" ]; then
  PYTHON="$BLEU_SESSION_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# A session-style private bus; the logind client reaches it through DBUS_SYSTEM_BUS_ADDRESS.
cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$work</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
dbus-daemon --config-file="$work/bus.conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
pids+=("$!")
for _ in $(seq 1 100); do [ -s "$work/address" ] && break; sleep 0.05; done
DBUS_SYSTEM_BUS_ADDRESS="$(head -n1 "$work/address")"
export DBUS_SYSTEM_BUS_ADDRESS
say "bus: $DBUS_SYSTEM_BUS_ADDRESS"

start_mock() {
  BLEU_LOGIND_LOG="$work/calls.log" "$PYTHON" -I "$here/mock_logind.py" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && return 0; sleep 0.05; done
  say "the mock did not start:"; cat "$work/mock.err"; exit 2
}

# The sources: every module of the library except the test files.
sources=()
for f in "$lib"/src/*.c3; do case "$f" in *_test.c3) ;; *) sources+=("$f") ;; esac; done
libs=(--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_objc --lib bleu_win --lib bleu_dbus --lib bleu_dl --lib bleu_session)
ld="${BLEU_LIBDIR:-$("$repo/tools/libdir.sh")}"   # BLEU_LIBDIR: a library directory to test against

start_mock
set -e
# c3c writes its build output to the working directory: keep it in the work directory.
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile-test "$here/logind_live.c3" --sources "${sources[@]}")
say "live: passed"
# Every call the backend made must have reached the mock, in order.
expected=$'LockSession 32\nUnlockSession 32\nLockSession c1\nTerminateSession nope\nSuspend false'
logged="$(cat "$work/calls.log")"
[ "$logged" = "$expected" ] || { say "calls differ from the expected sequence:"; printf '%s\n' "$logged"; exit 1; }
say "calls: passed"
set +e
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
set -e

# This process is in no session for the first two seconds: the backend must find its session when it appears.
BLEU_LOGIND_LATE_SESSION_SECONDS=2 BLEU_LOGIND_LOG= "$PYTHON" -I "$here/mock_logind.py" >"$work/late.out" 2>"$work/late.err" &
LATE_PID=$!
pids+=("$LATE_PID")
for _ in $(seq 1 200); do grep -q READY "$work/late.out" 2>/dev/null && break; sleep 0.05; done
grep -q READY "$work/late.out" || { say "the late mock did not start:"; cat "$work/late.err"; exit 2; }
set -e
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile-test "$here/logind_late.c3" --sources "${sources[@]}")
say "late session: passed"
set +e
kill "$LATE_PID" 2>/dev/null; wait "$LATE_PID" 2>/dev/null
set -e
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile-test "$here/logind_absent.c3" --sources "${sources[@]}")
say "absent: passed"
