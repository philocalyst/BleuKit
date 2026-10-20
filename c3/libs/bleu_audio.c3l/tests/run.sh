#!/usr/bin/env bash
# Live integration test for bleu_audio against a PulseAudio native-protocol server.
#
#   libs/bleu_audio.c3l/tests/run.sh mock      the python mock server (pulse_mock.py)
#   libs/bleu_audio.c3l/tests/run.sh nocookie  the same checks with no cookie file
#                                              anywhere: the mock takes any cookie, and
#                                              discovery finds none
#   libs/bleu_audio.c3l/tests/run.sh real      the PulseAudio daemon already running at
#                                              $PULSE_SERVER or $XDG_RUNTIME_DIR/pulse/native
#
# Needs c3c and python3 (mock modes). Each check prints PASS or FAIL; the exit
# status is the number of failures, or 2 when the program cannot be built. The
# program runs under `timeout`: a hang counts as a failure (exit 124).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mode="${1:-mock}"
work="$(mktemp -d)"
pids=()
case "$mode" in mock|nocookie|real) ;; *) echo "usage: run.sh mock|nocookie|real" >&2; exit 2 ;; esac

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

head -c 256 /dev/urandom >"$work/cookie"
export BLEU_AUDIO_COOKIE="$work/cookie" BLEU_AUDIO_MODE="$mode"

if [ "$mode" = mock ]; then
  export BLEU_AUDIO_SOCKET="$work/native"
  python3 -I "$here/pulse_mock.py" "$work/native" "$work/cookie" >"$work/mock.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 100); do [ -S "$work/native" ] && break; sleep 0.05; done
elif [ "$mode" = nocookie ]; then
  # No cookie file: the mock is started without one (it then accepts any cookie),
  # and the environment offers no cookie path, so discovery finds nothing.
  export BLEU_AUDIO_SOCKET="$work/native" BLEU_AUDIO_COOKIE=""
  mkdir -p "$work/home"
  unset PULSE_COOKIE XDG_CONFIG_HOME PULSE_SERVER
  export HOME="$work/home" BLEU_AUDIO_MODE=mock
  python3 -I "$here/pulse_mock.py" "$work/native" "" >"$work/mock.log" 2>&1 &
  pids+=("$!")
  for _ in $(seq 100); do [ -S "$work/native" ] && break; sleep 0.05; done
else
  if [ -n "${PULSE_SERVER:-}" ]; then
    export BLEU_AUDIO_SOCKET="${PULSE_SERVER#unix:}"
  else
    export BLEU_AUDIO_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
  fi
fi

libdir="$(TMPDIR="$work" "$repo/tools/libdir.sh")"
c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_service --lib bleu_win --lib bleu_objc --lib bleu_audio \
  compile "$here/integration_main.c3" -o "$work/integration" >"$work/build.log" 2>&1 || {
  cat "$work/build.log"; rm -rf "$libdir"; exit 2; }
rm -rf "$libdir"
timeout 300 "$work/integration"
