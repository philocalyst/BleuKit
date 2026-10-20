#!/usr/bin/env bash
# End-to-end test of the dgop, apps, evdev and refusal modules of dmsd, and of the clipboard
# module's absence. The daemon runs without a bus, a Wayland display or a logind; the XDG
# directories are a private tree written here; /proc is read as it is (dgop is checked
# against it).
#
#   apps/dmsd/tests/modules.sh <dmsd binary> <python3>
#
# Called from run.sh. Exit status 0 when every check passed.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
dmsd_bin="${1:?usage: modules.sh <dmsd binary> <python3>}"
python="${2:?usage: modules.sh <dmsd binary> <python3>}"
# A short work path: a Unix socket path is limited to 108 bytes.
work="$(mktemp -d /tmp/dmsdm.XXXXXX)"
status=0
dmsd_pid=""
cleanup() {
  [ -n "$dmsd_pid" ] && kill "$dmsd_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

echo "== modules: dgop, apps, evdev, refusals (no clipboard: no Wayland display)"

# XDG data: two desktop files and a mimeapps.list. vim is a terminal application
# (Terminal=true), which handlersForMime leaves out.
mkdir -p "$work/xdg/data/applications" "$work/xdg/config" "$work/run"
chmod 700 "$work/run"
cat >"$work/xdg/data/applications/firefox.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=firefox %u
Icon=firefox
MimeType=text/html;x-scheme-handler/http;
EOF
cat >"$work/xdg/data/applications/vim.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Vim
Exec=vim %F
Terminal=true
MimeType=text/plain;
EOF
cat >"$work/xdg/config/mimeapps.list" <<'EOF'
[Default Applications]
text/html=firefox.desktop
EOF

sock="$work/d.sock"
# WAYLAND_DISPLAY is removed so the clipboard module cannot start, whatever the host has.
env -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work/run" \
  XDG_DATA_HOME="$work/xdg/data" XDG_CONFIG_HOME="$work/xdg/config" XDG_DATA_DIRS=/nonexistent \
  DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/no-bus.sock" \
  "$dmsd_bin" --socket "$sock" --debug \
  --module-off loginctl --module-off brightness --module-off bluetooth --module-off network \
  >"$work/dmsd.out" 2>"$work/dmsd.err" &
dmsd_pid=$!
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.05; done
if [ ! -S "$sock" ]; then
  echo "FAIL dmsd did not start (see $work/dmsd.err)"; cat "$work/dmsd.err"; exit 1
fi

if "$python" "$here/check_modules.py" "$sock" "$here" >"$work/check.log" 2>&1; then
  echo "ok   module checks ($(grep -c '^ok' "$work/check.log") checks)"
else
  echo "FAIL module checks"; grep -v "^ok" "$work/check.log" | head -60; status=1
fi

# The start-up reports: clipboard is absent once, apps and dgop are not.
if [ "$(grep -c 'clipboard: not started' "$work/dmsd.err")" -eq 1 ]; then
  echo "ok   clipboard reported absent once"
else
  echo "FAIL clipboard absence not reported once"; cat "$work/dmsd.err"; status=1
fi
for module in apps dgop; do
  if grep -q "$module: not started" "$work/dmsd.err"; then
    echo "FAIL $module did not start"; cat "$work/dmsd.err"; status=1
  else
    echo "ok   $module started"
  fi
done

echo "== shutdown on SIGTERM with the modules running"
kill -TERM "$dmsd_pid"
for _ in $(seq 100); do kill -0 "$dmsd_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$dmsd_pid" 2>/dev/null; then
  echo "FAIL dmsd did not stop within 5 s"; status=1; kill -KILL "$dmsd_pid"
else
  wait "$dmsd_pid"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   exit status 0 after SIGTERM"; else echo "FAIL exit status $rc"; status=1; fi
fi
dmsd_pid=""
if grep -q "LEAKS\|Out of bounds\|ERROR" "$work/dmsd.err"; then
  echo "FAIL dmsd reported a leak or an error"; cat "$work/dmsd.err"; status=1
else
  echo "ok   no leak or runtime error reported"
fi

if [ "$status" -eq 0 ]; then echo "modules: PASSED"; else echo "modules: FAILED"; fi
exit "$status"
