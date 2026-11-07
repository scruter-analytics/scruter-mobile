#!/bin/sh
# Checks the batches the test suite built (exported to $SCRUTER_BATCH_OUT, default .build/batches) against the
# protocol's JSON Schema with sdk/protocol/validate.mjs (Node ≥ 20). Run after the tests (linux-test.sh or swift test).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
dir=${SCRUTER_BATCH_OUT:-$root/.build/batches}
count=0
check() { # schema file [$defs name]
  printf '%s: ' "$(basename "$2")"
  node "$root/protocol/validate.mjs" "$@"
  count=$((count + 1))
}
for f in "$dir"/*.json; do
  [ -e "$f" ] || { echo "nothing in $dir: run the tests first" >&2; exit 1; }
  case "$(basename "$f")" in
    team-register*) check team-register "$f" ;;
    team-meta*) check team-screen "$f" meta ;;
    team-tree*) check team-screen "$f" tree ;;
    *) check batch "$f" ;;
  esac
done
echo "$count bodies conform to sdk/protocol/schema"
