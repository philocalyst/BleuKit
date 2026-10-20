#!/usr/bin/env bash
# Runs bleu_ipc's protocol checks: the in-process C3 tests (every src/*_test.c3 and
# integration_test.c3) and the raw-socket Python checks against a live server.
#
#   libs/bleu_ipc.c3l/tests/run.sh
#
# Builds in private scratch directories, so concurrent runs and the source tree stay
# clean. Every run is bounded by `timeout`.
set -eu
here="$(cd "$(dirname "$0")/../../.." && pwd)"
lib="$here/libs/bleu_ipc.c3l"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
libdir="$("$here/tools/libdir.sh")"
cd "$work"
echo "== in-process unit and integration tests"
timeout "${TEST_TIMEOUT:-600}" c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_ipc \
  compile-test "$lib"/src/*.c3 -o "$work/testrun"
echo "== raw-socket protocol checks (Python3, against an in-process server)"
timeout "${TEST_TIMEOUT:-600}" c3c --libdir "$libdir" --lib bleu_core --lib bleu_rt --lib bleu_ipc \
  compile "$lib"/tests/protocol_driver.c3 -o "$work/driver"
timeout 60 "$work/driver" "$work/protocol.sock" "$lib/tests/raw_protocol.py"
