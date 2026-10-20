#!/usr/bin/env bash
# Each file in refusals/ must fail to compile, and its diagnostic must contain the
# text named by its `// EXPECT:` line. This is how the compile-time refusals of
# bleu::json are verified, since a refusal cannot run as a unit test.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work"
libdir="$("$repo/tools/libdir.sh")"; trap 'rm -rf "$work" "$libdir"' EXIT
status=0
for file in "$here"/refusals/*.c3; do
  expect="$(sed -n 's#^// EXPECT: ##p' "$file")"
  out="$(c3c --libdir "$libdir" --lib bleu_core --lib bleu_json compile-only "$file" 2>&1)"
  if [ $? -eq 0 ]; then echo "FAIL  $(basename "$file"): compiled, expected a refusal"; status=1; continue; fi
  if grep -qF "$expect" <<<"$out"; then echo "ok    $(basename "$file")"
  else echo "FAIL  $(basename "$file"): diagnostic lacks '$expect'"; echo "$out" | grep "error:" | head -3; status=1; fi
done
exit $status
