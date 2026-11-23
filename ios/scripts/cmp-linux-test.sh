#!/bin/sh
# Builds and tests the platform-free logic of the CMP module (ios/Sources/ScruterCMP/Core) on Linux, in the official Swift
# image pinned by digest (the SwiftUI sheet builds on Apple platforms only: .github/workflows/ios-cmp.yml), then checks
# the bodies the tests sent against the protocol's JSON Schemas (ios/scripts/cmp-conformance.sh, Node ≥ 20).
# Usage: sdk/ios/scripts/cmp-linux-test.sh [extra `swift test` arguments]
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
image="swift@sha256:92cafdba8c519c32b83d5aa50539fb3d5a534bc87c3d9437bf6e8984aa1be4f3" # swift:6.1-noble
rm -rf "$here/.build/cmp-bodies"
docker run --rm --memory=6g --memory-swap=6g --cpus=2 --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$here:/sdk" -w /sdk \
  -e SCRUTER_CMP_BODIES=/sdk/.build/cmp-bodies \
  "$image" sh -c "swift build --build-tests -j 2 --scratch-path /sdk/.build/linux && swift test --skip-build -j 2 --scratch-path /sdk/.build/linux --filter ScruterCMPTests $*"
"$here/ios/scripts/cmp-conformance.sh"
