# Scruter Analytics for Android

Audience measurement for Android apps without an advertising id, a device identifier, an ATT-style prompt or a consent
banner: the SDK draws a random identifier each day and forgets it at midnight. It is the Android half of
[scruter-mobile](https://github.com/scruter-analytics/scruter-mobile); the behaviour is specified by Scruter's mobile
contract, and `../protocol` holds the wire schemas and the conformance fixtures.

Android 7 (API 24) and later. Android Views and Jetpack Compose. MIT.

## Install

In the app module's `build.gradle.kts`:

```kotlin
plugins {
    id("net.scruter.symbols") version "1.0.2"
}

scruter {
    appId = "ATMONA02" // the "App identifier" shown in Scruter
}

dependencies {
    implementation("net.scruter:scruter-android:1.0.2")
}
```

In your `Application`:

```kotlin
class AtelierMonaApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Scruter.start(this, appId = "ATMONA02")
    }
}
```

Run the app: the installation check in Scruter turns green by itself. `start` returns at once: nothing touches the disk
or the network on the main thread. A debug build's sessions show in the check and never count in your statistics.

Without the Gradle plugin, set the placeholder yourself: `manifestPlaceholders["scruterAppId"] = "atmona02"` (the app id
in lower case).

### Options of `start`

| Option | Purpose |
|---|---|
| `debugKey` | a debug build becomes a team phone (see below); ignored by a release build |
| `debug` | logs screens, events, batches and server warnings to Logcat, tag `Scruter` |
| `testBuild` | marks a build given to testers (Google Play internal testing has no run-time signal); counted, unless the app's settings exclude it |
| `endpoint`, `apiEndpoint` | for tests |

Google Play internal testing has no run-time signal, so a tester's build says so itself, for example with a build variant:

```kotlin
Scruter.start(this, appId = "ATMONA02", testBuild = BuildConfig.FLAVOR == "internal")
```

## Screens

Automatic, nothing to add: resumed `Activity` and visible `Fragment`, named after their class without its suffix
(`CartFragment` → `Cart`). An activity hosting a fragment counts the fragment. A `DialogFragment` counts only when named.
A return from the background inside a session is not a new view.

```kotlin
@ScruterScreen("Cart")            // names a class (required for an Activity or Fragment obfuscated by R8)
class CartFragment : Fragment()

Scruter.screen("Cart")            // anything else
```

The consumer rules keep fragments' class names, so automatic names work in release builds.

Jetpack Compose:

```kotlin
import net.scruter.compose.*

// the name is the route pattern: product/{id}, never the values
val nav = Scruter.trackNavigation(rememberNavController())

@Composable fun Cart() {
    ScruterScreen("Cart")                         // overrides the route, or names a screen without navigation
}
```

## Events

```kotlin
Scruter.track("Add to cart")
Scruter.track("Add to cart", mapOf("color" to "blue"))
Scruter.track("Order placed", revenue = 49.0, currency = "EUR")   // no currency, no revenue
```

Up to 30 properties; strings, numbers and booleans. Never put personal data in a name or a property.

## Taps, scroll, time per block, forms

Nothing to add: collected for the sessions in the app's Advanced analytics sample, always aggregated, never a value, never a
session recording. To give elements a stable name, use an id:

```xml
<Button android:id="@+id/add_to_cart" … />
```

```kotlin
view.scruterId = "addToCart"             // Views
Modifier.scruterId("addToCart")          // Compose; a stable Modifier.testTag works too
```

Fields are grouped by form with `view.scruterForm = "Delivery"` / `Modifier.scruterForm("Delivery")`, else by a
container whose id ends with `form`, else by the screen. Passwords, one-time codes and payment fields are ignored
entirely, as are fields whose id contains card, cvc, iban, pin, otp, token or secret.

```kotlin
Scruter.formSent("Delivery")                          // when leaving the screen forward does not say it
Scruter.fieldError("postalCode", FieldError.FORMAT)   // when the field's own error is not a TextView / Material error
```

To leave an area out of taps and images: `view.scruterIgnore = true`, `Modifier.scruterIgnore()`.

In a layout, the same with a keyed tag:

```xml
<LinearLayout …>
    <tag android:id="@id/scruter_form" android:value="Delivery" />
    …
</LinearLayout>
```

## Team phones and screen images

Screen images come **only** from your team's phones. A user's screen is never captured.

- **By QR code**: in App settings › Team phones, scan the code with the phone holding your test build, then
  answer the SDK's question. The SDK declares the link by itself.
- **Debug builds**: create a key in App settings › SDK, keep it out of release builds:

```kotlin
Scruter.start(this, appId = "ATMONA02", debugKey = if (BuildConfig.DEBUG) "scr_dbg_…" else null)
```

A release build that ships the key never uses it. Text inputs and web views are always masked in the images, and so is
what you mark; use a test account on these phones:

```kotlin
view.scruterMask = true                  // Java: ScruterViews.setScruterMask(view, true)
Modifier.scruterMask()                   // Compose
```

```xml
<TextView …>
    <tag android:id="@id/scruter_mask" android:value="true" />
</TextView>
```

The mask is an opaque rectangle drawn on the phone before the image is encoded, and drawn again on the server. To capture a
long list, the SDK scrolls it once, then returns to its top.

## Crashes

Uncaught exceptions, plus, on Android 11 and later, native crashes and ANRs from `ApplicationExitInfo`; an ANR watchdog
below Android 11 (foreground only). Other crash reporters keep working: the handler is chained. Reports go out at the next
launch with the last 10 screen and event names, never a property value or a log.

Set `SCRUTER_UPLOAD_TOKEN` (App settings › SDK) in your CI's secrets. After `assemble` and `bundle` of non-debuggable variants
the plugin uploads the R8 mapping and unstripped NDK libraries, skipping what Scruter already has. Without a token it says
so and the build goes on; an upload failure never fails a build unless asked.

```kotlin
scruter {
    appId = "ATMONA02"
    failOnError = true                    // default false
    autoUpload = false                    // run scruterUploadSymbolsRelease yourself
    nativeSymbolDirs.from("third_party/symbols")
}
```

## Openings and install referrer

Icon, notification (FCM intents, or `Scruter.openedFromNotification()`), link, widget and shortcut are read from the
launching intent. For a widget, add `scruter_open=widget` to its intent's URI or as an extra. A `singleTop` activity
forwards `onNewIntent` with `Scruter.handle(intent)`. Links keep their host, path and `utm_*` values only. The Google Play
Install Referrer is read once; click ids are dropped by the server.

## The user's choice

```kotlin
Scruter.optOut()   // nothing is sent any more; the queue, daily id and install day are deleted
Scruter.optIn()    // starts as a new install, without install day
Scruter.isOptedOut

Scruter.ignoreThisDevice()   // for your own test phones; never copied by a backup
```

Wire `optOut` to your app's "Audience measurement" setting.

## What the SDK never does

No GAID (no `AD_ID` permission), Android ID, serial or any device identifier; no identifier beyond the day; no IP address
kept, no GPS, no contacts, no typed text; no user's screen; no session recording; no link between a person's app and site
use. The only permission is `INTERNET`, plus the one the Install Referrer library declares.

## Dependencies

| Dependency | Scope | Why | Licence |
|---|---|---|---|
| `com.android.installreferrer:installreferrer` | runtime | the only supported way to read the Play Install Referrer | Apache-2.0 |
| Compose UI and runtime, Navigation, Fragment, RecyclerView, Material | `compileOnly` | used only when your app has them; never added to it | Apache-2.0 |

The Kotlin standard library is the app's, 1.8.22 at least: the SDK uses nothing newer, so that it never raises an app's
Kotlin (React Native 0.73 compiles with 1.8). `WorkManager`, Room, OkHttp, kotlinx and `androidx.core` are deliberately absent: `JobScheduler`, SQLite,
`HttpURLConnection` and `org.json` come with the platform.

## Budgets

Measured by the CI: `:budget:checkBudgets` (one app built with and without the SDK, R8 on, the difference of the dex
files, Kotlin standard library included) and `scripts/device-check.mjs` (the R8 release build of the sample on emulators
without a GPU, API 24 and 34; no physical phone yet).

| | Budget | Measured |
|---|---|---|
| Size after R8 | ≤ 150 KB | 143.3 KB of dex (an app without Compose) |
| Methods after R8 | ≤ 2 500 | 1 194 |
| `start` on the main thread | ≤ 5 ms, no disk or network | API 34: 0.5 ms (44 ms on the very first launch after an install, code not compiled yet); API 24: 2–4.5 ms |
| A tap on a 2 000-element screen, identity included | ≤ 0.5 ms | **over budget**: 1.1–1.9 ms; about 3 µs per element, so ≈ 0.3 ms on a screen of 100 |

The tap's cost applies only to sessions in the Advanced analytics sample, on a tap, never while scrolling.

Team phones only: ≤ 60 MB while capturing (one RGB 565 image), freed at once. No wake lock, no timer in the background.

## Limits

Taps in dialogs and popups are not collected (they are other windows). A screen drawn by a `SurfaceView` (maps, video) shows
empty in screen images. Android 11 gives no stack for native crashes: they are counted without one.

## Develop

```sh
./gradlew :scruter-android:testDebugUnitTest :sample:testDebugUnitTest :scruter-android:lintDebug
scripts/conformance.sh                      # recorded payloads against ../protocol (Node ≥ 20)
./gradlew :budget:checkBudgets              # the SDK's cost after R8
./gradlew -p scruter-symbols-gradle-plugin test
scripts/gradle-docker.sh <tasks>            # the same, in a pinned Docker image, without an Android toolchain
./gradlew :sample:assembleRelease -Pscruter.selfCheck=http://10.0.2.2:8787
node scripts/device-check.mjs sample/build/outputs/apk/release/sample-release.apk   # on a running emulator
```

## Releasing

A tag `v<version>` of this repository publishes the four SDKs (`.github/workflows/publish.yml`): `net.scruter:scruter-android`
and the plugin go to Maven Central in one signed bundle, and the plugin to the Gradle Plugin Portal.
`SIGNING_KEY` and `SIGNING_PASSWORD` in the environment sign what these tasks write to `build/staging`:

```
./gradlew :scruter-android:publishReleasePublicationToStagingRepository
./gradlew -p scruter-symbols-gradle-plugin publishAllPublicationsToStagingRepository
python3 ../scripts/release.py central-verify build/staging "$(cat ../VERSION)"   # what Maven Central checks, offline
```
