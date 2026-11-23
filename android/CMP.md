# Scruter CMP for Android

The consent sheet of Scruter CMP in an Android app: the same banner, texts, purposes, proofs and statistics as on your
website, drawn with Android's own views. The visitor's choice is kept in your app's storage; every decision leaves a
proof in Scruter's registry; your app starts its SDKs (Firebase, Google Mobile Ads, Meta, AppsFlyer…) according to it.

Android 7 (API 24) and later. Jetpack Compose and Views apps alike. No runtime dependency besides the Kotlin standard
library your app already has: the module adds about 160 KB to an app after R8, 85 KB of download (measured in CI by
`budget-cmp`, the sheet's words in 33 languages included: budget 350 KB). MIT. It does not depend on Scruter Analytics, nor Scruter Analytics on it: take one, the other or both.

- [Install](#install)
- [Start](#start)
- [The settings entry first](#the-settings-entry-first)
- [When the sheet shows](#when-the-sheet-shows)
- [Reading the choice](#reading-the-choice)
- [Gating your app's SDKs](#gating-your-apps-sdks)
- [Google Consent Mode](#google-consent-mode)
- [Languages](#languages)
- [Debug builds](#debug-builds)
- [What the module stores and sends](#what-the-module-stores-and-sends)
- [Google Play data safety](#google-play-data-safety)

## Install

In the app module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation("net.scruter:scruter-cmp:1.2.0")
    // Optional, for Compose apps: ScruterConsentHost, rememberConsentChoice(), choices() as a Flow.
    implementation("net.scruter:scruter-cmp-compose:1.2.0")
}
```

The module declares the `INTERNET` and `ACCESS_NETWORK_STATE` permissions (both normal permissions, granted at install:
the second lets it try again when the network returns). No advertising id, no `AD_ID` permission.

## Start

In your `Application`, with the app id shown in Scruter (« Sites et apps », the app's installation page):

```kotlin
class AtelierMonaApp : Application() {
    override fun onCreate() {
        super.onCreate()
        ScruterCMP.start(this, "ATMONA02")
    }
}
```

`start` reads the stored choice at once (one read of the app's storage, well under a millisecond): `isGranted` answers
from the next line. Then, off the main thread, it fetches the banner's configuration (cached, revalidated with its ETag
every `ttl`, an hour by default) and shows the sheet over your first screen when a decision is needed. Until a choice
exists, every optional purpose is denied. Your app keeps working meanwhile.

## The settings entry first

An app has no floating button: your app's settings must give the visitor a way back to their choices, such as
« Confidentialité » or « Gérer mes cookies », that opens the preferences. It is how a visitor changes their mind or
withdraws consent, as easily as they gave it; the stores and the regulators expect it.

```kotlin
// Views
privacyRow.setOnClickListener { ScruterCMP.showPreferences(this) }

// Compose
ListItem(
    headlineContent = { Text(stringResource(R.string.privacy_choices)) },
    modifier = Modifier.clickable { ScruterCMP.showPreferences(activity) },
)
```

The preferences list every purpose with its state, the visitor's consent id (their receipt, with a copy button) and the
date of their choice. « Tout refuser » there, after a consent, is recorded as a withdrawal. Debug builds log a warning when
`showPreferences` was never called during 10 launches after a decision.

## When the sheet shows

- **Automatically** (the default): over the resumed activity, once its first frame is drawn, whenever a decision is
  needed: no choice yet, or the banner asks again (a new purpose, a purpose whose meaning changed, the re-consent period
  ran out — checked at each start and each return to the foreground).
- **Manually**: start with `Presentation.MANUAL`, then show it where your app wants, after an onboarding, never after a
  paywall or a sign-in wall (the banner comes first):

  ```kotlin
  ScruterCMP.start(this, "ATMONA02", Presentation.MANUAL)
  // … at the end of the onboarding:
  ScruterCMP.showIfNeeded(activity)
  ```

  Called before the first configuration has arrived, `showIfNeeded` waits for it. In Compose, `ScruterConsentHost`
  does the same each time its screen resumes:

  ```kotlin
  setContent { ScruterConsentHost { AppNavHost() } }
  ```

The sheet is a bottom sheet on phones and a centred card on tablets. It cannot be swiped or touched away. Android's back
action on its first layer is « close »: recorded as `close`, a refusal, like the close button of a web banner; in
« Personnaliser » it goes back a step. After a choice, a short confirmation shows for four seconds.

## Reading the choice

```kotlin
ScruterCMP.isGranted(Purpose.ANALYTICS)          // synchronous; false until a choice exists
ScruterCMP.isGranted("crash_reports")            // a purpose of your own banner
ScruterCMP.state                                 // READY, NEEDS_DECISION or UNAVAILABLE
ScruterCMP.choice                                // the valid choice, or null
ScruterCMP.consentId                             // "cns_…", the visitor's receipt

ScruterCMP.whenReady { choice -> start(choice) } // once a valid choice exists: now, or after the decision
ScruterCMP.onChange { choice -> apply(choice) }  // each new valid choice: a decision, the preferences, a withdrawal
```

Listeners run on the main thread; `whenReady` and `onChange` return a `Subscription` to `cancel()`. With
`scruter-cmp-compose`:

```kotlin
val choice by rememberConsentChoice()            // Compose state
ScruterCMP.choices().collect { apply(it) }       // a Flow: the current choice, then every change
```

During a re-ask, a purpose that did not change keeps its answer until the new decision. `UNAVAILABLE` means no
configuration could be fetched and none is cached, or the app has no published banner: every optional purpose stays
denied, and the module tries again at the next return to the foreground and when the network returns.

## Gating your app's SDKs

Scruter Analytics is exempt from consent (no cookie, no identifier that lasts beyond the day): start it as usual, never
behind the CMP. Every other SDK that stores or reads something on the phone for an optional purpose waits for its
purpose. The pattern: keep the SDK off at launch (its manifest switch), then turn it on or off from the choice.

```kotlin
ScruterCMP.whenReady(::applyConsent)
ScruterCMP.onChange(::applyConsent)

fun applyConsent(choice: ConsentChoice) {
    val analytics = choice.isGranted(Purpose.ANALYTICS)
    val ads = choice.isGranted(Purpose.ADVERTISING)
    // one or two lines per SDK, below
}
```

**Firebase Analytics.** In the manifest, off until a choice:

```xml
<meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />
<meta-data android:name="google_analytics_default_allow_analytics_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_storage" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_user_data" android:value="false" />
<meta-data android:name="google_analytics_default_allow_ad_personalization_signals" android:value="false" />
```

```kotlin
Firebase.analytics.setAnalyticsCollectionEnabled(analytics)
Firebase.analytics.setConsent(consentModeForFirebase())   // see Google Consent Mode below
```

**Firebase Crashlytics.** Manifest `firebase_crashlytics_collection_enabled` = `false`, then
`Firebase.crashlytics.setCrashlyticsCollectionEnabled(choice.isGranted(Purpose.ANALYTICS))` (or the purpose your banner
gives crash reports).

**Google Mobile Ads.** `MobileAds.initialize(context)` once a choice exists; without `advertising`, non-personalised ads:

```kotlin
val request = AdRequest.Builder().apply {
    if (!ads) addNetworkExtrasBundle(AdMobAdapter::class.java, Bundle().apply { putString("npa", "1") })
}.build()
```

With the IAB TCF on your banner, Google Mobile Ads reads the TCF's keys itself.

**Meta (Facebook SDK).** In the manifest, `com.facebook.sdk.AutoInitEnabled`, `com.facebook.sdk.AutoLogAppEventsEnabled` and
`com.facebook.sdk.AdvertiserIDCollectionEnabled` set to `false`; then, when `advertising` is granted:

```kotlin
FacebookSdk.setAutoInitEnabled(true)
FacebookSdk.fullyInitialize()
FacebookSdk.setAutoLogAppEventsEnabled(ads)
FacebookSdk.setAdvertiserIDCollectionEnabled(ads)
```

**AppsFlyer.** `AppsFlyerLib.getInstance().init(devKey, null, context)` in `onCreate`, but
`AppsFlyerLib.getInstance().start(context)` only when `advertising` is granted, after `stop(false, context)` when an
earlier refusal stopped it; on a refusal or a withdrawal, `AppsFlyerLib.getInstance().stop(true, context)`.

**Adjust (SDK v5).** `Adjust.initSdk(config)` only once `advertising` is granted; afterwards `Adjust.enable()` or
`Adjust.disable()` from each change.

**OneSignal (SDK v5).** Before `OneSignal.initWithContext(…)`: `OneSignal.consentRequired = true`; then
`OneSignal.consentGiven = choice.isGranted(Purpose.PERSONALIZATION)` (or the purpose your banner gives messaging).

**Sentry.** Manifest `io.sentry.auto-init` = `false`; `SentryAndroid.init(context) { it.dsn = "…" }` once its purpose is
granted, `Sentry.close()` on a withdrawal.

**Braze.** `Braze.enableSdk(context)` or `Braze.disableSdk(context)` from each choice (`personalization`).

**Amplitude (Kotlin SDK).** `amplitude.configuration.optOut = !analytics`.

**Mixpanel.** Create it opted out, `MixpanelAPI.getInstance(context, token, true, false)` (opt-out by default, no
automatic events), then `mixpanel.optInTracking()` or `mixpanel.optOutTracking()` from each choice.

Scruter lists the SDKs your app links (« SDK détectés » in the console) with the purpose each belongs to: the module
reports them once per app version, by the presence of their classes only (`Class.forName(name, false, loader)`, never
initialised; nothing else of your app is read).

## Google Consent Mode

When your banner has Consent Mode on, `consentModeSignals()` gives the visitor's Google signals with the banner's mapping
(otherwise the default one: `ad_*` → `advertising`, `analytics_storage` → `analytics`, `personalization_storage` →
`personalization`), every signal denied until a choice exists and `security_storage` always granted. For Firebase:

```kotlin
fun consentModeForFirebase(): Map<FirebaseAnalytics.ConsentType, FirebaseAnalytics.ConsentStatus> =
    ScruterCMP.consentModeSignals().mapNotNull { (signal, status) ->
        val type = runCatching { FirebaseAnalytics.ConsentType.valueOf(signal.uppercase()) }.getOrNull() ?: return@mapNotNull null
        type to if (status == ConsentStatus.GRANTED) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED
    }.toMap()
```

The proof records the signals sent as granted.

## IAB TCF

When your site's IAB TCF v2.2 settings are on in Scruter CMP (Intégration › IAB TCF: the vendors, the legal basis of
each IAB purpose, the publisher's country — the same page for a site and its app), the module is a TCF CMP (CMP ID 528):

- **The sheet** speaks IAB's text in the message's place (« Nous et nos 10 partenaires stockent… »), with links to the
  partners, the objections to legitimate interest and your privacy policy; each « Personnaliser » step shows the IAB
  purposes grouped under its purpose; a last step lists the partners (with a search) and each partner's declarations;
  the preferences open every IAB purpose and the partners. IAB's texts come in the banner's language from Scruter
  (never from consensu.org).
- **The keys**: the `IABTCF_*` keys of IAB's in-app specification in the default `SharedPreferences`
  (`<package>_preferences`, what `PreferenceManager.getDefaultSharedPreferences` opens), written before the sheet
  closes and kept in step with every change (a decision, the preferences, a withdrawal, a re-ask, `debugReset()`, the
  TCF turned off): `IABTCF_CmpSdkID` (528), `IABTCF_CmpSdkVersion`, `IABTCF_PolicyVersion`, `IABTCF_gdprApplies` (1:
  the same banner for everyone), `IABTCF_PublisherCC`, `IABTCF_PurposeOneTreatment`, `IABTCF_UseNonStandardTexts` (as
  integers), `IABTCF_TCString`, `IABTCF_VendorConsents`, `IABTCF_VendorLegitimateInterests`, `IABTCF_DisclosedVendors`,
  `IABTCF_PurposeConsents`, `IABTCF_PurposeLegitimateInterests`, `IABTCF_SpecialFeaturesOptIns`,
  `IABTCF_PublisherRestrictions{purpose}` and the publisher's keys (as strings). The first five are there as soon as the
  configuration arrives, so vendors know a CMP is present before the choice.
- **Your ad SDKs read the keys themselves**: Google Mobile Ads (AdMob, Ad Manager), AppLovin, ironSource and the other
  TCF vendors need no code. Start them from `whenReady` as usual; the keys are written before `whenReady` and
  `onChange` run.
- **Never Google's UMP SDK beside Scruter CMP**: one CMP per app (IAB's rule), else the two overwrite each other's keys.
  Remove `com.google.android.ump` and its consent form when you install `scruter-cmp`.
- **Google's other ad tech providers** (its Additional Consent list: Google Ad Manager, AdSense and AdMob partners that
  are not registered with the IAB TCF): tick those you work with in the console's IAB settings (« Autres partenaires de
  Google »). The sheet lists them after the TCF's partners, each with its consent switch and privacy policy, and writes
  Google's Additional Consent string v2 in `IABTCF_AddtlConsent` (`2~<consented ids>~dv.<ids only disclosed>`), which
  Google Mobile Ads reads with the TC string. Their consent needs IAB purposes 1, 3 and 4 (storage, profiles and
  personalised ads); adding one asks your visitors again. Without any, the key is not written.
- **Test it**: `ScruterCMP.debug = true` logs « TC string written » (« TC string and Additional Consent string
  written » with Google's providers); read the keys in your debug build
  (`getSharedPreferences(packageName + "_preferences", MODE_PRIVATE).getString("IABTCF_TCString", null)`) and paste the
  string in IAB's decoder (https://iabtcf.com/#/decode); `debugReset()` removes the keys with the choice.
- **Auto Backup**: the default `SharedPreferences` follow your app's backup rules; restored on a new phone, the keys come
  back with the choice.

## Languages

The sheet speaks the first of the phone's languages (Android's per-app language included) that the banner speaks, else
the banner's default language; right to left for Arabic (Android mirrors a layout only in apps that declare
`android:supportsRtl="true"`, the default of a new project). `ScruterCMP.setLanguage("de")` follows your app's own language
switch (`null` gives the choice back to the phone). The texts of a language that is not the banner's default are fetched
once and kept.

## Debug builds

- `ScruterCMP.debug = true` logs the state, the configuration's revision and every decision to Logcat, tag `ScruterCMP`.
- A debuggable build's beacons carry `dbg = 1`: its openings count nowhere, its proofs stay out of the registry, the
  statistics and the webhooks, and show 24 hours in the installation check of the console, which turns green at the
  first launch.
- `ScruterCMP.debugReset()` forgets the choice: the sheet asks again.
- `ScruterCMP.forceShow = true` shows the sheet even with a valid choice (screenshots).

## What the module stores and sends

- **Stored on the phone**: the choice in the `SharedPreferences` file `net.scruter.cmp` (its consent id, the date, the
  banner version, the purposes granted, a flag while its proof is not acknowledged; with the TCF its TC string `tcf`),
  the `IABTCF_*` keys in the default `SharedPreferences` with the TCF, and the cached configuration, texts, media, the
  vendor list and the queue of beacons in the app's no-backup directory. Nothing else; no device identifier.
- **Sent to Scruter** (`cdn.scruter.net`, hosted in France): one hit per opening of the app (a cold start, or a return
  after 30 minutes in the background), one proof per decision (the consent id, the choice, the banner version, the
  language, the hash of the texts shown, the app's package and version, the screen's size class), and once per app
  version the keys of the detected SDKs. Never an advertising id, Android id, IMEI, IP address kept, or user agent.
- **Queue**: hits and proofs wait in a small persistent queue for 48 hours; failures retry with an exponential backoff
  (5 s to 10 minutes) honouring `Retry-After`. A proof not acknowledged is sent again at the next launches.
- **Auto Backup**: `net.scruter.cmp.xml` follows your app's backup rules. Restored on a new phone, the visitor keeps their
  choice; exclude it in your `data_extraction_rules` if your app should ask again on each device.

## Google Play data safety

What the module collects, for your app's « Data safety » form (Scruter is your processor; the data is not shared with
third parties and is not used for advertising or analytics):

| Data type | Collected | Shared | Purpose | Required or optional | Processed ephemerally |
|---|---|---|---|---|---|
| Device or other IDs (the random consent id of the app on this phone) | yes | no | Fraud prevention, security, and compliance (proof of consent) | required | no |
| App activity › App interactions (the visitor's choices in the consent sheet) | yes | no | Fraud prevention, security, and compliance (proof of consent) | required | no |

Encrypted in transit: yes (HTTPS). The visitor can ask for deletion through you, with the consent id shown in the
preferences. Approximate location is not collected (the country of a proof is derived from the address at receipt, which
is then discarded). Have your counsel confirm the wording for your app.
