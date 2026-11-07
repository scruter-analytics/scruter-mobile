#!/bin/sh
# Builds and tests the Foundation-only core of the iOS SDK on Linux, in the official Swift image pinned by digest
# (the UIKit, SwiftUI and MetricKit parts compile only on Apple platforms: macOS CI, .github/workflows/ios.yml).
# Usage: sdk/ios/scripts/linux-test.sh [extra `swift test` arguments]
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
image="swift@sha256:92cafdba8c519c32b83d5aa50539fb3d5a534bc87c3d9437bf6e8984aa1be4f3" # swift:6.1-noble
exec docker run --rm --memory=6g --memory-swap=6g --cpus=2 --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$here:/sdk" -w /sdk \
  -e SCRUTER_BATCH_OUT=/sdk/.build/batches \
  "$image" sh -c "swift build --build-tests -j 2 --scratch-path /sdk/.build/linux && swift test --skip-build -j 2 --scratch-path /sdk/.build/linux $*"
