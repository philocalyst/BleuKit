#!/usr/bin/env bash
# Build the Bleu C ABI: libbleu_capi.so and .a for this host, plus the public headers.
#
#   tools/capi/build.sh          build into $OUT (default c3/out/capi) and regenerate include/bleu
#   tools/capi/build.sh --check  build, and fail if include/bleu is stale; write nothing to include/
#
# 1. c3c compiles libs/bleu_capi.c3l and writes its raw header (c3c's own layout).
# 2. tools/capi/genheader.py turns that header into include/bleu/*.h and the list of exported functions.
# 3. Shared library: the linker gets a version script that exports exactly those functions (C3 exports
#    every function of a dynamic library, including its own methods, unless told otherwise). Linux only;
#    other hosts keep C3's default and say so.
# 4. nm checks that the shared library exports exactly the functions in the header, nothing else.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${OUT:-$repo/out/capi}"
check=0
if [ "${1:-}" = "--check" ]; then check=1; fi
work="$(mktemp -d)"
libdir="$("$repo/tools/libdir.sh")"
trap 'rm -rf "$work" "$libdir"' EXIT
cd "$work"  # c3c writes obj/ and out/ into the working directory

libs=(bleu_core bleu_rt bleu_service bleu_json bleu_objc bleu_win bleu_dbus bleu_ddc bleu_dl bleu_battery bleu_brightness)
args=(); for l in "${libs[@]}"; do args+=(--lib "$l"); done
sources=(); while IFS= read -r f; do sources+=("$f"); done < <(ls "$repo/libs/bleu_capi.c3l/src/"*.c3 | grep -v '_test\.c3$')
c3flags=(--libdir "$libdir" "${args[@]}" --no-entry -O1 --warn-deprecation=error --warn-deadcode=no)

echo "== c3c: header"
c3c "${c3flags[@]}" --header-output "$work/hdr" dynamic-lib "${sources[@]}" -o libbleu_capi >"$work/c3-dyn.log" 2>&1 \
  || { cat "$work/c3-dyn.log"; exit 1; }
grep -v "warning\|^ \|^$\|Dynamic library" "$work/c3-dyn.log" || true

echo "== genheader"
gen=(--header "$work/hdr/libbleu_capi.h" --src "$repo/libs/bleu_capi.c3l/src" --libs "$repo/libs" --exports "$work/exports.txt")
if [ "$check" = 1 ]; then
  python3 "$here/genheader.py" "${gen[@]}" --out "$repo/include/bleu" --check
else
  python3 "$here/genheader.py" "${gen[@]}" --out "$repo/include/bleu"
  mkdir -p "$out"
  cp "$repo/include/bleu/"*.h "$out/" 2>/dev/null || true
fi

echo "== c3c: static library"
c3c "${c3flags[@]}" static-lib "${sources[@]}" -o libbleu_capi >"$work/c3-static.log" 2>&1 \
  || { cat "$work/c3-static.log"; exit 1; }

if [ "$(uname -s)" = "Linux" ]; then
  # A version script with the exact export list. `local: *` hides everything else, including C3's internal methods.
  {
    echo "{"
    echo "  global:"
    sed 's/$/;/; s/^/    /' "$work/exports.txt"
    echo "  local: *;"
    echo "};"
  } > "$work/exports.map"
  linker="$work/ld-with-exports"
  printf '#!/usr/bin/env bash\nexec "%s" "$@" --version-script="%s"\n' "$(command -v ld)" "$work/exports.map" > "$linker"
  chmod +x "$linker"
  echo "== c3c: shared library (exports restricted to the header)"
  c3c "${c3flags[@]}" --linker=custom "$linker" dynamic-lib "${sources[@]}" -o libbleu_capi >"$work/c3-shared.log" 2>&1 \
    || { cat "$work/c3-shared.log"; exit 1; }
  # Exported functions in the dynamic symbol table, by name (defined text symbols only).
  nm -D --defined-only libbleu_capi.so | awk '$2 == "T" || $2 == "W" {print $3}' | sort -u > "$work/symbols.txt"
  sort -u "$work/exports.txt" > "$work/expected.txt"
  if ! diff -u "$work/expected.txt" "$work/symbols.txt"; then
    echo "error: libbleu_capi.so exports symbols other than the header's functions" >&2
    exit 1
  fi
  echo "exported symbols ($(wc -l < "$work/symbols.txt")): $(tr '\n' ' ' < "$work/symbols.txt")"
else
  echo "note: $(uname -s): symbol restriction is implemented for Linux ELF only; the shared library exports all of C3's symbols"
  c3c "${c3flags[@]}" dynamic-lib "${sources[@]}" -o libbleu_capi >"$work/c3-shared.log" 2>&1 \
    || { cat "$work/c3-shared.log"; exit 1; }
fi

if [ "$check" = 0 ]; then
  mkdir -p "$out"
  cp libbleu_capi.so libbleu_capi.a "$out/"
  cp "$work/exports.txt" "$out/exports.txt"
  echo "built: $out/libbleu_capi.so $out/libbleu_capi.a"
  echo "headers: $repo/include/bleu/ (abi $(grep -o 'BLEU_ABI_VERSION [0-9]*' "$repo/include/bleu/core.h" | cut -d' ' -f2))"
else
  echo "headers are up to date"
fi
