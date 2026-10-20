#!/usr/bin/env bash
# Verify the Bleu C ABI from C, C++ and Python, against fake sysfs trees.
#
#   tools/capi/tests/run.sh            (after tools/capi/build.sh)
#
# Needs gcc, g++, python3, and valgrind (optional: the leak check is skipped without it).
# Each consumer gets its own fresh fake tree: they change the files they watch.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
lib="${CAPI_OUT:-$repo/out/capi}"
inc="$repo/include"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0

fake_tree() {  # fake_tree <dir>: the sysfs files the consumers read and write
  local root="$1"
  mkdir -p "$root/sys/class/power_supply/AC" "$root/sys/class/power_supply/BAT0" "$root/sys/class/backlight/intel_backlight"
  printf 'Mains\n' > "$root/sys/class/power_supply/AC/type"
  printf '1\n' > "$root/sys/class/power_supply/AC/online"
  local bat="$root/sys/class/power_supply/BAT0"
  printf 'Battery\n' > "$bat/type"; printf 'Charging\n' > "$bat/status"
  printf 'Li-ion\n' > "$bat/technology"; printf 'ACME\n' > "$bat/manufacturer"
  printf 'Cell9\n' > "$bat/model_name"; printf '1\n' > "$bat/present"
  printf '11100000\n' > "$bat/voltage_now"; printf '1000000\n' > "$bat/charge_now"
  printf '2000000\n' > "$bat/charge_full"; printf '2500000\n' > "$bat/charge_full_design"
  printf '1500000\n' > "$bat/current_now"; printf '212\n' > "$bat/cycle_count"; printf '312\n' > "$bat/temp"
  local bl="$root/sys/class/backlight/intel_backlight"
  printf 'firmware\n' > "$bl/type"; printf '48000\n' > "$bl/brightness"
  printf '48000\n' > "$bl/actual_brightness"; printf '96000\n' > "$bl/max_brightness"
}

test -f "$lib/libbleu_capi.so" || { echo "run tools/capi/build.sh first ($lib has no library)"; exit 2; }
cflags=(-std=c11 -Wall -Wextra -pedantic -Werror -I"$inc")
ldflags=(-L"$lib" -Wl,-rpath,"$lib" -lbleu_capi -lpthread -ldl -lm)

step() { echo; echo "== $*"; }

step "C11 (gcc), shared library"
gcc "${cflags[@]}" "$here/capi_smoke.c" -o "$work/smoke" "${ldflags[@]}"
fake_tree "$work/root-c"
"$work/smoke" "$work/root-c" || status=1

step "C11 (gcc), static library"
gcc "${cflags[@]}" "$here/capi_smoke.c" -o "$work/smoke-static" "$lib/libbleu_capi.a" -lpthread -ldl -lm
fake_tree "$work/root-static"
"$work/smoke-static" "$work/root-static" || status=1

step "two translation units including the header"
gcc "${cflags[@]}" -c "$here/tu_main.c" -o "$work/tu_main.o"
gcc "${cflags[@]}" -c "$here/tu_other.c" -o "$work/tu_other.o"
gcc "$work/tu_main.o" "$work/tu_other.o" -o "$work/tu" "${ldflags[@]}"
"$work/tu" || status=1

step "C++ (g++)"
g++ -std=c++17 -Wall -Wextra -pedantic -Werror -I"$inc" "$here/capi_cxx.cpp" -o "$work/cxx" "${ldflags[@]}"
fake_tree "$work/root-cxx"
"$work/cxx" "$work/root-cxx" || status=1

step "Python ctypes"
fake_tree "$work/root-py"
python3 -I "$here/capi_ctypes.py" "$lib/libbleu_capi.so" "$work/root-py" || status=1

if command -v valgrind >/dev/null 2>&1; then
  step "valgrind (C test, shared library)"
  fake_tree "$work/root-vg"
  valgrind --leak-check=full --errors-for-leak-kinds=definite,indirect --error-exitcode=9 \
    --log-file="$work/valgrind.log" "$work/smoke" "$work/root-vg" >/dev/null || status=1
  grep -E "ERROR SUMMARY|definitely lost|indirectly lost" "$work/valgrind.log" || true
else
  step "valgrind not installed: leak check skipped"
fi

echo
if [ "$status" = 0 ]; then echo "capi verification: PASS"; else echo "capi verification: FAIL"; fi
exit "$status"
