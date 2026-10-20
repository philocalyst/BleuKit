#!/usr/bin/env bash
# Live test of the portal backend of bleu_hotkey against a mock xdg-desktop-portal on a private session bus.
#
#   libs/bleu_hotkey.c3l/tests/run.sh
#
# 1. starts a private dbus-daemon (a session-style bus) and exports DBUS_SESSION_BUS_ADDRESS to it;
# 2. starts mock_portal.py (python-dbus-next) which owns org.freedesktop.portal.Desktop there;
# 3. runs portal_live.c3: the backend binds, reports, and follows the mock through its control file;
# 4. stops the mock and runs portal_absent.c3: with no portal on the bus the backend must refuse.
#
# Needs dbus-daemon, c3c, python3. Set BLEU_HOTKEY_PYTHON to a python that has dbus-next; otherwise a
# virtual environment is created in the work directory (needs pypi access).
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

if [ -n "${BLEU_HOTKEY_PYTHON:-}" ]; then
  PYTHON="$BLEU_HOTKEY_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# A session bus of our own: the portal client reaches it through DBUS_SESSION_BUS_ADDRESS.
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
DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"
export DBUS_SESSION_BUS_ADDRESS
say "bus: $DBUS_SESSION_BUS_ADDRESS"

: >"$work/control"
export BLEU_HOTKEY_CONTROL="$work/control"

start_mock() {
  "$PYTHON" -I "$here/mock_portal.py" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && return 0; sleep 0.05; done
  say "the mock did not start:"; cat "$work/mock.err"; exit 2
}

# The sources: every module of the library except the test files, for Linux only.
sources=()
for f in "$lib"/src/*.c3; do
  case "$f" in
    *_test.c3|*_macos*|*_windows*|*/carbon*.c3|*/windows.c3|*/driver_macos.c3|*/driver_windows.c3) ;;
    *) sources+=("$f") ;;
  esac
done
libs=(--lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus --lib bleu_dl --lib bleu_win)
ld="${BLEU_LIBDIR:-$("$repo/tools/libdir.sh")}"   # BLEU_LIBDIR: a library directory to test against

start_mock
set -e
# c3c writes its build output to the working directory: keep it in the work directory.
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile-test "$here/portal_live.c3" --sources "${sources[@]}")
say "live: passed"
set +e
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
set -e
(cd "$work" && c3c --libdir "$ld" "${libs[@]}" compile-test "$here/portal_absent.c3" --sources "${sources[@]}")
say "absent: passed"
