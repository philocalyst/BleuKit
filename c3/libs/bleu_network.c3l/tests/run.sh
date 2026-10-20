#!/usr/bin/env bash
# Runs the bleu_network Linux backend against fakes:
#   * a private dbus-daemon with tests/nm_mock.py serving org.freedesktop.NetworkManager,
#   * a fake /sys/class/net tree for the Ethernet and Wi-Fi interfaces,
#   * the C3 unit tests (src/*_test.c3) and the end-to-end scenario (tests/nm_scenario_test.c3).
#
#   libs/bleu_network.c3l/tests/run.sh
#
# Needs dbus-daemon, c3c and python3. BLEU_NETWORK_PYTHON may name a python that
# has dbus-next; otherwise a virtual environment is created and dbus-next is
# installed into it (pypi.org access needed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
pids=()

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  if [ -n "${BLEU_NETWORK_KEEP:-}" ]; then say "kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

python_with_dbus_next() {
  if [ -n "${BLEU_NETWORK_PYTHON:-}" ]; then echo "$BLEU_NETWORK_PYTHON"; return; fi
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q dbus-next >"$work/pip.log" 2>&1 || {
    say "could not install dbus-next (see $work/pip.log)"; exit 2; }
  echo "$work/venv/bin/python"
}

PYTHON="$(python_with_dbus_next)"

# 1. A private system bus: the backend's default is the system bus, which the
#    tests reach through DBUS_SYSTEM_BUS_ADDRESS.
conf="$work/bus.conf"
cat >"$conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:tmpdir=$work</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
dbus-daemon --config-file="$conf" --nofork --print-address=1 >"$work/address" 2>"$work/daemon.log" &
pids+=("$!")
for _ in $(seq 1 100); do [ -s "$work/address" ] && break; sleep 0.05; done
bus="$(head -n1 "$work/address")"
say "bus: $bus"

# 2. The NetworkManager mock on that bus.
DBUS_SYSTEM_BUS_ADDRESS="$bus" "$PYTHON" -I "$here/nm_mock.py" >"$work/mock.out" 2>"$work/mock.err" &
pids+=("$!")
for _ in $(seq 1 200); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
grep -q READY "$work/mock.out" || { say "the mock did not start:"; cat "$work/mock.err"; exit 2; }
say "mock: READY"

# 3. A fake sysfs root with one wired and one wireless interface.
root="$work/root"
for dev in eth0 wlan0; do mkdir -p "$root/sys/class/net/$dev/statistics"; done
printf 'up\n' >"$root/sys/class/net/eth0/operstate"
printf '1\n' >"$root/sys/class/net/eth0/carrier"
printf '1000\n' >"$root/sys/class/net/eth0/speed"
printf '12345\n' >"$root/sys/class/net/eth0/statistics/rx_bytes"
printf '678\n' >"$root/sys/class/net/eth0/statistics/tx_bytes"
printf 'up\n' >"$root/sys/class/net/wlan0/operstate"
printf '1\n' >"$root/sys/class/net/wlan0/carrier"
printf '%s\n' -1 >"$root/sys/class/net/wlan0/speed"
printf '1000\n' >"$root/sys/class/net/wlan0/statistics/rx_bytes"
printf '2000\n' >"$root/sys/class/net/wlan0/statistics/tx_bytes"

# 4. The C3 tests against the fakes. The scenario reads its bus and root from the environment.
export BLEU_NETWORK_TEST_BUS="$bus" BLEU_NETWORK_TEST_ROOT="$root"
# BLEU_LIBDIR may name a libdir built by the caller (for example with a committed bleu_dbus).
if [ -n "${BLEU_LIBDIR:-}" ]; then ld="$BLEU_LIBDIR"; else ld="$(cd "$repo" && tools/libdir.sh)"; fi
cleanup_all() { cleanup; [ -n "${BLEU_LIBDIR:-}" ] || rm -rf "$ld"; }
trap cleanup_all EXIT
cd "$repo" || exit 2
src="libs/bleu_network.c3l/src"
c3c --libdir "$ld" \
  --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_dbus --lib bleu_objc --lib bleu_win --lib bleu_network \
  compile-test "$src"/nm_convert_test.c3 "$src"/nm_settings_test.c3 "$src"/sysfs_test.c3 "$src"/ssid_test.c3 \
    "$here/nm_scenario_test.c3"
status=$?
say "compile-test exit status: $status"
exit "$status"
