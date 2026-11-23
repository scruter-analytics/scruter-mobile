#!/usr/bin/env bash
# The size budget of docs/MOBILE.md §3.18: what the SDK's Dart layer adds to an app's AOT snapshot (arm64, release): the
# same small app built with and without it, the difference of libapp.so. Gate: 150 KB.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
budget_kb=150
cd "$here/example"
size_of() {
  flutter build apk --release --target-platform android-arm64 --split-per-abi -t "$1" >/dev/null
  unzip -q -o build/app/outputs/flutter-apk/app-arm64-v8a-release.apk 'lib/arm64-v8a/libapp.so' -d build/budget
  stat -c %s build/budget/lib/arm64-v8a/libapp.so
}
without=$(size_of lib/budget_without.dart)
with=$(size_of lib/budget_with.dart)
added=$(( (with - without) / 1024 ))
mkdir -p "$here/build"
echo "Dart AOT: ${without} bytes without the SDK, ${with} bytes with it: ${added} KB added (budget ${budget_kb} KB)" | tee "$here/build/budget.txt"
[ "$added" -le "$budget_kb" ]
