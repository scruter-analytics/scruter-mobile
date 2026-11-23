#!/bin/bash
# What the CMP module adds to an app (docs/CMP-MOBILE.md §3.11: ≤ 1 100 KB, arm64, release): a small SwiftUI app is linked
# statically, as Swift Package Manager does, with and without the module, release (-O, whole module), dead-stripped and
# stripped; the measure is the difference. macOS + Xcode. SCRUTER_SIZE_DETAIL=<dir> writes the symbol sizes there.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
budget=${SCRUTER_CMP_SIZE_BUDGET:-1126400} # 1 100 KB
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios15.0
swiftc() { xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" "$@"; }
sources=$(find "$root/ios/Sources/ScruterCMP" -name '*.swift' | sort)

measure() { # optimisation flag -> size of the app with the module minus the app without it
  local opt=$1
  local dir="$out/build$opt"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  swiftc "$opt" -whole-module-optimization -parse-as-library -module-name ScruterCMP \
    -emit-module -emit-module-path "$dir/ScruterCMP.swiftmodule" -emit-object -o "$dir/cmp.o" $sources
  cat > "$dir/with.swift" <<'SWIFT'
import ScruterCMP
import SwiftUI

@main struct DemoApp: App {
    init() {
        ScruterCMP.start(appId: "ATMONA02")
        ScruterCMP.whenReady { c in print(c.isGranted(.analytics), ScruterCMP.consentModeSignals()) }
        ScruterCMP.onChange { print($0.consentId) }
        ScruterCMP.requestTrackingIfGranted { print($0) }
    }
    var body: some Scene { WindowGroup { Button("x") { ScruterCMP.showPreferences() } } }
}
SWIFT
  cat > "$dir/without.swift" <<'SWIFT'
import SwiftUI

@main struct DemoApp: App {
    init() { print("ATMONA02") }
    var body: some Scene { WindowGroup { Button("x") { print("x") } } }
}
SWIFT
  swiftc "$opt" -parse-as-library -I "$dir" -c "$dir/with.swift" -o "$dir/with.o"
  swiftc "$opt" -parse-as-library -c "$dir/without.swift" -o "$dir/without.o"
  swiftc "$dir/with.o" "$dir/cmp.o" -Xlinker -dead_strip -o "$dir/with"
  swiftc "$dir/without.o" -Xlinker -dead_strip -o "$dir/without"
  if [ "$opt" = "-O" ] && [ -n "${SCRUTER_SIZE_DETAIL:-}" ]; then
    mkdir -p "$SCRUTER_SIZE_DETAIL"
    xcrun nm -n -U -m "$dir/with" > "$dir/nm.txt"
    python3 - "$dir/nm.txt" > "$SCRUTER_SIZE_DETAIL/cmp-size-symbols.txt" <<'PY'
import subprocess, sys
rows = []
for line in open(sys.argv[1]):
    f = line.split()
    if "(__TEXT,__text)" in line:
        rows.append((int(f[0], 16), f[-1]))
sizes = [(b[0] - a[0], a[1]) for a, b in zip(rows, rows[1:])]
names = [s for _, s in sizes]
demangled = subprocess.run(["xcrun", "swift-demangle", "--simplified"], input="\n".join(names), capture_output=True, text=True).stdout.split("\n")
for (n, _), d in sorted(zip(sizes, demangled), reverse=True):
    print(n, d[:240])
PY
    xcrun size -m "$dir/with" > "$SCRUTER_SIZE_DETAIL/cmp-size-sections.txt" || true
    xcrun size -m "$dir/cmp.o" >> "$SCRUTER_SIZE_DETAIL/cmp-size-sections.txt" || true
  fi
  xcrun strip -x "$dir/with" "$dir/without"
  echo $(($(stat -f%z "$dir/with") - $(stat -f%z "$dir/without")))
}

size=$(measure -O)
osize=$(measure -Osize)
echo "ScruterCMP in an app (arm64, static, dead-stripped, stripped): -O $size bytes ($((size / 1024)) KB), -Osize $osize bytes ($((osize / 1024)) KB), budget $((budget / 1024)) KB"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "ScruterCMP size in an app: **$((size / 1024)) KB** (-Osize $((osize / 1024)) KB) / $((budget / 1024)) KB" >> "$GITHUB_STEP_SUMMARY"
fi
# The module never links AppTrackingTransparency (it reaches ATT at run time, §3.9).
if xcrun otool -L "$out/build-O/with" | grep -q AppTrackingTransparency; then
  echo "AppTrackingTransparency is linked" >&2
  exit 1
fi
[ "$size" -le "$budget" ] || { echo "over the budget" >&2; exit 1; }
