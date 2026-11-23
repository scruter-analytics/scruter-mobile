#!/usr/bin/env bash
# Validates every payload the SDK's tests recorded (build/conformance/<schema>[#<def>]--<name>.json) against the
# protocol kit's JSON Schemas (../protocol, docs/API.md §5.3), with the kit's own dependency-free validator (Node ≥ 20).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
validator="$here/../protocol/validate.mjs"
shopt -s nullglob
files=("$here"/scruter-android/build/conformance/*.json "$here"/sample/build/conformance/*.json)
if (( ${#files[@]} == 0 )); then
  echo "no recorded payload: run the unit tests first" >&2
  exit 1
fi
failed=0
for f in "${files[@]}"; do
  base="$(basename "$f" .json)"
  spec="${base%%--*}"
  schema="${spec%%#*}"
  def=""
  [[ "$spec" == *"#"* ]] && def="${spec#*#}"
  if out="$(node "$validator" "$schema" "$f" $def 2>&1)"; then
    echo "ok    $schema${def:+ ($def)}  ${base#*--}"
  else
    echo "FAIL  $schema${def:+ ($def)}  ${base#*--}"
    echo "$out" | sed 's/^/      /'
    failed=1
  fi
done
exit $failed
