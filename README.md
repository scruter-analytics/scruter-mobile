# Scruter Analytics for mobile apps

The SDKs of [Scruter Analytics](https://scruter.net), privacy-first analytics hosted in France: screens, events, sessions,
retention, sources, crashes and screen analysis, without an advertising id, a device identifier, an ATT prompt or a
consent banner. A random identifier each day, forgotten at midnight. MIT licence.

| Platform | Guide | Install |
|---|---|---|
| iOS 15+ | [ios/README.md](ios/README.md) | Swift Package Manager: `https://github.com/scruter-analytics/scruter-mobile`, or CocoaPods from this repository |
| Android 7+ (API 24) | [android/README.md](android/README.md) | Maven Central: `net.scruter:scruter-android`; Gradle plugin `net.scruter.symbols` |
| React Native 0.73+ | [react-native/README.md](react-native/README.md) | npm: `@scruter/react-native` |
| Flutter 3.22+ | [flutter/README.md](flutter/README.md) | pub.dev: `scruter_flutter` |

**Scruter CMP for apps**, the consent sheet of [Scruter CMP](https://scruter.net/cmp) with the proof of every choice
and Google Consent Mode, is a separate module of the same SDKs: an app takes Analytics, the CMP or both.

| Platform | Guide | Install |
|---|---|---|
| iOS 15+ | [ios/CMP.md](ios/CMP.md) | Swift Package Manager: product `ScruterCMP` of this package, or CocoaPods: `ScruterCMP` from this repository |
| Android 7+ (API 24) | [android/CMP.md](android/CMP.md) | Maven Central: `net.scruter:scruter-cmp` (and `net.scruter:scruter-cmp-compose` for Compose) |
| React Native 0.73+ | [react-native/CMP.md](react-native/CMP.md) | npm: `@scruter/react-native`, with `"scruter": { "cmp": true }` in the app's `package.json` |
| Flutter 3.22+ | [flutter/CMP.md](flutter/CMP.md) | pub.dev: `scruter_flutter`, with `scruter: { cmp: true }` in the app's `pubspec.yaml` |

The four SDKs share one version (`VERSION`), one wire protocol (`protocol/`, with its conformance kit) and one
[changelog](CHANGELOG.md). A tag `v<version>` publishes them (`.github/workflows/publish.yml`).
