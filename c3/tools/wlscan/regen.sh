#!/usr/bin/env bash
# Fetch the Wayland protocol XML files listed in protocols.tsv and regenerate the
# committed C3 bindings in libs/bleu_wl.c3l/src/proto/.
#
#   tools/wlscan/regen.sh            fetch into a fresh temporary directory, then generate
#   WLSCAN_XML_DIR=dir regen.sh      use XML files already in dir (no network)
#
# Building the library never runs this: the generated files are committed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/libs/bleu_wl.c3l/src/proto"
xml_dir="${WLSCAN_XML_DIR:-}"
if [ -z "$xml_dir" ]; then
  xml_dir="$(mktemp -d)"
  trap 'rm -rf "$xml_dir"' EXIT
  while IFS=$'\t' read -r module url; do
    case "$module" in ''|\#*) continue ;; esac
    curl -fsSL -o "$xml_dir/$module.xml" "$url"
  done < "$here/protocols.tsv"
fi
python3 -I "$here/wlscan.py" --manifest "$here/protocols.tsv" --xml-dir "$xml_dir" --out "$out"
# The committed files are c3fmt output, so regeneration must end with the same formatter.
# c3fmt is not idempotent on this code: one pass aligns some declarations that the next pass
# un-aligns (`uint id_id = ...` above a multi-line declaration). Format until a pass changes nothing,
# then check, so the output is exactly what `c3fmt --check` accepts.
for _ in 1 2 3 4; do
  before="$(cat "$out"/*.c3 | md5sum)"
  c3fmt -i "$out"/*.c3
  [ "$(cat "$out"/*.c3 | md5sum)" = "$before" ] && break
done
c3fmt --check "$out"/*.c3
