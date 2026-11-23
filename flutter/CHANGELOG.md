## 1.3.0

Scruter CMP leaves this package for its own, `scruter_cmp_flutter`
([scruter-cmp-mobile](https://github.com/scruter-analytics/scruter-cmp-mobile)), version 1.0.0: `scruter_flutter` is
Scruter Analytics alone again and ignores the `scruter:` block of the app's `pubspec.yaml`. An app that takes both adds
both packages. Scruter Analytics does not change.

## 1.2.0

Scruter CMP: `ScruterCMP`, the native consent sheet of Scruter CMP over the iOS and Android modules, for an app that
takes it (`scruter: { cmp: true }` in its `pubspec.yaml`; `analytics: false` leaves Scruter Analytics out). Guide:
`CMP.md`. Without that key, nothing changes.

## 1.1.0

An iPhone or iPad app running on a Mac (« Designed for iPad » on Apple silicon) sends the platform `macos`, the form
`desktop` and the Mac's model, through the iOS SDK the plugin carries. Nothing else changes in the plugin.

## 1.0.2

No change to the plugin: every Scruter SDK shares one version.

## 1.0.1

No change to the plugin: every Scruter SDK shares one version.

## 1.0.0

First release: screens through `ScruterObserver` (Navigator and GoRouter), events, sessions, retention, sources,
opt-out; taps, dead and rage taps, scroll depth, time per block and forms; Dart and native crashes with
`dart run scruter_flutter:upload_symbols`; team phones' screen images with masks drawn on the phone.
