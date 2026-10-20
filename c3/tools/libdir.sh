#!/usr/bin/env bash
# Print a library directory containing only the libraries that currently have
# a manifest.json. c3c refuses a --libdir holding ANY half-created library, so
# while several engineers work in parallel use:
#   c3c --libdir "$(tools/libdir.sh)" --lib bleu_core ... compile-test ...
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="${TMPDIR:-/tmp}/bleu-libdir-$$"
rm -rf "$tmp"; mkdir -p "$tmp"
for d in "$here"/libs/*.c3l; do [ -f "$d/manifest.json" ] && ln -s "$d" "$tmp/$(basename "$d")"; done
echo "$tmp"
