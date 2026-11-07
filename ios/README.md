# Scruter Analytics for iOS

Privacy-first analytics for iOS apps, hosted in France: screens, events, sessions, retention, sources, crashes and
Screen analysis — **without the IDFA, without an App Tracking Transparency prompt, without a consent banner**.

- The SDK draws a **random identifier each day** and forgets it at midnight (the app's time zone). The phone keeps only
  the day the app was installed, shared by everyone who installed it that day: that is what makes "32% come back the next
  day" measurable without following anyone.
- Never read: IDFA, IDFV or any device identifier, the GPS position, contacts, photos, the text people type. Never
  stored by Scruter: the IP address (country and city are derived from it, then it is dropped).
- A user's screen is **never** captured. Screen images come only from your team's phones (§ Team phones).

Requirements: iOS 15+, Xcode 15+, Swift 5.9+. No third-party dependency. MIT licence.

## Install

**Swift Package Manager** — Xcode › File › Add Package Dependencies…, then

```
https://github.com/scruter-analytics/scruter-mobile
```

and add the **ScruterAnalytics** product to your app target. In a `Package.swift`:

```swift
.package(url: "https://github.com/scruter-analytics/scruter-mobile", from: "1.0.2"),
// …
.product(name: "ScruterAnalytics", package: "scruter-mobile"),
```

**CocoaPods** — in the `Podfile`, from this repository (the CocoaPods trunk takes no new pod after December 2, 2026; a
git source needs no trunk):

```ruby
pod 'Scruter', :git => 'https://github.com/scruter-analytics/scruter-mobile', :tag => '1.0.2'
```

## Start: three lines

Your "App identifier" is in Scruter › App settings › SDK (`ATMONA02`).

```swift
import ScruterAnalytics

@main struct AtelierMonaApp: App {
    init() { Scruter.start(appId: "ATMONA02") }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

With UIKit, call it in `application(_:didFinishLaunchingWithOptions:)`. `start` returns at once: disk and network work
happens on the SDK's own queue. Call it once; before it, every call is a no-op.

Options: `debugKey:` (team phones, below), `debug: true` (console logs, below), `testBuild: true` (marks a build as a
test build when iOS cannot tell, e.g. an enterprise build you hand to testers).

Run the app on a simulator or an iPhone: the installation check in Scruter turns green within seconds (debug builds
show there and are never counted in your statistics).

## Screens

**UIKit: automatic.** A screen is counted when a view controller appears on top of the window (`viewDidAppear`), once
per appearance (going back counts again, like a page). The name is the type name without its suffix:
`ProductViewController` → `Product`, `CheckoutPage` → `Checkout`, `CartScreen` → `Cart`. Navigation, tab, page and
split controllers, alerts and Apple's own controllers are never screens. Generic or obfuscated type names give no name:
the debug log says "name this screen". Name a controller yourself:

```swift
override init(nibName: String?, bundle: Bundle?) {
    super.init(nibName: nibName, bundle: bundle)
    scruterScreenName = "Cart"
}
```

Your controller must call `super.viewDidAppear(_:)` (as UIKit asks). For a child of your own container controller,
name the screen with `Scruter.screen("…")` in its `viewDidAppear`.

**SwiftUI: one modifier.** SwiftUI has no controller per screen, so name each screen:

```swift
ProductView(product: p)
    .scruterScreen("Product page")
```

Anywhere else: `Scruter.screen("Cart")`. Names: ≤ 120 characters. Screens listed in App settings › Exclusions are not
sent (wildcards: `Debug*`).

## Events

```swift
Scruter.track("Add to cart")
Scruter.track("Add to cart", props: ["color": "blue"])
Scruter.track("Order placed", revenue: 49.0, currency: "EUR")
```

Names ≤ 120 characters; ≤ 30 properties (strings, numbers, booleans; keys ≤ 300, values ≤ 2 000 characters). Revenue
counts only with its ISO 4217 currency. **Never put personal data in names or properties** (an e-mail address, a name,
an order number): the server masks e-mail addresses and long numbers anyway. Goals are created in Scruter on these
names.

## Links and openings

Forward the URLs that open your app; Scruter counts how the session started (icon, notification, link, widget,
shortcut) and the `utm_*` campaign of a link. Only the link's host, path and `utm_*` values leave the phone.

```swift
WindowGroup { ContentView() }
    .onOpenURL { url in
        if Scruter.handle(url: url) { return }   // Scruter's own (a team phone's QR code)
        // … your routing
    }
```

UIKit: `Scruter.handle(url:)` in `application(_:open:options:)` / `scene(_:openURLContexts:)`, and
`Scruter.handle(userActivity:)` for universal links in `scene(_:continue:)`. A widget's `widgetURL` or a quick action's
URL marked `?scruter_open=widget` / `?scruter_open=shortcut` counts as such. Notifications are detected on your
`UNUserNotificationCenter` delegate without replacing it; without a delegate, call `Scruter.openedFromNotification()`.

## Advanced analytics: taps, scroll, forms

On the sessions of the Advanced analytics sample (every session on Growth and Custom, 10% on Essential), the SDK
also counts, in aggregate: taps per element (and their position inside it), dead taps (nothing happens within a second),
rage taps (three taps within a second at the same place), scroll depth, time per part of the screen, and form fields
(focus, hesitation, changes, errors — never a value nor its length). Nothing is recorded per person; there is no
session recording.

**Element identity.** An element is named by its `accessibilityIdentifier` (UIKit, SwiftUI) or `scruterId`, else by
its type and position. Give the elements that matter a stable name:

```swift
addToCart.scruterId = "add_to_cart"
```

A stable identifier starts with a letter and holds only `A–Z a–z 0–9 _ . : -` (≤ 60 characters, no generated ids).
List and grid items share their list's name and are told apart by their position.

**SwiftUI** draws without UIKit views and describes its elements only to assistive technologies, so the SDK cannot tell
them apart by itself. Taps are still counted and placed on the screen's image by their position, and rage taps work;
to see an element by name in Screen analysis, mark it (the label is the name shown, since SwiftUI's text cannot be
read back). Dead taps are reported on UIKit elements only. Text fields, controls and the cells of a `List` are UIKit
views: they work without anything.

```swift
Button("Add to cart") { … }.scruterId("addToCart", label: "Add to cart")
```

**Forms.** Text fields and choices (switches, segmented controls, sliders, pickers) are fields; a screen's fields are
one form named after the screen, or group them:

```swift
deliveryStack.scruterForm = "Delivery"     // UIKit
Form { … }.scruterForm("Delivery")         // SwiftUI
```

A field's key is its identifier, else its `textContentType` (`postalCode`, `emailAddress`…), else `type:position`.
Passwords, one-time codes and payment fields (secure entry, `password`, `oneTimeCode`, `creditCardNumber`, names with
card, cvc, iban, pin, otp, token, secret) are ignored entirely. Report the errors you show, and when a form is sent:

```swift
Scruter.fieldError("postalCode", kind: .format)   // .required, .format, .refused, .invalid
Scruter.formSent("Delivery")
```

In UIKit, a form is also counted as sent when the user moves forward (a push or a presentation) after changing a field,
with no field showing an error.

**Ignore** a part of the screen entirely (no tap, no field): `view.scruterIgnore = true` / `.scruterIgnore()`.

## Team phones and screen images

Screen analysis draws taps on an image of each screen. Those images come **only from your team's phones**:

- **Added by QR code** (App settings › Team phones): add the URL scheme `scruter-<your app id in lower case>`
  to your app (Info › URL Types, e.g. `scruter-atmona02`) and forward URLs to `Scruter.handle(url:)` as above. Scan the
  code with the phone's camera: your test build (TestFlight) opens and asks; on "Add" the phone joins, with your name.
- **Debug builds**: create a debug key in App settings › SDK and keep it out of release builds:

  ```swift
  #if DEBUG
  Scruter.start(appId: "ATMONA02", debugKey: "scr_dbg_…")
  #else
  Scruter.start(appId: "ATMONA02")
  #endif
  ```

  The key is used only by a development-signed build or the simulator: a release build that ships it by mistake never
  takes an image.

On a team phone, the first time a screen opens in a new version (or when "Take the image again" asks), the SDK waits
until the screen is idle, scrolls through its main list or scroll view to take the whole content (the screen moves for
a second), and uploads one JPEG with the screen's element tree. **Every text field, every web view and every element
marked `scruterMask` is covered with an opaque rectangle on the phone, before the image is encoded** (and again on the
server):

```swift
addressLabel.scruterMask = true      // UIKit
AddressView().scruterMask()          // SwiftUI
```

Use a test account on team phones. Team phones' sessions are never counted. `Scruter.isTeamPhone`,
`Scruter.leaveTeamMode()`.

## Crashes

Crashes are captured automatically: signal and Mach exception handlers and uncaught Objective-C exceptions (a minimal
report written at the crash, sent at the next launch), plus MetricKit's crash and hang (≥ 2 s) diagnostics. Other crash
reporters keep working: the SDK chains to the handlers installed before it and leaves the Mach exception ports to a
reporter that already holds them. A report holds the stacks of the crashed and main threads, the binary images, the
exception type, the screen and the last 10 screen and event names — never a property value, never a log line. Crashes
never count in your quota.

**Readable stacks: upload your dSYMs.** Add a "Run Script" build phase after "Compile Sources" (input file:
`${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}`):

```sh
# Swift Package Manager
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/scruter-mobile/ios/upload-symbols" --app ATMONA02
# CocoaPods
"${PODS_ROOT}/Scruter/ios/upload-symbols" --app ATMONA02
```

It needs the upload token of App settings › SDK in the environment, `SCRUTER_UPLOAD_TOKEN=scr_up_…` (your CI's secrets
or Xcode Cloud's environment, **never in the project**). It skips simulator and Debug builds, asks the server which dSYMs
it is missing, uploads only those, and never fails your build (`--strict` to change that). Set
`DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` for Release. For an App Store build with bitcode-free dSYMs from Xcode's
Organizer, run it by hand: `SCRUTER_UPLOAD_TOKEN=… ios/upload-symbols --app ATMONA02 --force path/to/dSYMs`.

## Installs from campaigns: SKAdNetwork and AdAttributionKit

Apple sends ad networks anonymous "postbacks" for the installs their ads brought; it can send a copy to one address
of your choice. To see installations by network and campaign in Scruter › Sources › Installations, declare Scruter in
your **Info.plist**:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://scruter.net</string>
<key>AdAttributionKit</key>
<dict>
    <key>AttributionCopyEndpoint</key>
    <string>https://scruter.net</string>
</dict>
```

Apple accepts one copy address per app: if another attribution tool already holds it, keep it — the SDK reads
`NSAdvertisingAttributionReportEndpoint` and sends it with the install, so Scruter names that tool and shows App Store
installations without the per-network detail. The SDK starts the conversion window once, at the first launch
(fine value 0); it never reads the IDFA.

## Opt-out

The audience-measurement exemption needs no consent, but users may object. Wire your app's "Audience measurement"
setting to:

```swift
Scruter.optOut()       // nothing more is sent; the queue, the daily identifier and the install day are deleted
Scruter.optIn()        // measured again, as a new install without an install day
Scruter.isOptedOut
```

For your own test phones ("Test devices"): `Scruter.ignoreThisDevice()`, `Scruter.stopIgnoringThisDevice()`.

## Privacy manifest and store declarations

The SDK ships its `PrivacyInfo.xcprivacy`: no tracking, no tracking domain; collected and not linked to the user:
product interaction (analytics), crash data and performance data (app functionality, analytics); required-reason API:
file timestamps (C617.1, to tell a fresh install from an update that adds the SDK). Scruter › App settings ›
Privacy gives the store declarations to copy into App Store Connect and the Play Console.

## Sending, offline and limits

Everything goes to a queue in the app's private storage (excluded from backups) and is sent in batches: when 50 items
wait, 30 s after the oldest one in the foreground, when the app goes to the background, at launch, and 2 s after the
first screen of a debug build or of the first session (the installation check). Bodies over 1 KB are gzipped.
Offline, the queue keeps up to 5 000 items or 5 MB for 48 hours (the oldest dropped first). A failed batch is retried
as is with an exponential backoff from 5 s to 10 minutes, honouring `Retry-After`. `Scruter.flush()` sends now.

Remote configuration: Scruter can switch collection off for an app or a version (nothing kept, nothing sent), change
the Advanced analytics sample, crash reports and team phones; the SDK reads it at launch (cached, 1 hour) and never waits
for it.

## Debug logging

`Scruter.start(appId: "ATMONA02", debug: true)` logs every screen, event and batch to the console (subsystem
`net.scruter.analytics`, category `Scruter`), every limit applied, and the server's warnings in debug builds (names
truncated, properties dropped…). Property values are logged only in debug builds. Leave it off in release builds.

## Budget on the phone

| | Budget | Measured |
|---|---|---|
| Binary size added to an app (arm64, release, stripped) | 400 KB target, CI gate 560 KB | 551 KB with Swift Package Manager (`-O`), 489 KB with CocoaPods (`-Osize`): `ios/scripts/size.sh` |
| `start` on the main thread | ≤ 5 ms | no disk, no network: reads `Bundle.main` and the interface idiom |
| Per screen view / tap on the main thread | ≤ 1 ms | identity of a tap: 0.35–1 ms on 300 views, 4.5–8 ms on a worst-case 2 000 views (CI simulator, sessions of the sample only) |
| Memory | ≤ 2 MB; ≤ 60 MB while a team phone captures | captures are drawn in a bitmap of ≤ 56 MB, freed at once |
| Network | ≤ 1 batch / 30 s in the foreground | ≈ 1–3 KB gzipped per batch |
| Battery | no background timer, no location | no timer at all: engaged time is computed from the interactions |

## Example app and tests

`ios/Example/` holds a small app (SwiftUI and UIKit screens, a list, a form, a masked view) and its tests. Generate
the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `cd ios/Example && xcodegen`, then open
`ScruterExample.xcodeproj`. Core tests: `swift test` (macOS) or `ios/scripts/linux-test.sh` (Linux, Docker). The CI
(`.github/workflows/ios.yml`) runs the core tests, the SDK and the example's tests on an iOS simulator, checks every
payload against `protocol/schema`, runs `pod lib lint`, tests `upload-symbols` and checks the binary size.
