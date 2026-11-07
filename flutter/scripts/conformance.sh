#!/usr/bin/env bash
# Validates what the Dart layer produced (flutter test wrote build/conformance) against ../protocol/schema. Node ≥ 20.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/build/conformance"
[ -n "$(ls -A "$dir" 2>/dev/null)" ] || { echo "no payloads in $dir: run flutter test first" >&2; exit 1; }
fail=0
for f in "$dir"/*.json; do
  base="$(basename "$f" .json)"
  spec="${base%%--*}"
  schema="${spec%%#*}"
  def=""
  [[ "$spec" == *"#"* ]] && def="${spec#*#}"
  if node "$here/../protocol/validate.mjs" "$schema" "$f" $def; then echo "ok   $base"; else echo "FAIL $base"; fail=1; fi
done
exit $fail
