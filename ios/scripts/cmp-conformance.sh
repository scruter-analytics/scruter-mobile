#!/bin/sh
# Checks every body the CMP tests sent (exported to $SCRUTER_CMP_BODIES, default .build/cmp-bodies, as
# `<schema>--<name>.json`) against the protocol's JSON Schemas with protocol/validate.mjs (Node ≥ 20).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
dir=${SCRUTER_CMP_BODIES:-$root/.build/cmp-bodies}
count=0
for f in "$dir"/*.json; do
  [ -e "$f" ] || { echo "nothing in $dir: run the CMP tests first" >&2; exit 1; }
  schema=$(basename "$f" | sed 's/--.*//')
  printf '%s: ' "$(basename "$f")"
  node "$root/protocol/validate.mjs" "$schema" "$f"
  count=$((count + 1))
done
for s in cmp-hit cmp-consent cmp-sdks; do
  ls "$dir/$s--"*.json > /dev/null 2>&1 || { echo "no $s body recorded" >&2; exit 1; }
done
echo "$count CMP bodies conform to protocol/schema"
