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

# Only the two libraries this test needs are visible to the compiler, so other
# libraries under construction in libs/ cannot break it.
libdir="$work/libs"
mkdir -p "$libdir"
ln -s "$repo/libs/bleu_core.c3l" "$libdir/bleu_core.c3l"
ln -s "$repo/libs/bleu_dbus.c3l" "$libdir/bleu_dbus.c3l"

compile() { # source output
  c3c --libdir "$libdir" --lib bleu_core --lib bleu_dbus compile "$1" -o "$2" >"$2.log" 2>&1 || {
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

# 2. A client whose bus disappears and comes back at the same address: process()
#    must say DISCONNECTED, reopening must fail while the bus is down, and must
#    succeed once the bus is restarted.
say "== suite: disconnect and reconnect"
compile "$here/integration/disconnect.c3" "$work/disconnect"
start_bus "unix:path=$work/reconnect-bus"
"$work/disconnect" >"$work/disconnect.out" 2>&1 &
client=$!
for _ in $(seq 1 200); do
  grep -q CONNECTED "$work/disconnect.out" 2>/dev/null && break
  sleep 0.05
done
kill "$BUS_PID"
wait "$BUS_PID" 2>/dev/null
for _ in $(seq 1 200); do
  grep -q 'REOPEN ' "$work/disconnect.out" 2>/dev/null && break
  sleep 0.05
done
rm -f "$work/reconnect-bus"
start_bus "unix:path=$work/reconnect-bus"
wait "$client"
client_status=$?
cat "$work/disconnect.out"
[ "$client_status" -eq 0 ] || { say "the client did not reconnect (status $client_status)"; failed=1; }
grep -q '^DISCONNECTED' "$work/disconnect.out" || { say "no DISCONNECTED report"; failed=1; }
grep -q '^REOPEN error::UNAVAILABLE' "$work/disconnect.out" || { say "reopen while down did not fail with UNAVAILABLE"; failed=1; }
grep -q '^REOPENED as :1.' "$work/disconnect.out" || { say "no successful reopen after restart"; failed=1; }

# 3. The object server. This library exports org.bleu.Test at /org/bleu/ServerTest
#    (server_main.c3); the Python dbus-next client checks it (server_client.py),
#    then the C3 client does, and calls Quit, which ends the server with status 0.
compile "$here/integration/server_main.c3" "$work/server_main"
compile "$here/integration/server_client.c3" "$work/server_client"
for listen in "unix:tmpdir=$work" "unix:path=$work/server-bus"; do
  say "== suite: object server on $listen"
  start_bus "$listen"
  timeout 300 "$work/server_main" >"$work/server.out" 2>"$work/server.err" &
  server=$!
  pids+=("$server")
  for _ in $(seq 1 200); do
    grep -q READY "$work/server.out" 2>/dev/null && break
    sleep 0.05
  done
  if ! grep -q READY "$work/server.out"; then
    say "the object server did not start:"; cat "$work/server.out" "$work/server.err"; failed=1
    kill "$server" "$BUS_PID" 2>/dev/null; wait 2>/dev/null; continue
  fi
  timeout 120 "$PYTHON" -I "$here/integration/server_client.py" >"$work/server_py.out" 2>&1
  py_status=$?
  cat "$work/server_py.out"
  timeout 120 "$work/server_client" >"$work/server_c3.out" 2>&1
  c3_status=$?
  cat "$work/server_c3.out"
  wait "$server"
  server_status=$?
  say "python client: $py_status, C3 client: $c3_status, server: $server_status"
  { [ "$py_status" -eq 0 ] && [ "$c3_status" -eq 0 ] && [ "$server_status" -eq 0 ]; } || failed=1
  kill "$BUS_PID" 2>/dev/null
  wait "$BUS_PID" 2>/dev/null
done

# 4. The worked example: a notification server (examples/notifications_server_sketch.c3)
#    exporting org.freedesktop.Notifications, checked by notifications_client.py.
compile "$repo/libs/bleu_dbus.c3l/examples/notifications_server_sketch.c3" "$work/notifications"
say "== suite: notifications example"
start_bus "unix:tmpdir=$work"
timeout 300 "$work/notifications" >"$work/notifications.out" 2>&1 &
notifier=$!
pids+=("$notifier")
for _ in $(seq 1 200); do
  grep -q READY "$work/notifications.out" 2>/dev/null && break
  sleep 0.05
done
timeout 120 "$PYTHON" -I "$here/integration/notifications_client.py" >"$work/notifications_py.out" 2>&1
notify_status=$?
cat "$work/notifications_py.out"
kill "$notifier" 2>/dev/null
wait "$notifier" 2>/dev/null
say "notifications client: $notify_status"
[ "$notify_status" -eq 0 ] || failed=1
kill "$BUS_PID" 2>/dev/null
wait "$BUS_PID" 2>/dev/null

if [ "$failed" -eq 0 ]; then say "INTEGRATION OK"; else say "INTEGRATION FAILED"; fi
exit "$failed"
