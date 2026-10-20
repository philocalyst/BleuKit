#!/usr/bin/env bash
# Runs the BlueZ backend against a mock org.bluez on a private dbus-daemon.
#
#   libs/bleu_bluetooth.c3l/tests/run.sh
#
# Starts a session-style dbus-daemon on a temporary socket, starts mock_bluez.py
# (python-dbus-next) as org.bluez on it, makes a fake rfkill tree, and runs the
# compiled integration program bluez_integration.c3 against them. Needs
# dbus-daemon, c3c and python3; set BLEU_BLUETOOTH_PYTHON to a python that has
# dbus-next, otherwise a virtual environment is created with pip.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
pids=()

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

if [ -n "${BLEU_BLUETOOTH_PYTHON:-}" ]; then
  PYTHON="$BLEU_BLUETOOTH_PYTHON"
else
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    echo "could not install dbus-next (see $work/pip.log)"; exit 2; }
  PYTHON="$work/venv/bin/python"
fi

# 1. A private bus, as a session bus with EXTERNAL auth.
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
address="$(head -n1 "$work/address")"
export DBUS_SESSION_BUS_ADDRESS="$address"

# 2. The mock org.bluez.
"$PYTHON" -I "$here/mock_bluez.py" >"$work/mock.out" 2>"$work/mock.err" &
pids+=("$!")
for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
grep -q READY "$work/mock.out" || { echo "mock did not start:"; cat "$work/mock.err"; exit 2; }

# 3. A fake rfkill tree with one Bluetooth switch, not blocked.
mkdir -p "$work/root/sys/class/rfkill/rfkill0"
echo bluetooth >"$work/root/sys/class/rfkill/rfkill0/type"
echo 0 >"$work/root/sys/class/rfkill/rfkill0/soft"
echo 0 >"$work/root/sys/class/rfkill/rfkill0/hard"

# 4. The C3 client.
bin="$work/bluez_integration"
c3c --libdir "${BLEU_BLUETOOTH_LIBDIR:-$(bash "$repo/tools/libdir.sh")}" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus \
  --lib bleu_dl --lib bleu_objc --lib bleu_win --lib bleu_bluetooth \
  compile "$here/bluez_integration.c3" -o "$bin" >"$work/compile.log" 2>&1 || { cat "$work/compile.log"; exit 2; }
timeout 180 "$bin" "$address" "$work/root"
status=$?
echo "exit status: $status"
exit "$status"
