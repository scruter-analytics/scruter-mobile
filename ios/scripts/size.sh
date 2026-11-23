#!/bin/bash
# What the SDK adds to an app (docs/MOBILE.md §3.18, §10): a small arm64 iOS app is linked statically, as
# Swift Package Manager does, with and without the SDK, release (-O, whole module), dead-stripped and stripped; the
# measure is the difference. macOS + Xcode. SCRUTER_SIZE_DETAIL=<dir> writes the symbol sizes there.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
budget=${SCRUTER_SIZE_BUDGET:-573440} # 560 KB
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios15.0
swiftc() { xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" "$@"; }
mkdir -p "$out/modules"
cat > "$out/modules/module.modulemap" <<MAP
module ScruterCrash {
  header "$root/ios/Sources/ScruterCrash/include/ScruterCrash.h"
  export *
}
MAP
xcrun --sdk iphoneos clang -c -Os -target "$target" -isysroot "$sdk" \
  -I "$root/ios/Sources/ScruterCrash/include" "$root/ios/Sources/ScruterCrash/crash.c" -o "$out/crash.o"
sources=$(find "$root/ios/Sources/ScruterAnalytics" -name '*.swift' | sort)

measure() { # optimisation flag -> size of the app with the SDK minus the app without it
  local opt=$1
  local dir="$out/build$opt"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  swiftc "$opt" -whole-module-optimization -parse-as-library -module-name ScruterAnalytics -I "$out/modules" \
    -emit-module -emit-module-path "$dir/ScruterAnalytics.swiftmodule" -emit-object -o "$dir/sdk.o" $sources
  cat > "$dir/with.swift" <<'SWIFT'
import ScruterAnalytics
import SwiftUI

@main struct DemoApp: App {
    init() { Scruter.start(appId: "ATMONA02") }
    var body: some Scene { WindowGroup { Text("x").scruterScreen("Home").scruterId("x").scruterMask().scruterIgnore().scruterForm("f") } }
}
SWIFT
  cat > "$dir/without.swift" <<'SWIFT'
import SwiftUI

@main struct DemoApp: App {
    init() { print("ATMONA02") }
    var body: some Scene { WindowGroup { Text("x") } }
}
SWIFT
  swiftc "$opt" -parse-as-library -I "$dir" -I "$out/modules" -c "$dir/with.swift" -o "$dir/with.o"
  swiftc "$opt" -parse-as-library -c "$dir/without.swift" -o "$dir/without.o"
  swiftc "$dir/with.o" "$dir/sdk.o" "$out/crash.o" -Xlinker -dead_strip -o "$dir/with"
  swiftc "$dir/without.o" -Xlinker -dead_strip -o "$dir/without"
  if [ "$opt" = "-O" ] && [ -n "${SCRUTER_SIZE_DETAIL:-}" ]; then
    mkdir -p "$SCRUTER_SIZE_DETAIL"
    xcrun nm -n -U -m "$dir/with" > "$dir/nm.txt"
    python3 - "$dir/nm.txt" > "$SCRUTER_SIZE_DETAIL/size-symbols.txt" <<'PY'
import sys
rows = []
for line in open(sys.argv[1]):
    f = line.split()
    if "(__TEXT,__text)" in line:
        rows.append((int(f[0], 16), f[-1]))
sizes = [(b[0] - a[0], a[1]) for a, b in zip(rows, rows[1:])]
for n, sym in sorted(sizes, reverse=True):
    print(n, sym)
PY
    xcrun size -m "$dir/with" > "$SCRUTER_SIZE_DETAIL/size-sections.txt" || true
    xcrun size -m "$dir/sdk.o" >> "$SCRUTER_SIZE_DETAIL/size-sections.txt" || true
  fi
  xcrun strip -x "$dir/with" "$dir/without"
  echo $(($(stat -f%z "$dir/with") - $(stat -f%z "$dir/without")))
}

size=$(measure -O)
osize=$(measure -Osize)
echo "SDK in an app (arm64, static, dead-stripped, stripped): -O $size bytes ($((size / 1024)) KB), -Osize $osize bytes ($((osize / 1024)) KB), budget $((budget / 1024)) KB"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "SDK size in an app: **$((size / 1024)) KB** (-Osize $((osize / 1024)) KB) / $((budget / 1024)) KB" >> "$GITHUB_STEP_SUMMARY"
fi
# iOS 15 has no AdAttributionKit (iOS 17.4): a strong link would stop the app at launch.
if ! xcrun otool -l "$out/build-O/with" | grep -A2 LC_LOAD_WEAK_DYLIB | grep -q AdAttributionKit \
  && xcrun otool -L "$out/build-O/with" | grep -q AdAttributionKit; then
  echo "AdAttributionKit is not weakly linked" >&2
  exit 1
fi
[ "$size" -le "$budget" ] || { echo "over the budget" >&2; exit 1; }
