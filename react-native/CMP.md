# Scruter CMP for React Native

The consent banner of [Scruter CMP](https://scruter.net/cmp) in your React Native app, with a proof of every choice.
`ScruterCMP`, in `@scruter/react-native`, is a thin layer over the native modules of [iOS](../ios/CMP.md) and
[Android](../android/CMP.md): the sheet is native (SwiftUI on iOS, the platform's views on Android), presented over your
app whatever its navigation (React Navigation, Expo Router); the choice, the proofs and their queue live in the native
modules. Your JavaScript reads the answer and starts your SDKs accordingly.

React Native 0.73 and later, new and old architecture, Expo development builds and EAS Build. iOS 15, Android 7 (API
24). MIT. No IDFA, no GAID, no device identifier: the only identifier is the random consent id the visitor gets as a
receipt.

## Install

```sh
npm install @scruter/react-native
npm pkg set scruter.cmp=true --json
cd ios && pod install
```

`@scruter/react-native` carries Scruter Analytics and Scruter CMP; your app's `package.json` says which ones it takes,
and only their native code goes into the app:

```json
"scruter": { "cmp": true }
```

- `"cmp": true` adds Scruter CMP. Scruter Analytics stays, as before.
- `"analytics": false` leaves Scruter Analytics out: an app that takes the CMP alone sets both,
  `"scruter": { "cmp": true, "analytics": false }` (or `npm pkg set scruter.analytics=false --json`).
- Without the key, nothing changes: Scruter Analytics alone.

The podspec and the Android Gradle build read it, so rebuild the app after a change (`cd ios && pod install`, then a new
build).
Without the native module, `ScruterCMP.start` says so in the console and grants nothing.

### Expo

Add the key to `package.json` as above, and the plugin to `app.json`:

```json
"plugins": [["@scruter/react-native", { "trackingDescription": "To show you ads about the pieces you liked." }]]
```

The CMP needs nothing from the plugin but, when your app asks Apple's tracking prompt after the CMP (below), the
prompt's text (`NSUserTrackingUsageDescription`). An app with Scruter Analytics too keeps its `"appId"` there. Then
`npx expo prebuild`, or an EAS build. Expo Go cannot load a native module: use a development build.

## Start

Your app's code is on its page in Scruter CMP, under Installation (`ATMONA02`). Start the CMP once, before
`AppRegistry`, in `index.js`:

```ts
import { AppRegistry } from 'react-native';
import { ScruterCMP } from '@scruter/react-native';
import App from './src/App';

ScruterCMP.start({ appId: 'ATMONA02' });
ScruterCMP.whenReady(applyConsent);
ScruterCMP.onChange(applyConsent);

AppRegistry.registerComponent('AtelierMona', () => App);
```

That is all it takes for the banner to show: at the first launch, the native sheet slides up over your app once its
first screen is drawn, and stays until the visitor chooses. Your app keeps working behind it, its optional SDKs off.

`start` returns at once. A JavaScript reload starts nothing again: the native module runs once per process, and the new
JavaScript context hears each change once.

## The settings entry first

An app has no floating button: **your app must offer a way to change or withdraw the choice**, as easily as it was
given. Add an entry such as « Gérer mes cookies », « Privacy choices » or « Confidentialité » to your settings:

```tsx
<Button title="Privacy choices" onPress={() => ScruterCMP.showPreferences()} />
```

The preferences list every purpose with its switch, show the visitor's consent id as a receipt, and withdraw in one
gesture. In a debug build, the native module warns when `showPreferences()` was never called in 10 launches after a
decision.

## Read the choice

Until a choice exists, every optional purpose is denied.

```ts
ScruterCMP.isGranted('analytics');      // synchronous; false until a choice exists
ScruterCMP.isGranted('crash_reports');  // your banner's own purposes, by key
ScruterCMP.state;                       // 'ready' | 'needsDecision' | 'unavailable'
ScruterCMP.choice;                      // { consentId, decidedAt, granted, denied, isGranted() } or null
ScruterCMP.consentId;                   // the visitor's receipt, cns_…, or null

// Once a valid choice exists: now (a returning visitor), or after the decision.
const ready = ScruterCMP.whenReady((choice) => applyConsent(choice));
// Every later change: the preferences, a withdrawal, the banner asking again.
const changes = ScruterCMP.onChange((choice) => applyConsent(choice));
changes.remove();
```

`ScruterPurpose` names the usual keys (`ScruterPurpose.analytics`, `.advertising`, `.personalization`,
`.embeddedContent`, `.socialMedia`, `.functional`). In a component, `useConsentChoice()` gives the current choice and
re-renders when it changes:

```tsx
function AdSlot() {
  const choice = useConsentChoice();
  return <BannerAd unitId={UNIT} requestOptions={{ requestNonPersonalizedAdsOnly: !choice?.isGranted('advertising') }} />;
}
```

While the banner asks again (a new purpose, a revision, the period), `choice` is `null` and `isGranted` keeps the
answers of the purposes that did not change, until the new decision.

## Gate your SDKs

The CMP decides nothing for your SDKs: your code starts them according to the answer, in `applyConsent`. Turn each
SDK's automatic start off in its configuration, as the [iOS](../ios/CMP.md#gate-your-sdks) and
[Android](../android/CMP.md) guides show for the native SDKs, then:

```ts
import { getAnalytics, setAnalyticsCollectionEnabled, setConsent } from '@react-native-firebase/analytics';
import { getCrashlytics, setCrashlyticsCollectionEnabled } from '@react-native-firebase/crashlytics';
import mobileAds from 'react-native-google-mobile-ads';
import { Settings } from 'react-native-fbsdk-next';
import { ScruterCMP, type ScruterChoice } from '@scruter/react-native';

async function applyConsent(choice: ScruterChoice) {
  const analytics = choice.isGranted('analytics');
  const ads = choice.isGranted('advertising');

  // Firebase (firebase.json: "analytics_auto_collection_enabled": false, "crashlytics_auto_collection_enabled": false)
  await setAnalyticsCollectionEnabled(getAnalytics(), analytics);
  await setConsent(getAnalytics(), firebaseConsent());
  await setCrashlyticsCollectionEnabled(getCrashlytics(), analytics);

  // Google Mobile Ads: without the IAB TCF, non-personalised ads unless advertising is granted
  // (requestNonPersonalizedAdsOnly: !ads in each request's options).
  await mobileAds().initialize();

  // Meta (app.json of react-native-fbsdk-next: autoLogAppEventsEnabled and advertiserIDCollectionEnabled false)
  Settings.setAutoLogAppEventsEnabled(ads);
  Settings.setAdvertiserIDCollectionEnabled(ads);
}
```

The other SDKs of the console's installation page, with their React Native packages:

| SDK | Purpose | When granted | On a refusal or a withdrawal |
|---|---|---|---|
| AppsFlyer (`react-native-appsflyer` 7) | advertising | `AppsFlyer.stop({ shouldStop: false })`, then `AppsFlyer.start()` once its session is ready (`registerSessionReadyListener`) | `AppsFlyer.stop({ shouldStop: true })` |
| Adjust (`react-native-adjust` 5) | advertising | `Adjust.initSdk(new AdjustConfig(token, AdjustConfig.EnvironmentProduction))`, `Adjust.enable()` | `Adjust.disable()` |
| OneSignal (`react-native-onesignal` 5) | personalization | `OneSignal.setConsentRequired(true)` before `initialize`, then `OneSignal.setConsentGiven(true)` | `OneSignal.setConsentGiven(false)` |
| Sentry (`@sentry/react-native`) | analytics | `Sentry.init({ dsn })` | `Sentry.close()` |
| Braze (`@braze/react-native-sdk`) | personalization | `Braze.enableSDK()` | `Braze.disableSDK()` |
| Amplitude (`@amplitude/analytics-react-native`) | analytics | `setOptOut(false)` | `setOptOut(true)` |
| Mixpanel (`mixpanel-react-native`, `optOutTrackingDefault: true`) | analytics | `mixpanel.optInTracking()` | `mixpanel.optOutTracking()` |

The purpose is the console's suggestion: use the key of your banner's purpose that covers the SDK. Scruter Analytics,
when your app uses it, is exempt and never gated.

## Google Consent Mode

`consentModeSignals()` gives the seven signals of the current choice with your banner's mapping (Scruter CMP ›
Bannière › Google Consent Mode): every signal denied until a choice exists but `security_storage`. For React Native
Firebase:

```ts
function firebaseConsent() {
  const s = ScruterCMP.consentModeSignals();
  return {
    analytics_storage: s.analytics_storage === 'granted',
    ad_storage: s.ad_storage === 'granted',
    ad_user_data: s.ad_user_data === 'granted',
    ad_personalization: s.ad_personalization === 'granted',
  };
}
```

The proof records the signals sent as granted.

## App Tracking Transparency

The CMP comes first; Apple's tracking prompt only for a visitor who granted `advertising`:

```ts
ScruterCMP.whenReady(async () => {
  const status = await ScruterCMP.requestTrackingIfGranted();
  // 'authorized': your ad SDKs may read the IDFA.
});
```

It asks only when `advertising` is granted, Apple's status is `notDetermined` and no sheet is on screen; otherwise it
answers the current status without asking. The prompt's text is your `NSUserTrackingUsageDescription` (the Expo
plugin's `trackingDescription`); without it, nothing is asked. Android has no such prompt: `'unsupported'`.

## Showing the banner yourself

By default the sheet shows by itself. To show it after your onboarding (never after a paywall or a sign-in wall: the
banner comes first):

```ts
ScruterCMP.start({ appId: 'ATMONA02', presentation: 'manual' });
// … when the onboarding ends:
ScruterCMP.showIfNeeded();
```

The sheet shows over the screen on top, a React Navigation or Expo Router modal included.

## Languages

The banner speaks the first of the device's preferred languages it was published in, else its default language. An
app with its own language setting overrides it with `ScruterCMP.setLanguage('de')` (`null` follows the device again).

## Debug

- `ScruterCMP.debug = true` logs the state and every decision: the native module's lines in Xcode's console or Logcat
  (tag `ScruterCMP`), this layer's in Metro.
- `ScruterCMP.debugReset()` forgets the choice in a debug build: the sheet shows again.
- `ScruterCMP.forceShow = true`, before `start`, shows the sheet at every opening (screenshots, end-to-end tests).
- A debug build (the simulator, a development-signed or debuggable app) marks its beacons as such: its proofs stay out
  of your registry, statistics and webhooks, and show for 24 hours in the installation check of Scruter CMP.
- End-to-end tests find the iOS sheet's elements by the identifiers of the [iOS guide](../ios/CMP.md#debug), and the
  Android sheet's by their text.

## Store declarations and privacy

What the modules store and send, the Apple privacy manifest (shipped in the pod) and the App Store and Google Play
answers are those of the native modules: [iOS](../ios/CMP.md#what-the-module-stores-and-sends),
[Android](../android/CMP.md). The React Native layer adds nothing: the beacons name it (`cv`: `react_native/1.2.0`).

## Size

Measured in CI on the example's release build (`scripts/cmp-size.mjs`, `.github/workflows/react-native.yml`, React
Native 0.88, new architecture), the example built three times: Scruter Analytics alone, both modules, Scruter CMP
alone.

| Release build of the example | Android: APK (Hermes, R8, arm64-v8a) | iOS: app binary and Scruter bundles (arm64, stripped) |
|---|---|---|
| Scruter Analytics alone | 19 557 KB | 1 708 KB |
| Scruter Analytics and Scruter CMP | 19 624 KB | 2 274 KB |
| Scruter CMP alone | 19 567 KB | 1 812 KB |
| **What Scruter CMP adds** | **67 KB** (81 KB of dex before compression) | **566 KB** |

Each build carries only its modules' code (the CI looks for each module's own strings in it). The package's whole JavaScript,
both modules, is about 4 KB minified and gzipped (`npm run budget`).

## Example app and tests

`example/setup.mjs --cmp` generates the example with the CMP: its Privacy screen shows the state, the receipt, how many
times `whenReady` and `onChange` were heard, stand-ins for Firebase Analytics, Google Mobile Ads and an attribution SDK
gated on the answer, the settings entry and the debug reset (`--cmp only` leaves Scruter Analytics out). Jest tests the
JavaScript layer against a mocked native module; in CI (`.github/workflows/react-native.yml`), the example runs on an
Android emulator and an iOS simulator, oldest and latest React Native, against the CMP's stub ingest
(`scripts/cmp-device-check.mjs`, Maestro): first launch, decision, preferences, withdrawal, a JavaScript reload without
a second listener, a returning visitor, the debug reset, every beacon checked against `protocol/schema`.
