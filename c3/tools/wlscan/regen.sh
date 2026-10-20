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
