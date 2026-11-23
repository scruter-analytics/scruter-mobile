#!/usr/bin/env bash
# Copies the iOS SDK's sources into the plugin (ios/vendor/): under CocoaPods the pod `scruter_flutter` compiles them
# itself and depends on no pod of the CocoaPods trunk, which turns read-only on 2026-12-02 (docs/MOBILE.md §3
# "Distribution"). Scruter CMP's sources travel too; the podspec compiles each module only for an app that takes it.
# Run it before `dart pub publish` and before any build of the example through CocoaPods; `--check` fails when
# ios/vendor differs from ../ios/Sources. Swift Package Manager does not read ios/vendor (Package.swift).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
from="$here/../ios/Sources"
to="$here/ios/vendor"
if [[ "${1:-}" == "--check" ]]; then
  diff -r "$from/ScruterAnalytics" "$to/ScruterAnalytics" && diff -r "$from/ScruterCrash" "$to/ScruterCrash" &&
    diff -r "$from/ScruterCMP" "$to/ScruterCMP"
  exit
fi
rm -rf "$to"
mkdir -p "$to"
cp -R "$from/ScruterAnalytics" "$from/ScruterCrash" "$from/ScruterCMP" "$to/"
# With both modules, the pod compiles them and the plugin's Swift into one module, where a file name may appear once
# (docs/CMP-MOBILE.md §3.16).
twice=$(find "$to/ScruterAnalytics" "$to/ScruterCMP" "$here/ios/scruter_flutter/Sources" -name '*.swift' -exec basename {} \; | sort | uniq -d)
if [[ -n "$twice" ]]; then
  echo "Swift file names used twice in one module: $twice" >&2
  exit 1
fi
