# Scruter Analytics for Flutter

Privacy-first analytics for Flutter apps, hosted in France: screens, events, sessions, retention, sources, crashes and
Screen analysis — **without the IDFA or the GAID, without an App Tracking Transparency prompt, without a consent
banner**.

- The SDK draws a **random identifier each day** and forgets it at midnight (the app's time zone). The phone keeps only
  the day the app was installed, shared by everyone who installed it that day.
- Never read: IDFA, GAID or any device identifier, the GPS position, contacts, photos, the text people type. Never stored
  by Scruter: the IP address (country and city are derived from it, then it is dropped).
- A user's screen is **never** captured. Screen images come only from your team's phones.

It is the Flutter half of [scruter-mobile](https://github.com/scruter-analytics/scruter-mobile): the plugin embeds the
native SDKs (the iOS SDK's sources, compiled into the pod or taken from Swift Package Manager, and
`net.scruter:scruter-android`) for sessions, sending, native crashes, the install
referrer, openings and team phones. Flutter draws its own widgets, so everything about elements lives in Dart.

Requirements: Flutter 3.22+, iOS 15+, Android 7 (API 24)+. MIT licence.

## Install

```sh
flutter pub add scruter_flutter
```

Set the minimum platforms if your project is below them: `minSdk = 24` in `android/app/build.gradle`, and
`platform :ios, '15.0'` in `ios/Podfile`. The package needs no other native change.

## Start: three lines

Your "App identifier" is in Scruter › App settings › SDK (`ATMONA02`).

```dart
import 'package:scruter_flutter/scruter_flutter.dart';

Future<void> main() async {
  await Scruter.start(appId: 'ATMONA02');
  runApp(MaterialApp(
    navigatorObservers: [ScruterObserver()],
    home: const Home(),
  ));
}
```

`start` returns at once: disk and network work happens on the native SDK's own thread. Call it once; before it, every
call is a no-op. Run the app on a simulator or a phone: the installation check in Scruter turns green within seconds
(debug builds show there and are never counted).

Options: `debugKey:` (team phones, below), `debug: true` (console logs), `testBuild: true` (marks a build you hand to
testers, which the app's settings can exclude).

## Screens

The observer counts a screen when a route becomes the visible one, and again when the user comes back to it, like a page.

```dart
MaterialApp(navigatorObservers: [ScruterObserver()], …)      // Navigator 1 and 2
GoRouter(observers: [ScruterObserver()], routes: […])        // GoRouter
```

- The name is `RouteSettings.name`. With GoRouter, the route's `name`, else its path pattern (`/product/:id`), **never the
  parameters**. A custom `pageBuilder` must pass `name: state.name ?? state.path` to its `Page`.
- Named routes that carry values: the query and the fragment are dropped, and a path segment that is a number or a
  generated id becomes `:id` (`/product/42` → `/product/:id`). `ScruterObserver(nameExtractor: (settings) => …)` names
  routes your way (null skips one).
- **Unnamed routes are not counted** (the debug log says so). A dialog or a sheet stays part of the screen under it unless
  it has a name (`routeSettings: RouteSettings(name: 'Confirmation')`).
- One observer per navigator: a `ShellRoute` takes its own `observers: [ScruterObserver()]`.
- Screens that are not routes (tabs, a `PageView`, `StatefulShellRoute` branches once built) are named by you:

```dart
Scruter.screen('Cart');
```

Names: ≤ 120 characters. Screens listed in App settings › Exclusions are not sent (wildcards: `Debug*`).

## Events

```dart
Scruter.track('Add to cart');
Scruter.track('Add to cart', props: {'color': 'blue'});
Scruter.track('Order placed', revenue: 49.0, currency: 'EUR');
```

Names ≤ 120 characters; ≤ 30 properties (strings, numbers, booleans; keys ≤ 300, values ≤ 2 000 characters). Revenue
counts only with its ISO 4217 currency. **Never put personal data in names or properties** (an e-mail address, a name, an
order number): the server masks e-mail addresses and long numbers anyway.

## Taps, scroll, time per block, forms

Nothing to add. On the sessions of the Advanced analytics sample (every session on Growth and Custom, 10% on
Essential), the SDK counts, in aggregate: taps per element and their position inside it, dead taps (nothing happens within
a second), rage taps (three taps within a second at the same place), scroll depth on the main vertical `Scrollable`, time
per part of the screen, and form fields (focus, hesitation, changes, errors — never a value nor its length). Nothing is
recorded per person; there is no session recording. A pointer route that only watches sees the touches: your gestures are
never delayed or consumed, and no frame is added.

**Element identity.** An element is named by its explicit identifier, else by its widget type and position. Give the
elements that matter a stable name, in any of three ways:

```dart
ElevatedButton(key: const ValueKey('add_to_cart'), …)
Semantics(identifier: 'add_to_cart', child: …)
ScruterId('add_to_cart', child: ElevatedButton(…))
```

A stable identifier starts with a letter and holds only `A–Z a–z 0–9 _ . : -` (≤ 60 characters, no generated ids). The
items of a `ListView` or a `GridView` share their list's name and are told apart by their position; a key on an item
belongs to your data, so only `ScruterId` names one.

Only what means something gets a name: buttons, `InkWell`, `GestureDetector`, `ListTile`, text fields, choices, texts,
images, lists, `Scaffold`, `AppBar`, `Card`, dialogs, tab and navigation bars, and what you identify. Layout widgets and
Flutter's internals do not count as levels, so that a selector survives a new Flutter version.

**With `--obfuscate`**, Flutter's widgets keep their names; your own widgets' type names are gone (a list item then reads
`View[cell]`). Use `ScruterId` where it matters.

**Forms.** `TextField`, `TextFormField`, `CupertinoTextField` and choices (`Checkbox`, `Switch`, `Radio`, `Slider`,
dropdowns, segmented buttons, pickers) are fields. A screen's fields are one form named after the screen, or group them:

```dart
ScruterForm('Delivery', child: …)
Form(key: const ValueKey('delivery'), child: …)
```

A field's key is its identifier, else its first `autofillHints` (`postalCode`, `emailAddress`…), else `type:position`.
Passwords (`obscureText`), one-time codes and payment fields (`autofillHints`, names with card, cvc, iban, pin, otp,
token, secret) are ignored entirely. The errors your `InputDecoration` shows (`errorText`, a `TextFormField`'s validator)
are read by themselves: that one shows, never what it says. For the rest:

```dart
Scruter.fieldError('postalCode', ScruterFieldError.format);   // required, format, refused, invalid
Scruter.formSent('Delivery');                                 // else: leaving forward after a change, with no error
```

**Ignore** a part of the screen entirely (no tap, no field): `ScruterIgnore(child: …)`.

## Team phones and screen images

Screen analysis draws taps on an image of each screen. Those images come **only from your team's phones**:

- **Debug builds**: create a debug key in App settings › SDK and keep it out of release builds. It is used only with
  `kDebugMode`, and checked again by the native SDK: a release build that ships it by mistake never takes an image.

  ```dart
  await Scruter.start(appId: 'ATMONA02', debugKey: kDebugMode ? 'scr_dbg_…' : null);
  ```

- **Added by QR code** (App settings › Team phones), for a test build: declare the link once. The app asks the
  person holding the phone before it joins.

  iOS, in `ios/Runner/Info.plist` (nothing else: the plugin receives the URL):

  ```xml
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLSchemes</key>
    <array><string>scruter-atmona02</string></array>
  </dict></array>
  ```

  Android, in the `<application>` of `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <activity android:name="net.scruter.flutter.ScruterTeamLink"
      android:exported="true" android:noHistory="true" android:excludeFromRecents="true"
      android:theme="@android:style/Theme.Translucent.NoTitleBar">
    <intent-filter>
      <action android:name="android.intent.action.VIEW" />
      <category android:name="android.intent.category.DEFAULT" />
      <category android:name="android.intent.category.BROWSABLE" />
      <data android:scheme="scruter-atmona02" android:host="team" />
    </intent-filter>
  </activity>
  ```

  Scan the code with the phone's camera: your test build opens and the phone joins. The link never reaches your router.

On a team phone, the first time a screen opens in a new version (or when "Take the image again" asks), the SDK waits until
the screen is idle, paints the page from Flutter's own layers, scrolls its main list once to take the whole content (the
screen moves for a second, then returns), and uploads one JPEG with the element tree. **Every text field, every platform
view (the web views of `webview_flutter` and `flutter_inappwebview`, maps, video) and every `ScruterMask` is covered with an opaque rectangle on the phone, before the image is
encoded** (and again on the server):

```dart
ScruterMask(child: AddressCard(user))
```

The keyboard and system dialogs are never in the image. Platform views are not painted by Flutter's layers anyway. An
element floating over the list (a `FloatingActionButton`) shows on each scrolled strip. Use a test account on team phones;
their sessions are never counted. `Scruter.isTeamPhone`, `Scruter.leaveTeamMode()`.

## Crashes

- **Dart**: `FlutterError.onError` and `PlatformDispatcher.instance.onError`, chained with the handlers you or another
  reporter set, before or after `start`. Flutter's root isolate survives its errors, so they are reported as non-fatal
  errors; the same error is reported once a second at most (a widget failing in `build` fires at every frame), and
  `silent` errors are left alone. For what you catch yourself:

  ```dart
  Scruter.reportError(error, stack);               // fatal: true counts it as a crash of the session
  ```

- **Native**: the crashes and ANRs of the iOS and Android layers, by the native SDKs.

A report holds the stack, the error's type and the first line of its message (cut to 200 characters, masked by the
server), the screen and the last 10 screen and event names — never a property value, never a log line. Crashes never count
in your quota.

**Readable stacks: upload your symbols.** A release build with `--split-debug-info` or `--obfuscate` has no names in its
stacks.

```sh
flutter build ipa --split-debug-info=build/symbols
SCRUTER_UPLOAD_TOKEN=scr_up_… dart run scruter_flutter:upload_symbols build/symbols
```

On iOS this needs a Flutter version that writes Mach-O snapshots (checked on 3.47): the assembly snapshots of older versions
(checked on 3.22) leave symbols without a build id. With those, leave `--split-debug-info` out of iOS builds: their Dart
stacks then carry function names by themselves.

Create the token in App settings › SDK and keep it in your CI's secrets, **never in the project**. The tool reads the app id
in your `Scruter.start` (`--app ATMONA02` otherwise), the version in `pubspec.yaml`, skips what Scruter already has, and
never fails your build (`--strict` to change that). For native stacks, add the iOS build phase and the Gradle plugin as in
the [iOS](../ios/README.md#crashes) and [Android](../android/README.md#crashes) guides.

## Links and openings

The plugin forwards the links and quick actions that open your app: Scruter counts how the session started (icon,
notification, link, widget, shortcut) and the `utm_*` campaign of a link. Only the link's host, path and `utm_*` values
leave the phone. On iOS, an app that handles links in a `UISceneDelegate` passes them on, since plugins do not see them:
`Scruter.handleLink(url)`. Notifications: Firebase Cloud Messaging intents and `UNUserNotificationCenter` delegates are
detected; otherwise call `Scruter.openedFromNotification()`.

On iOS, declare the SKAdNetwork and AdAttributionKit copies in `Info.plist` as in the
[iOS guide](../ios/README.md#installs-from-campaigns-skadnetwork-and-adattributionkit).

## Opt-out

The audience-measurement exemption needs no consent, but users may object. Wire your app's "Audience measurement" setting to:

```dart
Scruter.optOut();              // nothing more is sent; the queue, the daily identifier and the install day are deleted
Scruter.optIn();               // measured again, as a new install without an install day
await Scruter.isOptedOut;
```

For your own test phones ("Test devices"): `Scruter.ignoreThisDevice()`, `Scruter.ignoreThisDevice(false)`.

## Debug logging

`Scruter.start(appId: 'ATMONA02', debug: true)` logs screens, taps and limits to the console with `debugPrint`, and the
native SDK logs events and batches (Logcat tag `Scruter`, os_log category `Scruter`). Leave it off in release builds.

## Budget on the phone

Measured by the CI: `scripts/budget.sh` (one app built with and without the SDK, arm64, release), and the self-check in a
release build on emulators without a GPU, API 34 and 24 (no physical phone yet). The ranges are over several CI runs.

| | Budget | Measured |
|---|---|---|
| Dart AOT | ≤ 150 KB, plus the native SDKs | 64 KB |
| `Scruter.start` | ≤ 5 ms | the `await`, first initialisation of Flutter's binding included: 2.7–5.6 ms on API 34, 59–65 ms on API 24 |
| A tap on a screen of 2 000 elements, identity | ≤ 0.5 ms | **over budget**: 0.74–1.26 ms on API 34, 0.89–1.12 ms on API 24; 1.4 ms with the hit test |
| A tap on an ordinary screen, hit test included | ≤ 1 ms | 0.3 ms |
| Frames | none added | a widget test: a screen, a tap, a scroll schedule no frame |

The tap's cost applies only to sessions in the Advanced analytics sample, on a tap, never while scrolling.

Team phones only: a bitmap of ≤ 40 MB plus one strip twice, ≤ 60 MB by construction (not measured on a phone), freed at once. No
timer in the background: the SDK's timers run around an event of the foreground. Network and battery are the native SDKs'.

## Example app and tests

`example/` is a small shop with GoRouter: a list, a long product screen, a form with a password and validators, a masked
widget, the opt-out. Its `lib/self_check.dart` drives the app with real pointer events.

```sh
flutter test                                # widget tests of every behaviour
scripts/conformance.sh                      # what they recorded, against ../protocol/schema (Node ≥ 20)
scripts/budget.sh                           # the size of the Dart layer
node scripts/device-check.mjs android debug app-debug.apk       # on a running emulator, the self-check's payloads
```

`.github/workflows/flutter.yml` runs them on Flutter 3.22 and the latest stable, builds Android and iOS, and runs the
self-check on Android emulators (API 24 and 34, debug and release) and an iOS simulator.

The example depends on the native SDKs of this repository: `android/build/staging` (`./gradlew
:scruter-android:publishReleasePublicationToStagingRepository` in `../android`) and `ios/vendor`, the iOS SDK's sources
that `scripts/sync-ios-sources.sh` copies into the plugin. Run it before building for iOS through CocoaPods, and before
`dart pub publish`: the CocoaPods trunk is read-only from December 2, 2026, so the pod depends on no trunk pod (Swift
Package Manager reads `ios/scruter_flutter/Package.swift`, unchanged).
