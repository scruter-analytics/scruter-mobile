# Scruter CMP for iOS

The consent banner of [Scruter CMP](https://scruter.net/cmp) in your iOS app, as a native sheet, with a proof of every
choice. You publish the banner in Scruter CMP (texts, colours, image or video header, languages, A/B tests); the module
draws it in SwiftUI, keeps the visitor's choice in the app's own storage, tells your code what is granted, and sends
the proof to the registry. It asks again when the rules of your banner say so, exactly as on your website.

- **Native**: SwiftUI, presented from SwiftUI and UIKit apps alike; a bottom sheet on iPhone, a centred card on iPad;
  the system font, Dynamic Type up to the largest sizes, VoiceOver, dark mode, right to left for Arabic.
- **No identifier of the device**: no IDFA, no IDFV, no fingerprint. The only identifier is the random consent id the
  visitor gets as a receipt, kept in your app's storage. The module never asks App Tracking Transparency by itself.
- **Independent**: no third-party dependency, no link with Scruter Analytics (take one module, the other or both).

Requirements: iOS 15+, Xcode 15+, Swift 5.9+. MIT licence.

## Install

**Swift Package Manager**: Xcode › File › Add Package Dependencies…, then

```
https://github.com/scruter-analytics/scruter-mobile
```

and add the **ScruterCMP** product to your app target. In a `Package.swift`:

```swift
.package(url: "https://github.com/scruter-analytics/scruter-mobile", from: "1.2.0"),
// …
.product(name: "ScruterCMP", package: "scruter-mobile"),
```

**CocoaPods**: in the `Podfile`, from this repository:

```ruby
pod 'ScruterCMP', :git => 'https://github.com/scruter-analytics/scruter-mobile', :tag => '1.2.0'
```

## Start

Your app's code is on its page in Scruter CMP, under Installation (`ATMONA02`). Start the module first thing at launch:

```swift
import ScruterCMP

@main struct AtelierMonaApp: App {
    init() {
        ScruterCMP.start(appId: "ATMONA02")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

With UIKit, call it in `application(_:didFinishLaunchingWithOptions:)`. That is all it takes for the banner to show:
at the first launch, the sheet slides up over your app once its first frame is drawn, and stays until the visitor
chooses (no gesture closes it). Your app keeps working behind it, its optional SDKs off.

`start` reads the stored choice at once (one small storage read on the main thread, nothing else): from the next line,
`ScruterCMP.isGranted(.analytics)` answers. The configuration and the network are on the module's own queue.

## The settings entry first

An app has no floating button: **your app must offer a way to change or withdraw the choice**, as easily as it was
given. Add an entry such as « Gérer mes cookies », « Privacy choices » or « Confidentialité » to your settings, and
open the preferences from it:

```swift
// SwiftUI
Button("Privacy choices") { ScruterCMP.showPreferences() }

// UIKit
ScruterCMP.showPreferences(from: self)
```

The preferences list every purpose with its switch and show the visitor's consent id as a receipt; « Tout refuser »
there, after a consent, withdraws it (recorded as `withdraw`). In a debug build, the module warns in the console when `showPreferences()` was
never called in 10 launches after a decision.

## Gate your SDKs

The module decides nothing for your SDKs: your code starts them according to the answer. Until a choice exists, every
optional purpose is denied.

```swift
ScruterCMP.start(appId: "ATMONA02")

// Once a valid choice exists: now (a returning visitor), or after the decision.
ScruterCMP.whenReady { choice in
    Partners.apply(choice)
}
// Every later change: the preferences, a withdrawal, the banner asking again.
ScruterCMP.onChange { choice in
    Partners.apply(choice)
}
```

Both callbacks run on the main thread. `ScruterCMP.isGranted(_:)` answers synchronously anywhere. Purposes are your
banner's keys: `.analytics`, `.advertising`, `.personalization`, `.embeddedContent`, `.socialMedia`, `.functional`,
and your own with `isGranted(custom: "crash_reports")`.

Turn each SDK's automatic start off in its configuration (the `Info.plist` keys below), then apply the choice:

**Firebase Analytics** (`Info.plist`: `FIREBASE_ANALYTICS_COLLECTION_ENABLED` = NO, and the four
`GOOGLE_ANALYTICS_DEFAULT_ALLOW_*` keys = NO):

```swift
Analytics.setAnalyticsCollectionEnabled(choice.isGranted(.analytics))
Analytics.setConsent(firebaseConsent())   // Consent Mode, below
```

**Firebase Crashlytics** (`Info.plist`: `FirebaseCrashlyticsCollectionEnabled` = NO):

```swift
Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(choice.isGranted(.analytics))
```

**Google Mobile Ads**: without the IAB TCF, ads stay non-personalised unless `advertising` is granted:

```swift
let request = Request()                       // GADRequest before version 12
if !choice.isGranted(.advertising) {
    let extras = Extras()                     // GADExtras before version 12
    extras.additionalParameters = ["npa": "1"]
    request.register(extras)
}
```

**Meta** (`Info.plist`: `FacebookAutoLogAppEventsEnabled` = NO, `FacebookAdvertiserIDCollectionEnabled` = NO):

```swift
Settings.shared.isAutoLogAppEventsEnabled = choice.isGranted(.advertising)
Settings.shared.isAdvertiserIDCollectionEnabled = choice.isGranted(.advertising)
Settings.shared.isAdvertiserTrackingEnabled = choice.isGranted(.advertising)   // SDKs that still have it
```

**AppsFlyer**: start it only with `advertising`, stop it on a withdrawal:

```swift
let af = AppsFlyerLib.shared()
af.setConsentData(AppsFlyerConsent(isUserSubjectToGDPR: true,
                                   hasConsentForDataUsage: choice.isGranted(.advertising),
                                   hasConsentForAdsPersonalization: choice.isGranted(.advertising),
                                   hasConsentForAdStorage: choice.isGranted(.advertising)))
af.isStopped = !choice.isGranted(.advertising)
if choice.isGranted(.advertising) { af.start() }
```

**Adjust** (version 5):

```swift
if choice.isGranted(.advertising) {
    Adjust.initSdk(ADJConfig(appToken: "…", environment: ADJEnvironmentProduction))
    Adjust.enable()
} else {
    Adjust.disable()
}
Adjust.trackThirdPartySharing(ADJThirdPartySharing(isEnabled: NSNumber(value: choice.isGranted(.advertising))))
```

**OneSignal** (version 5): before `OneSignal.initialize`, `OneSignal.setConsentRequired(true)`; then

```swift
OneSignal.setConsentGiven(choice.isGranted(.personalization))
```

**Sentry**:

```swift
if choice.isGranted(.analytics) {
    SentrySDK.start { options in options.dsn = "…" }
} else {
    SentrySDK.close()
}
```

**Braze** (Swift SDK): create the instance only with the purpose, and turn it off on a withdrawal:

```swift
if choice.isGranted(.personalization), AppDelegate.braze == nil {
    AppDelegate.braze = Braze(configuration: Braze.Configuration(apiKey: "…", endpoint: "…"))
}
AppDelegate.braze?.enabled = choice.isGranted(.personalization)
```

**Amplitude** (Amplitude-Swift):

```swift
amplitude.optOut = !choice.isGranted(.analytics)
```

**Mixpanel**: initialise with `optOutTrackingByDefault: true`, then

```swift
choice.isGranted(.analytics) ? Mixpanel.mainInstance().optInTracking() : Mixpanel.mainInstance().optOutTracking()
```

Scruter Analytics, when your app uses it, is exempt and never gated: it measures without any identifier that outlives
the day.

## Google Consent Mode

`consentModeSignals()` gives the seven signals of the current choice with your banner's mapping (Scruter CMP ›
Bannière › Google Consent Mode): every signal denied until a choice exists but `securityStorage`. For Firebase:

```swift
func firebaseConsent() -> [ConsentType: ConsentStatus] {
    var out: [ConsentType: ConsentStatus] = [:]
    for (signal, status) in ScruterCMP.consentModeSignals()
    where [.analyticsStorage, .adStorage, .adUserData, .adPersonalization].contains(signal) {
        out[ConsentType(rawValue: signal.rawValue)] = status == .granted ? .granted : .denied
    }
    return out
}
```

The proof records the signals sent as granted.

## IAB TCF

When your site's IAB TCF v2.2 settings are on in Scruter CMP (Intégration › IAB TCF: the vendors, the legal basis of
each IAB purpose, the publisher's country — the same page for a site and its app), the module is a TCF CMP (CMP ID 528):

- **The sheet** speaks IAB's text in the message's place (« Nous et nos 10 partenaires stockent… »), with links to the
  partners, the objections to legitimate interest and your privacy policy; each Personnaliser step shows the IAB
  purposes grouped under its purpose; a last step lists the partners (with a search) and each partner's declarations;
  the preferences open every IAB purpose and the partners. IAB's texts come in the banner's language from Scruter
  (never from consensu.org).
- **The keys**: the `IABTCF_*` keys of IAB's in-app specification in `UserDefaults.standard`, written before the sheet
  closes and kept in step with every change (a decision, the preferences, a withdrawal, a re-ask, `debugReset()`, the
  TCF turned off): `IABTCF_CmpSdkID` (528), `IABTCF_CmpSdkVersion`, `IABTCF_PolicyVersion`, `IABTCF_gdprApplies` (1:
  the same banner for everyone), `IABTCF_PublisherCC`, `IABTCF_PurposeOneTreatment`, `IABTCF_UseNonStandardTexts`,
  `IABTCF_TCString`, `IABTCF_VendorConsents`, `IABTCF_VendorLegitimateInterests`, `IABTCF_DisclosedVendors`,
  `IABTCF_PurposeConsents`, `IABTCF_PurposeLegitimateInterests`, `IABTCF_SpecialFeaturesOptIns`,
  `IABTCF_PublisherRestrictions{purpose}` and the publisher's keys. The first five are there as soon as the
  configuration arrives, so vendors know a CMP is present before the choice.
- **Your ad SDKs read the keys themselves**: Google Mobile Ads (AdMob, Ad Manager), AppLovin, ironSource and the other
  TCF vendors need no code. Start them from `whenReady` as usual; the keys are written before `whenReady` and
  `onChange` run.
- **Never Google's UMP SDK beside Scruter CMP**: one CMP per app (IAB's rule), else the two overwrite each other's keys.
  Remove `UserMessagingPlatform` and its consent form when you install `ScruterCMP`.
- **Google's other ad tech providers** (its Additional Consent list: Google Ad Manager, AdSense and AdMob partners that
  are not registered with the IAB TCF): tick those you work with in the console's IAB settings (« Autres partenaires de
  Google »). The sheet lists them after the TCF's partners, each with its consent switch and privacy policy, and writes
  Google's Additional Consent string v2 in `IABTCF_AddtlConsent` (`2~<consented ids>~dv.<ids only disclosed>`), which
  Google Mobile Ads reads with the TC string. Their consent needs IAB purposes 1, 3 and 4 (storage, profiles and
  personalised ads); adding one asks your visitors again. Without any, the key is not written.
- **Test it**: `ScruterCMP.debug = true` logs « TC string written » (« TC string and Additional Consent string
  written » with Google's providers); read the keys in your debug build
  (`UserDefaults.standard.string(forKey: "IABTCF_TCString")`) and paste the string in IAB's decoder
  (https://iabtcf.com/#/decode); `debugReset()` removes the keys with the choice. The example app shows what a TCF
  vendor reads (`ios/ExampleCMP`).

## App Tracking Transparency

The CMP comes first; Apple's tracking prompt only for a visitor who granted `advertising`:

```swift
ScruterCMP.whenReady { _ in
    ScruterCMP.requestTrackingIfGranted { status in
        // .authorized: your ad SDKs may read the IDFA.
    }
}
```

It asks only when `advertising` is granted, Apple's status is `notDetermined` and no sheet is on screen; otherwise it
returns the current status without asking. The prompt's text is your `NSUserTrackingUsageDescription` (without it,
nothing is asked). Whether to show a short explanation before Apple's prompt is your choice. The module links no
AppTrackingTransparency: it reaches it at run time, so an app that never asks carries no reference to it.

## Showing the banner yourself

By default the sheet shows by itself. To show it after your onboarding (never after a paywall or a sign-in wall: the
banner comes first):

```swift
ScruterCMP.start(appId: "ATMONA02", presentation: .manual)
// … when the onboarding ends:
ScruterCMP.showIfNeeded(from: viewController)   // or showIfNeeded() in SwiftUI
```

`ScruterCMP.state` is `.ready` (a valid choice), `.needsDecision` (the sheet must show) or `.unavailable` (no
configuration could be fetched and none is cached: every optional purpose stays denied, the module tries again at the
next foreground and when the network returns).

## Languages

The banner speaks the first of the device's preferred languages it was published in, else its default language.
An app with its own language setting overrides it:

```swift
ScruterCMP.setLanguage("de")   // nil follows the device again
```

## Debug

- `ScruterCMP.debug = true` logs the state, the configuration's revision and every decision to the console.
- `ScruterCMP.debugReset()` forgets the choice in a debug build: the sheet shows again.
- `ScruterCMP.forceShow = true`, before `start`, shows the sheet at every opening (screenshots, UI tests).
- A debug build (the simulator, or a development-signed app) marks its beacons as such: its proofs stay out of your
  registry, statistics and webhooks, and show for 24 hours in the installation check of Scruter CMP; its openings
  count nowhere. TestFlight and App Store builds are release builds.
- UI tests find the sheet's elements by identifier: `scruter-cmp-accept-all`, `scruter-cmp-reject-all`,
  `scruter-cmp-customize`, `scruter-cmp-close`, `scruter-cmp-save`, `scruter-cmp-next`, `scruter-cmp-back`,
  `scruter-cmp-switch-<purpose>`, `scruter-cmp-preferences-close`; with the TCF
  `scruter-cmp-iab-<purpose>`, `scruter-cmp-li-<purpose>`, `scruter-cmp-sf-<feature>`, `scruter-cmp-vendor-<id>`,
  `scruter-cmp-vendor-consent-<id>`, `scruter-cmp-detail-consent`, `scruter-cmp-detail-li`, `scruter-cmp-search`,
  `scruter-cmp-tcf-back`, `scruter-cmp-tcf-purposes`, `scruter-cmp-tcf-partners`.

## What the module stores and sends

- **Stored on the device**: the choice under the key `choice` of `UserDefaults(suiteName: "net.scruter.cmp")` (the
  consent id, the time, the banner version and the granted purposes, the same format as the web's cookie), with the TCF
  its TC string (`tcf`) and the `IABTCF_*` keys in `UserDefaults.standard`; in
  `Library/Application Support/ScruterCMP/` the cached configuration and texts, the beacons waiting to be sent (48 hours
  at most) and a few counters; in `Library/Caches/ScruterCMP/` the banner's images and video.
- **Sent to `cdn.scruter.net`**: the configuration request (your app's code, its version, the module's version); one
  hit per opening (a cold start, or a return after 30 minutes): the banner version, the language, whether the sheet
  showed, the screen's shorter side, your bundle id and app version; one proof per decision: the consent id, the
  action, the purposes granted and refused, the hash of the texts shown, the time to decide; once per app version, the
  keys of the known third-party SDKs linked into the app (a class present or not, nothing else about your app); with
  the TCF, the proof carries the TC string and the module fetches the vendor list of your selection and IAB's texts.
- Never: an advertising or vendor identifier, the device's name or model, an IP address stored by Scruter, a user id,
  a location.

### Privacy manifest and App Store answers

The module ships its `PrivacyInfo.xcprivacy`: no tracking, no tracking domain; `UserDefaults` for the app's own data
(reason CA92.1); collected data not linked to the user and not used for tracking: « Other data types » (the consent
choices and their receipt, for app functionality: the proof you must keep) and « Product interaction » (the openings
and whether the banner showed, for analytics of your banner). In App Store Connect › App Privacy, declare the same for
the module: Other Data and Product Interaction, not linked to the user's identity, not used for tracking.

## Size and performance

The module adds about 1 040 KB to an arm64 release app, most of it the IAB TCF's layers, model and words in 33
languages (measured in CI by `ios/scripts/cmp-size.sh`, budget 1 100 KB).
On the main thread it reads the stored choice once at launch; the network, JSON and images are on its own queue. The
configuration is fetched once per `ttl` (an hour by default, a `304` most of the time).

## Example apps

`ios/ExampleCMP/` holds a SwiftUI app (automatic presentation) and a UIKit app (manual presentation after an
onboarding), both with the settings entry, stand-ins for Firebase, Google Mobile Ads and an attribution SDK gated on
the answer, and ATT after the CMP. `xcodegen` in that directory generates the project.
