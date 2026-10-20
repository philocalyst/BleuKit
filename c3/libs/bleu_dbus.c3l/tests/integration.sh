#!/usr/bin/env bash
# Live integration test for bleu_dbus.
#
# Starts a private dbus-daemon (abstract and filesystem listen addresses), a
# python-dbus-next mock service, and runs the C3 client against them. Then stops
# the bus under a connected client and checks it reports DISCONNECTED.
#
#   libs/bleu_dbus.c3l/tests/integration.sh
#
# Needs dbus-daemon, c3c and python3. Set BLEU_DBUS_PYTHON to a python that has
# dbus-next; otherwise a virtual environment is created in the work directory
# and dbus-next is installed into it (network access to pypi.org needed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
pids=()
failed=0

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

python_with_dbus_next() {
  if [ -n "${BLEU_DBUS_PYTHON:-}" ]; then
    echo "$BLEU_DBUS_PYTHON"
    return
  fi
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  echo "$work/venv/bin/python"
}

# Writes a session bus configuration listening on $1 and starts the daemon.
# Sets BUS_PID and DBUS_SESSION_BUS_ADDRESS.
start_bus() {
  local listen="$1" conf="$work/bus.conf"
  cat >"$conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>$listen</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
  rm -f "$work/address"
  dbus-daemon --config-file="$conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
  BUS_PID=$!
  pids+=("$BUS_PID")
  for _ in $(seq 1 100); do
    [ -s "$work/address" ] && break
    sleep 0.05
  done
  DBUS_SESSION_BUS_ADDRESS="$(head -n1 "$work/address")"
  export DBUS_SESSION_BUS_ADDRESS
  say "bus: $DBUS_SESSION_BUS_ADDRESS"
}

# Starts the mock service on the current bus and waits until it owns its name.
start_mock() {
  "$PYTHON" -I "$here/integration/mock_service.py" >"$work/mock.out" 2>"$work/mock.err" &
  MOCK_PID=$!
  pids+=("$MOCK_PID")
  for _ in $(seq 1 200); do
    grep -q READY "$work/mock.out" 2>/dev/null && return 0
    sleep 0.05
  done
  say "the mock service did not start:"; cat "$work/mock.err"; exit 2
}

compile() { # source output
  c3c --libdir "$repo/libs" --lib bleu_core --lib bleu_dbus compile "$1" -o "$2" >"$2.log" 2>&1 || {
    say "compile failed: $1"; cat "$2.log"; exit 2; }
}

PYTHON="$(python_with_dbus_next)"
export PYTHON

# 1. The full client test, on an abstract socket and on a filesystem socket.
compile "$here/integration/main.c3" "$work/integration"
for listen in "unix:tmpdir=$work" "unix:path=$work/bus-socket"; do
  say "== suite: $listen"
  start_bus "$listen"
  start_mock
  timeout 180 "$work/integration" >"$work/suite.out" 2>&1
  status=$?
  cat "$work/suite.out"
  say "exit status: $status"
  [ "$status" -eq 0 ] || failed=1
  kill "$MOCK_PID" "$BUS_PID" 2>/dev/null
  wait "$MOCK_PID" "$BUS_PID" 2>/dev/null
done

# 2. A client whose bus disappears: process() must say DISCONNECTED.
say "== suite: disconnect"
compile "$here/integration/disconnect.c3" "$work/disconnect"
start_bus "unix:tmpdir=$work"
"$work/disconnect" >"$work/disconnect.out" 2>&1 &
client=$!
for _ in $(seq 1 200); do
  grep -q CONNECTED "$work/disconnect.out" 2>/dev/null && break
  sleep 0.05
done
kill "$BUS_PID"
wait "$BUS_PID" 2>/dev/null
wait "$client"
cat "$work/disconnect.out"
grep -q '^DISCONNECTED' "$work/disconnect.out" || { say "no DISCONNECTED report"; failed=1; }
grep -q '^REOPEN error::UNAVAILABLE' "$work/disconnect.out" || { say "reopen did not fail with UNAVAILABLE"; failed=1; }

if [ "$failed" -eq 0 ]; then say "INTEGRATION OK"; else say "INTEGRATION FAILED"; fi
exit "$failed"
