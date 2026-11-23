#!/usr/bin/env bash
# Copies the iOS SDK's sources into the plugin (ios/vendor/): under CocoaPods the pod `scruter_flutter` compiles them
# itself and depends on no pod of the CocoaPods trunk, which turns read-only on 2026-12-02 (docs/MOBILE.md §3
# "Distribution"). Run it before `dart pub publish` and before any build of the example through CocoaPods; `--check`
# fails when ios/vendor differs from ../ios/Sources. Swift Package Manager does not read ios/vendor (Package.swift).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
from="$here/../ios/Sources"
to="$here/ios/vendor"
if [[ "${1:-}" == "--check" ]]; then
  diff -r "$from/ScruterAnalytics" "$to/ScruterAnalytics" && diff -r "$from/ScruterCrash" "$to/ScruterCrash"
  exit
fi
rm -rf "$to"
mkdir -p "$to"
cp -R "$from/ScruterAnalytics" "$from/ScruterCrash" "$to/"
