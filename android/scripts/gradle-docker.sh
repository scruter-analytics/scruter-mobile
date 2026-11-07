#!/usr/bin/env bash
# Runs Gradle for the Android SDK inside a pinned Docker image that holds the Android SDK (platform 35, build-tools
# 35.0.0) and a JDK 21, for machines without an Android toolchain. Usage, from anywhere:
#
#   sdk/android/scripts/gradle-docker.sh :scruter-android:testDebugUnitTest
#   sdk/android/scripts/gradle-docker.sh -p scruter-symbols-gradle-plugin check
#
# Environment: SCRUTER_GRADLE_HOME (Gradle and Maven caches, default ~/.cache/scruter-android-gradle); SIGNING_KEY and
# SIGNING_PASSWORD reach Gradle when set. On a shared machine, run this script through the machine's own lock. Memory
# is capped at 6 GB, swap included.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"   # sdk/android
sdk="$(cd "$here/.." && pwd)"               # sdk/ (the protocol kit is ../protocol from android/)
image="ghcr.io/cirruslabs/android-sdk@sha256:c724009e305b4607157287624033ab97f319af44c244bfc9f73b6293f3bb01b9"
cache="${SCRUTER_GRADLE_HOME:-$HOME/.cache/scruter-android-gradle}"
mkdir -p "$cache/home"
exec docker run --rm --memory=6g --memory-swap=6g --user "$(id -u):$(id -g)" \
  -e HOME=/gradle/home -e GRADLE_USER_HOME=/gradle -e ANDROID_USER_HOME=/gradle/home/.android \
  -e SIGNING_KEY -e SIGNING_PASSWORD \
  -v "$cache:/gradle" -v "$sdk:/sdk" -w /sdk/android "$image" \
  ./gradlew --no-daemon --max-workers=2 "-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8" "$@"
