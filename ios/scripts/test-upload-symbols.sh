#!/bin/sh
# Tests ios/upload-symbols against a fake server (macOS: dsymutil, dwarfdump, ditto): a dSYM is built, its UUID asked
# for, created, uploaded byte for byte and completed; the request bodies conform to protocol/schema/symbols.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/out" "$work/build"
printf 'int scruter_answer(void) { return 42; }\nint main(void) { return scruter_answer(); }\n' > "$work/main.c"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -g -arch arm64 -isysroot "$sdk" -c "$work/main.c" -o "$work/main.o"
xcrun clang -arch arm64 -isysroot "$sdk" "$work/main.o" -o "$work/build/Demo"
xcrun dsymutil "$work/build/Demo" -o "$work/build/Demo.dSYM"
python3 "$root/ios/scripts/fake_symbols_server.py" 8765 "$work/out" &
server=$!
sleep 1
SCRUTER_UPLOAD_TOKEN="scr_up_$(printf 'a%.0s' $(seq 1 43))" MARKETING_VERSION=2.3.0 CURRENT_PROJECT_VERSION=230 \
  "$root/ios/upload-symbols" --app ATMONA02 --api http://127.0.0.1:8765 --force --strict "$work/build" </dev/null
node "$root/protocol/validate.mjs" symbols "$work/out/missing.json" missing
node "$root/protocol/validate.mjs" symbols "$work/out/upload-1.json" upload
grep -q ok "$work/out/complete-1"
grep -q '"app_version":"2.3.0"' "$work/out/upload-1.json"
# Without a token, the build goes on.
env -u SCRUTER_UPLOAD_TOKEN "$root/ios/upload-symbols" --app ATMONA02 --force "$work/build" 2>&1 | grep -q 'SCRUTER_UPLOAD_TOKEN is not set'
echo "upload-symbols: missing → create → PUT → complete, bodies conform"
