#!/usr/bin/env bash
# End-to-end test of dmsd's `network` module: the DMS methods and topics over the socket, against
# the NetworkManager mock that libs/bleu_network ships (tests/nm_mock.py) on a private system bus,
# and a fake sysfs tree with eth0 and wlan0. Nothing touches the real bus or /sys.
#
#   apps/dmsd/tests/network.sh <dmsd binary> <python with dbus-next>
#
# Called by run.sh with the binary it built. Checks: every reply (network_check.py), the shutdown
# on SIGTERM, and what an absent NetworkManager or `--module-off network` does to the handshake.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mock="$repo/libs/bleu_network.c3l/tests/nm_mock.py"
dmsd="${1:?usage: network.sh <dmsd binary> <python>}"
python="${2:?usage: network.sh <dmsd binary> <python>}"
# A Unix socket path is limited to 108 bytes, so the work directory is short.
work="$(mktemp -d /tmp/dmsdnet.XXXXXX)"
pids=()
status=0

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# Start a private system bus; its address is in "$work/<name>.address" (not printed: a command
# substitution would start the daemon in a subshell, outside `pids`). $1: the name of its files.
start_bus() {
  local name="$1"
  cat >"$work/$name.conf" <<XML
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
  dbus-daemon --config-file="$work/$name.conf" --nofork --print-address=1 >"$work/$name.address" 2>"$work/$name.log" &
  pids+=($!)
  for _ in $(seq 100); do [ -s "$work/$name.address" ] && break; sleep 0.05; done
}

# The mock with every fault switched off, on the bus at $1.
start_mock() {
  local bus="$1"
  mkdir -p "$work/faults"
  for name in wifi-fail vanish-ap no-agent; do printf '0\n' >"$work/faults/$name"; done
  DBUS_SYSTEM_BUS_ADDRESS="$bus" BLEU_NETWORK_TEST_FAULTS="$work/faults" "$python" -I -B "$mock" \
    >"$work/mock.out" 2>"$work/mock.err" &
  pids+=($!)
  for _ in $(seq 200); do grep -q READY "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
  if ! grep -q READY "$work/mock.out"; then echo "FAIL the NetworkManager mock did not start"; cat "$work/mock.err"; exit 2; fi
}

# One wired and one wireless interface, as the mock's visible networks expect.
make_sysfs() {
  local root="$1" dev
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
}

# Start dmsd on the bus at $1 with the extra arguments after it; waits for its socket. Sets `dmsd_pid`.
start_dmsd() {
  local bus="$1" sock="$2"
  shift 2
  DBUS_SYSTEM_BUS_ADDRESS="$bus" "$dmsd" --socket "$sock" --fake-root "$work/root" "$@" \
    >"$work/$(basename "$sock").out" 2>"$work/$(basename "$sock").err" &
  dmsd_pid=$!
  pids+=($dmsd_pid)
  for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.05; done
}

# The handshake line of a daemon on $1, as its capability list.
capabilities_of() {
  "$python" -I -c "
import socket, json, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
print(' '.join(json.loads(s.makefile('rb').readline().decode())['capabilities']))
" "$1"
}

start_bus bus
bus="$(head -n1 "$work/bus.address")"
start_mock "$bus"
mkdir -p "$work/root"
make_sysfs "$work/root"

echo "== network: the methods, the topics and the prompt stream"
sock="$work/dmsd.sock"
start_dmsd "$bus" "$sock"
caps="$(capabilities_of "$sock")"
if echo " $caps " | grep -q " network "; then
  echo "ok   network is advertised (capabilities: $caps)"
else
  echo "FAIL network is not advertised (capabilities: $caps)"; cat "$work/dmsd.sock.err"; status=1
fi
if "$python" -I "$here/network_check.py" "$sock" "$here" >"$work/check.log" 2>&1; then
  echo "ok   network checks ($(grep -c '^ok' "$work/check.log") checks)"
else
  echo "FAIL network checks"; grep -v '^ok' "$work/check.log" | head -40; status=1
fi

echo "== network: shutdown on SIGTERM"
kill -TERM "$dmsd_pid"
for _ in $(seq 100); do kill -0 "$dmsd_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$dmsd_pid" 2>/dev/null; then
  echo "FAIL dmsd did not stop within 5 s"; status=1; kill -KILL "$dmsd_pid"
else
  wait "$dmsd_pid"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   exit status 0 after SIGTERM"; else echo "FAIL exit status $rc"; status=1; fi
fi
if grep -q "LEAKS\|Out of bounds\|ERROR" "$work/dmsd.sock.err"; then
  echo "FAIL dmsd reported a leak or an error"; cat "$work/dmsd.sock.err"; status=1
else
  echo "ok   no leak or runtime error reported"
fi

echo "== network: an absent NetworkManager is reported once and not advertised"
start_bus empty-bus
empty_bus="$(head -n1 "$work/empty-bus.address")"
sock="$work/absent.sock"
start_dmsd "$empty_bus" "$sock"
caps="$(capabilities_of "$sock")"
kill -TERM "$dmsd_pid"; wait "$dmsd_pid" 2>/dev/null
if ! echo " $caps " | grep -q " network "; then
  echo "ok   network not advertised without NetworkManager"
else
  echo "FAIL network advertised without NetworkManager: $caps"; status=1
fi
if [ "$(grep -c 'network: not started' "$work/absent.sock.err")" -eq 1 ]; then
  echo "ok   network reported once: $(grep 'network: not started' "$work/absent.sock.err")"
else
  echo "FAIL network not reported once"; cat "$work/absent.sock.err"; status=1
fi

echo "== network: --module-off network leaves the module out"
sock="$work/off.sock"
start_dmsd "$bus" "$sock" --module-off network
caps="$(capabilities_of "$sock")"
kill -TERM "$dmsd_pid"; wait "$dmsd_pid" 2>/dev/null
if ! echo " $caps " | grep -q " network "; then
  echo "ok   --module-off network: not advertised"
else
  echo "FAIL --module-off network still advertised: $caps"; status=1
fi

if [ "$status" -eq 0 ]; then echo "NETWORK PASSED"; else echo "NETWORK FAILED"; fi
exit "$status"
