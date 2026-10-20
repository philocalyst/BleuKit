#!/usr/bin/env bash
# Live test of bleu_notify's freedesktop server against python-dbus-next on a private session bus.
#
#   libs/bleu_notify.c3l/tests/run.sh
#
# 1. builds tests/server_main.c3 (the notification centre as a process) and
#    tests/notify_send.c3 (the sender as a command) with c3c;
# 2. starts a private dbus-daemon and exports DBUS_SESSION_BUS_ADDRESS to it;
# 3. runs notify_server_test.py, which drives the server and checks the bus behaviour.
#
# Needs dbus-daemon, c3c and python3. Set BLEU_NOTIFY_PYTHON to a python that has
# dbus-next; otherwise a virtual environment is created in the work directory
# (needs pypi access).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/.." && pwd)"
repo="$(cd "$lib/../.." && pwd)"
work="$(mktemp -d)"
pids=()

cleanup() {
  set +e
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

if [ -n "${BLEU_NOTIFY_PYTHON:-}" ]; then
  PYTHON="$BLEU_NOTIFY_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# A session-style private bus, listening on a short path (unix socket names are limited to 108 bytes).
sock_dir="$(mktemp -d /tmp/bleu-notify.XXXXXX)"
cat >"$work/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$sock_dir</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
trap 'rm -rf "$sock_dir"; cleanup' EXIT
dbus-daemon --config-file="$work/bus.conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
pids+=("$!")
for _ in $(seq 1 100); do [ -s "$work/address" ] && break; sleep 0.05; done
DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"
export DBUS_SESSION_BUS_ADDRESS
say "bus: $DBUS_SESSION_BUS_ADDRESS"

# Build the test server and the sender client into the work directory, never into the repository.
cd "$work" || exit 2
if ! c3c --libdir "$("$repo/tools/libdir.sh")" --lib bleu_core --lib bleu_rt --lib bleu_dbus \
     --lib bleu_service --lib bleu_objc --lib bleu_notify \
     compile "$lib/tests/server_main.c3" -o "$work/notify_test_server" >"$work/build.log" 2>&1; then
  say "build of the test server failed:"; cat "$work/build.log"; exit 2
fi
if ! c3c --libdir "$("$repo/tools/libdir.sh")" --lib bleu_core --lib bleu_rt --lib bleu_dbus \
     --lib bleu_service --lib bleu_objc --lib bleu_notify \
     compile "$lib/tests/notify_send.c3" -o "$work/notify_send" >"$work/build_send.log" 2>&1; then
  say "build of the sender client failed:"; cat "$work/build_send.log"; exit 2
fi
server="$work/notify_test_server"
sender="$work/notify_send"
"$PYTHON" -I "$lib/tests/notify_server_test.py" "$server" "$sender"
status=$?
exit $status
