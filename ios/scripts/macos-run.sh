#!/bin/sh
# A real native macOS run of the SDK: builds the example Mac app (ScruterExampleMac, Debug, signed to run locally),
# starts a local fake collection host, launches the app (it comes to the front for ≈ 5 s, opens an AppKit window, sends
# an event and quits), then checks what it sent (ios/scripts/macos_run_check.py) and validates the batches against
# sdk/protocol's batch schema, as they are and with `p`/`f` set to iOS values (to tell a new platform value from a
# shape error).
#
# Needs Xcode, XcodeGen (`XCODEGEN=/path/to/xcodegen`, else `xcodegen` on PATH), Python 3 and Node ≥ 20.
# Usage: ios/scripts/macos-run.sh   (from sdk/ or anywhere)
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
example="$root/ios/Example"
work="${SCRUTER_MACOS_RUN_DIR:-$root/.build/macos-run}"
gen="${XCODEGEN:-xcodegen}"
data="$HOME/Library/Application Support/net.scruter.example.mac"
sdk="ios/$(cat "$root/VERSION")"

rm -rf "$work"
mkdir -p "$work/batches"
echo "== build ScruterExampleMac (Debug)"
(cd "$example" && "$gen" generate --quiet)
if ! xcodebuild -project "$example/ScruterExample.xcodeproj" -scheme ScruterExampleMac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$work/dd" build > "$work/build.log" 2>&1; then
    grep -E 'error:' "$work/build.log" | head -20 || tail -30 "$work/build.log"
    exit 1
fi
app="$work/dd/Build/Products/Debug/ScruterExampleMac.app"

# A fresh install each time: the SDK's files of an earlier run go first.
rm -rf "$data"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$root/ios/scripts/fake_batch_server.py" "$port" "$work/batches" &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true; rm -rf "$data"' EXIT
sleep 0.5

echo "== run (the app comes to the front for ≈ 5 s, then quits)"
SCRUTER_EXAMPLE_ENDPOINT="http://127.0.0.1:$port" SCRUTER_EXAMPLE_AUTORUN=1 \
    "$app/Contents/MacOS/ScruterExampleMac" > "$work/app.log" 2>&1 &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -gt 150 ]; then
        kill "$pid"
        echo "the app did not quit within 30 s"
        exit 1
    fi
done
exit_time=$(python3 -c 'import time; print("%.3f" % time.time())')
sleep 0.5

echo "== batches"
status=0
python3 "$root/ios/scripts/macos_run_check.py" "$work/batches" "$exit_time" "$sdk" || status=1

echo "== protocol (sdk/protocol/schema/batch.schema.json)"
for f in "$work"/batches/batch-*.json; do
    name=$(basename "$f")
    if node "$root/protocol/validate.mjs" batch "$f" > "$work/$name.validate" 2>&1; then
        echo "  $name: valid as sent"
    else
        echo "  $name: as sent: $(head -3 "$work/$name.validate" | tr '\n' ' ')"
        python3 -c 'import json, sys
b = json.load(open(sys.argv[1]))
for s in b.get("s", []):
    s["p"], s["f"] = "ios", "phone"
json.dump(b, open(sys.argv[2], "w"))' "$f" "$work/$name.ios"
        if node "$root/protocol/validate.mjs" batch "$work/$name.ios" > /dev/null 2>&1; then
            echo "  $name: valid once p/f carry iOS values: only the new macOS values differ"
        else
            echo "  $name: still invalid with iOS values: $(node "$root/protocol/validate.mjs" batch "$work/$name.ios" 2>&1 | head -3 | tr '\n' ' ')"
            status=1
        fi
    fi
done
exit $status
