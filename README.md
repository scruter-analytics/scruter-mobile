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

The four SDKs share one version (`VERSION`), one wire protocol (`protocol/`, with its conformance kit) and one
[changelog](CHANGELOG.md). A tag `v<version>` publishes them (`.github/workflows/publish.yml`).
