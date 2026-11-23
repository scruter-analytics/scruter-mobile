# Changelog

One version for the four SDKs. The GitHub release of a version carries its section below.

## 1.3.0

Scruter CMP for apps moves to SDKs of its own, in their own repository
([scruter-analytics/scruter-cmp-mobile](https://github.com/scruter-analytics/scruter-cmp-mobile)) and with their own
versions, from 1.0.0: the Swift package `scruter-cmp-mobile` (product `ScruterCMP`) and the pod `ScruterCMP` from that
repository, `net.scruter.cmp:scruter-cmp` and `net.scruter.cmp:scruter-cmp-compose` on Maven Central,
`@scruter/react-native-cmp` on npm and `scruter_cmp_flutter` on pub.dev. This repository is Scruter Analytics alone
again: no `ScruterCMP` product or pod, no `net.scruter:scruter-cmp` artifacts (Maven Central keeps their 1.2.0), and
`@scruter/react-native` and `scruter_flutter` carry no CMP; they ignore the `scruter` key of the app's `package.json` or
`pubspec.yaml` (an app that took the CMP alone with `analytics: false` replaces them with the CMP's packages). An app
that takes both installs both, Scruter Analytics 1.3.0 or later beside the CMP's packages. Scruter Analytics itself
does not change.

## 1.2.0

iOS: Scruter CMP for apps, the module `ScruterCMP` (Swift Package Manager product `ScruterCMP`, CocoaPods pod
`ScruterCMP`; independent of Scruter Analytics). The banner published in Scruter CMP as a native SwiftUI sheet (a bottom
sheet on iPhone, a centred card on iPad; image or video header, the app's icon, « Certifié par Scruter », the
Personnaliser steps, light and dark, Dynamic Type, VoiceOver, right to left), presented by itself once the app's first
frame is drawn or where the app asks; the choice kept in the app's storage in the web's format, a proof of every decision
(pending until acknowledged, sent again at the next launches), one hit per opening, the web's re-ask rules, the
preferences for the app's settings entry (« Tout refuser » there withdraws), `isGranted`, `whenReady`, `onChange`, Google Consent Mode
signals, Apple's tracking prompt after an advertising consent, the detected third-party SDKs, debug builds kept out of
the registry. Guide: `ios/CMP.md`.

Android: Scruter CMP for apps, `net.scruter:scruter-cmp` (Android 7+, Views and Compose, no dependency): the consent
sheet drawn with the platform's views (bottom sheet on phones, centred card on tablets, the banner's media header, its
steps and preferences, TalkBack and font scale up to 200 %, right to left), the choice in the app's own storage with its
proofs and their queue, the re-ask rules, Google Consent Mode signals, the detected SDKs, debug builds' proofs. The
companion `net.scruter:scruter-cmp-compose` adds `ScruterConsentHost`, `rememberConsentChoice()` and `choices()` as a
`Flow`. Guide: `android/CMP.md`. The Analytics SDKs do not change.

iOS and Android: the IAB TCF v2.2 in the CMP modules (CMP ID 528), when the site's TCF settings are on: IAB's text on
the first layer, the IAB purposes in the Personnaliser steps, the partners and their declarations, the objections to
legitimate interest, the special features; the TC string and the `IABTCF_*` keys of IAB's in-app specification
(`UserDefaults.standard`, the default `SharedPreferences`) written before the sheet closes and kept in step, read by
Google Mobile Ads and the other TCF vendors; the re-ask when the TCF policy changes or the publisher adds a vendor; the
proof carries the TC string. Google's other ad tech providers (its Additional Consent list) the site selected: listed
after the TCF's partners with their consent switch and privacy policy, Google's Additional Consent string v2 in
`IABTCF_AddtlConsent` and in the proof. Encoded alike on the web and in apps (the kit's `protocol/cmp/tcf-vectors.json`). Android:
the confirmation's second line, as on iOS. iOS: no separate « Retirer mon accord » in the preferences: « Tout refuser »
there withdraws, as on Android and the web.

React Native and Flutter: Scruter CMP in `@scruter/react-native` and `scruter_flutter`, over the native modules (the
sheet stays native, presented over the app whatever its navigation; the choice, the proofs and the queue stay in the
native modules; the beacons name the wrapper in `cv`). `ScruterCMP.start`, `isGranted`, `whenReady` and `onChange`
with their removal, `state`, `choice`, `consentId`, `showPreferences()`, `showIfNeeded()`, `consentModeSignals()`,
`requestTrackingIfGranted()` (`unsupported` on Android), `setLanguage`, `debug`, `debugReset()`, `forceShow`; React's
`useConsentChoice()`, Dart's `ScruterCMP.choices` stream. A JavaScript reload or a hot restart starts nothing twice and
hears each change once. An app takes the modules it wants in its `package.json` or `pubspec.yaml`
(`"scruter": { "cmp": true, "analytics": false }`) and carries only their native code; without that key, an install is
unchanged. The Expo plugin takes `trackingDescription` for Apple's tracking prompt and no longer needs `appId` for an
app without Scruter Analytics. Guides: `react-native/CMP.md`, `flutter/CMP.md`. The native modules gained the wrappers'
bridge (iOS `@_spi(ScruterBridge)`, Android `net.scruter.cmp.bridge.ScruterCMPBridge`); the iOS Analytics module's
internal `JSON`, `Environment` and `Text` types are now `JSONValue`, `AnalyticsEnvironment` and `AnalyticsText`, and two of
its files are renamed, as both modules share one Swift module in the
wrappers' pods.

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
