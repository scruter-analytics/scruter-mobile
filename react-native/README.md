# Scruter Analytics for React Native

Privacy-first analytics for React Native apps, hosted in France: screens, events, sessions, retention, sources, crashes
and Screen analysis, **without an IDFA, a GAID, an App Tracking Transparency prompt or a consent banner**.

- The SDK draws a **random identifier each day** and forgets it at midnight (the app's time zone). The phone keeps only
  the day the app was installed, shared by everyone who installed it that day.
- Never read: IDFA, GAID, IDFV, Android ID or any device identifier, the GPS position, contacts, photos, the text people
  type. Never stored by Scruter: the IP address (country and city are derived from it, then it is dropped).
- A user's screen is **never** captured. Screen images come only from your team's phones.

This package carries the [iOS](../ios/README.md) SDK and depends on the [Android](../android/README.md) one, which do the work; its
JavaScript adds what they cannot see: your routes, your JavaScript errors and how they end.

React Native 0.73 and later, new and old architecture, Hermes and JavaScriptCore. iOS 15, Android 7 (API 24). MIT.

## Install

```sh
npm install @scruter/react-native
cd ios && pod install
```

The iOS SDK comes inside the npm package and is compiled by the package's own pod, so nothing is fetched from the CocoaPods
trunk, read-only from December 2, 2026: an `npm update` brings native fixes too. An app that also uses the iOS SDK from
its own Swift or Objective-C code calls it through the module `ScruterReactNative`, and does not add the pod `Scruter` or
the Swift package as well (the same symbols twice).

Your "App identifier" is in Scruter › App settings › SDK (`ATMONA02`).

**Android**: the SDK's manifest holds a link for team phones, whose scheme comes from your app id. In
`android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        manifestPlaceholders += [scruterAppId: "atmona02"]   // your app id, in lower case
    }
}
```

**iOS 15 and Android API 24 are the minimum.** React Native 0.73 starts lower: set `platform :ios, '15.0'` in the
`Podfile` and `minSdkVersion = 24` in `android/build.gradle`.

**iOS links**: for the QR code of team phones, add the URL scheme `scruter-atmona02` (Xcode › Info › URL Types). A link that
works as soon as your app has the methods of [React Native's Linking guide](https://reactnative.dev/docs/linking#enabling-deep-links)
(the `SceneDelegate` of recent templates has them; older `AppDelegate`s need them). The SDK follows `Linking` by itself.

### Expo

A config plugin does all of the above: no native edit. In `app.json`:

```json
{ "expo": { "plugins": [["@scruter/react-native", { "appId": "ATMONA02" }]] } }
```

It sets the URL scheme, the attribution keys of the Info.plist (`"attribution": false` to leave them out, when another
tool holds Apple's one copy address), the Gradle placeholder, the minimum platforms, and keeps the iOS source map.

It works with **development builds** and EAS Build (`npx expo prebuild`, `eas build`). **Expo Go cannot load it**: Expo
Go runs a fixed set of native modules, and this SDK is native. In Expo Go every call does nothing and `start` says so in
the console.

## Start and navigation: three lines

```tsx
import { Scruter } from '@scruter/react-native';

Scruter.start({ appId: 'ATMONA02' });            // once, before AppRegistry, outside any component

<NavigationContainer ref={Scruter.navigationRef}>
```

That is all for React Navigation: every route counts as a screen, under its `name`, never its `params`. Going back
counts again, like a page; coming back from the background does not.

If you already hold a ref, or use **Expo Router**:

```tsx
import { useNavigationContainerRef } from 'expo-router';

export default function RootLayout() {
  const ref = useNavigationContainerRef();
  useEffect(() => Scruter.trackNavigation(ref), [ref]);
  return <Stack />;
}
```

With Expo Router the name is the route's file pattern (`product/[id]`); a folder's `index` takes the folder's name
(`shop`).

To give your screens clear names, or to leave some uncounted, pass `screenName`. A string replaces the name, `null` leaves
the route uncounted, `undefined` keeps the automatic name:

```tsx
const names: Record<string, string> = { index: 'Home', 'product/[id]': 'Product' };

Scruter.trackNavigation(ref, {
  screenName: (route) => (route.startsWith('admin') ? null : names[route]),
});
```

Without navigation: `Scruter.screen('Cart')`. Names ≤ 120 characters. Screens listed in App settings › Exclusions are not
sent.

Options of `start`: `debugKey` (below), `debug: true` (logs, below), `testBuild: true` (a build for testers, when the
platform cannot tell), `endpoint` and `apiEndpoint` (tests).

`start` returns at once: disk and network work happens on the native SDKs' own threads. A second `start` is ignored.
Before it, every call does nothing.

## Events

```ts
Scruter.track('Add to cart');
Scruter.track('Add to cart', { props: { color: 'blue' } });
Scruter.track('Order placed', { revenue: 49.0, currency: 'EUR' });
```

Names ≤ 120 characters; ≤ 30 properties (strings, numbers, booleans; keys ≤ 300, values ≤ 2 000 characters). Revenue
counts only with its ISO 4217 currency. **Never put personal data in a name or a property**: the server masks e-mail
addresses and long numbers anyway.

## Taps, scroll, time per block, forms

Nothing to add: the native SDKs see your host views. On the sessions of the Advanced analytics sample, they count taps per
element, dead and rage taps, scroll depth, time per part of the screen and form fields. Always aggregated, never a value
or its length, never a recording.

**Element identity.** An element is named by its **`testID`**, else its **`nativeID`**, else its type and position. Give
the elements that matter a stable name (it starts with a letter, holds only `A–Z a–z 0–9 _ . : -`, ≤ 60 characters, no
generated ids):

```tsx
<Pressable testID="add_to_cart" onPress={add}>
```

`Pressable`, the `Touchable`s and `Switch` are interactive by themselves (on iOS, unless you set `accessible={false}`). A
plain `View` with responder handlers is seen as what it is, a view: give it `accessibilityRole="button"`.

**Lists.** The items of a `FlatList` or a `ScrollView` share their list's name, and their position tells them apart.
`FlatList` mounts a window of its items: the position comes from the mounted items and the height of what is above them,
which is exact with items of one height. For items of different heights, give the list its exact indexes:

```tsx
import { ScruterCell } from '@scruter/react-native';

<FlatList CellRendererComponent={ScruterCell} … />
```

**`ScruterView`** is a `View` that carries the marks `testID` cannot:

```tsx
import { ScruterView } from '@scruter/react-native';

<ScruterView scruterId="addToCart">…</ScruterView>      // a name, when testID is taken for something else
<ScruterView scruterForm="Delivery">…</ScruterView>     // these fields are one form
<ScruterView scruterIgnore>…</ScruterView>              // no tap, no field, nothing in screen images' tree
```

`ScruterView` uses `nativeID` for its marks, and stays a real view (`collapsable={false}`): it takes part in the layout.

**Forms.** `TextInput`s and `Switch`es are fields; a screen's fields are one form named after the screen. A field's key is
its `testID`, else its `textContentType` / `autoComplete` (`postalCode`, `emailAddress`…), else `type:position`. Passwords,
one-time codes and payment fields (`secureTextEntry`, those content types, ids with card, cvc, iban, pin, otp, token,
secret) are ignored entirely. Report the errors you show, and when a form is sent:

```ts
Scruter.fieldError('postal_code', 'format');   // 'required', 'format', 'refused', 'invalid'
Scruter.formSent('Delivery');
```

A form is also counted as sent when the user pushes a new screen after changing a field. React Native's errors are your
own text, so a field's error counts only through `fieldError`.

## Team phones and screen images

Screen analysis draws taps on an image of each screen. Those images come **only from your team's phones**:

- **By QR code** (App settings › Team phones): scan the code with the phone's camera: your test build opens and
  the phone joins, with your name.
- **Debug builds**: create a debug key in App settings › SDK:

  ```ts
  Scruter.start({ appId: 'ATMONA02', debugKey: __DEV__ ? 'scr_dbg_…' : undefined });
  ```

  The key is used only under `__DEV__` and by a debug build of the app: a release build that ships it by mistake never
  takes an image.

On a team phone, the first time a screen opens in a new version, the SDK waits until the screen is idle, scrolls through
its main list once (the screen moves for a second), and uploads one JPEG with the screen's element tree. Team phones'
sessions are never counted. `Scruter.isTeamPhone`, `Scruter.leaveTeamMode()`.

**Every text input and web view, and everything inside `<ScruterMask>`, is covered with an opaque rectangle on the phone,
before the image is encoded** (and again on the server):

```tsx
import { ScruterMask } from '@scruter/react-native';

<ScruterMask>
  <Text>{user.address}</Text>
</ScruterMask>
```

Use a test account on team phones.

## Crashes

Fatal JavaScript errors are reported through a chained `ErrorUtils.setGlobalHandler`, with the bundle's frames, the screen
and the last 10 screen and event names, never a property value, never a log line. Your own handler and other crash
reporters keep running, after the report. Non-fatal errors count apart (`ErrorUtils.reportError`). Native crashes
and ANRs come from the iOS and Android layers. A JavaScript crash that ends in a native abort counts once. Crashes never
count in your quota.

**Readable stacks: upload your symbols after each release build**, with the upload token of App settings › SDK in the
environment, `SCRUTER_UPLOAD_TOKEN=scr_up_…` (your CI's secrets, **never in the project**):

```sh
npx scruter symbols upload --app ATMONA02
```

| What | Where it comes from |
|---|---|
| JavaScript source map, Hermes or JavaScriptCore | Android: `android/app/build/generated/sourcemaps/react/release/`. iOS: see below. A Hermes map must be the composed one, which is what React Native's build writes. Your source code is left out of the upload |
| R8 mapping | `android/app/build/outputs/mapping/release/mapping.txt` |
| dSYMs | handed to the iOS SDK's `upload-symbols` (on a Mac, from `ios/build`, or `--dsym <path>`) |

**iOS keeps no source map by default.** Add this line at the top of the build phase "Bundle React Native code and
images" (the Expo plugin does it):

```sh
export SOURCEMAP_FILE="$(pwd)/../main.jsbundle.map"
```

For the R8 mapping to match its crashes, apply the Gradle plugin of the Android SDK in `android/app/build.gradle`
(`id("net.scruter.symbols")`, [its guide](../android/README.md#install)); it can upload the mapping itself, and replaces the
placeholder above with `scruter { appId = "ATMONA02" }`.

The command skips what Scruter already has and never fails your build unless `--strict` says so. `--dry-run` shows what
would be sent; `--help` lists the options.

**Which bundle crashed.** By default a bundle is named by its app version and build. An app that ships JavaScript without
a new build (EAS Update, CodePush) needs an id per bundle: in `metro.config.js`:

```js
const { withScruter } = require('@scruter/react-native/metro');

module.exports = withScruter(mergeConfig(getDefaultConfig(__dirname), config));
```

Run `scruter symbols upload` for each update, with `--sourcemap` when your update tool writes the map elsewhere.

## Installs from campaigns

iOS: declare Scruter in your Info.plist, as [the iOS guide](../ios/README.md#installs-from-campaigns-skadnetwork-and-adattributionkit)
says (the Expo plugin does it). Android: the Play Install Referrer is read once, by the SDK.

## Opt-out

The audience-measurement exemption needs no consent, but users may object. Wire your app's "Audience measurement" setting:

```ts
Scruter.optOut();       // nothing more is sent; the queue, the daily identifier and the install day are deleted
Scruter.optIn();        // measured again, as a new install without an install day
Scruter.isOptedOut;
```

For your own test phones ("Test devices"): `Scruter.ignoreThisDevice()`, `Scruter.stopIgnoringThisDevice()`,
`Scruter.isDeviceIgnored`.

## Store declarations

The iOS SDK ships its `PrivacyInfo.xcprivacy`; the Android SDK declares no `AD_ID` permission. Scruter › App settings ›
Privacy gives the store declarations to copy into App Store Connect and the Play Console.

## Debug logging

`debug: true` logs every screen, event and batch to Metro's console as well as the system's (os_log, Logcat), every limit
applied, and the server's warnings in debug builds. Property values are logged only in debug builds. Leave it off in
release builds.

## Sending, offline, limits

As in the native SDKs: a queue in the app's private storage, batches every 30 s in the foreground and when the app goes to
the background, 5 000 items or 5 MB for 48 hours offline. `Scruter.flush()` sends now.

What the SDK does not see: on Android, taps inside React Native's `Modal`, which is another window (its screens and events
count); views drawn without host views (Skia, a game).

## Budget on the phone

| | Budget | Measured |
|---|---|---|
| JavaScript, min + gzip | ≤ 30 KB | 2.9 KB (`npm run budget`, a CI gate) |
| Native SDKs | [iOS](../ios/README.md#budget-on-the-phone), [Android](../android/README.md#budgets) | the same SDKs, plus a small module of Java or Swift classes (`android/src`, `ios`) |
| A call from JavaScript, on the JS thread | no disk, no network | `track`: 0.01–0.1 ms, ≈ 1 ms the first time; `start`: 0.5–2 ms (CI emulator and simulator, release builds; 60–170 ms on the new architecture's cold iOS simulator, the runtime creating the module, on the JS thread and not the main one) |
| A tap in the Advanced analytics sample | ≤ 1 ms on the main thread | 0.3–0.6 ms on a screen of 25 elements (Android emulator) |

## Example app and tests

`example/` holds an app with navigation, a list, a form and a masked view, generated for any React Native version
(`example/README.md`). The CI (`.github/workflows/react-native.yml`) runs Jest, the conformance kit and the budget, then
the example's **release build on an Android emulator and an iOS simulator**, on React Native 0.73, 0.81, 0.86 and 0.88, old
and new architecture, with real touches: every request is checked against `../protocol`, a real crash is resolved through its
real source map, a QR code makes a team phone, and an opted-out app sends nothing. The Expo jobs build a development build of an Expo Router app from the
config plugin alone, on SDK 57 (React Native 0.86) on both platforms and SDK 58 on Android.

```sh
npm ci && npm test && npm run typecheck && npm run budget
```
