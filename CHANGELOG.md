# Changelog

One version for the four SDKs. The GitHub release of a version carries its section below.

## 1.1.0

iOS: macOS support. The same package measures a native Mac app (AppKit or SwiftUI, macOS 12+): sessions follow the app
becoming active, resigning and quitting (what waits is sent before it quits); screens are the key window's content view
controller, `.scruterScreen` and `Scruter.screen`; events, properties, opt-out and crashes (handlers and MetricKit) work
as on iOS. A Mac sends the platform `macos`, the form `desktop`, its model (`Mac15,7`) and the macOS version, and its
install source (`mac_app_store`, `testflight`, `other`). An iPhone or iPad app running on a Mac (Mac Catalyst, or
« Designed for iPad » on Apple silicon) keeps its iOS layer and now sends `macos`, `desktop` and the Mac's model too. No
taps, scroll, forms or screen images on a Mac. The CocoaPods pod declares macOS 12.

React Native and Flutter carry the iOS SDK's sources: their iOS apps running on a Mac send `macos`, `desktop` and the
Mac's model too. Android changes only its version.

## 1.0.2

React Native: `screenName` also receives the whole route (`(tabs)/index`, `admin/job/[id]`), which tells apart two screens
called `index` and covers every route of a section. The other SDKs change only their version.

## 1.0.1

React Native: the package's entry is compiled JavaScript for every tool. An app's Jest tests no longer fail with
`Unexpected token 'export'` when they import the package, and need no `moduleNameMapper`. The other SDKs change only their
version.

React Native: `Scruter.trackNavigation(ref, { screenName })` gives routes clear names or leaves them uncounted, and Expo
Router's root is no longer counted as a screen called `__root`.

## 1.0.0

First release of Scruter Analytics for iOS, Android, React Native and Flutter: screens, events, sessions, retention,
sources and opt-out; taps, dead and rage taps, scroll depth, time per block and form fields, aggregated for everyone;
crashes and ANRs with symbol uploads; screen images from the team's phones, with masks drawn on the phone. No IDFA, no
advertising id, no device identifier, no ATT prompt, no banner: a random identifier each day, forgotten at midnight.
