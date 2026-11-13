import XCTest

@testable import ScruterAnalytics

#if os(macOS)
import AppKit
#endif

/// What a Mac reports (docs/MOBILE.md §2.2): a native macOS app and an iOS app running on a Mac send `macos`,
/// `desktop` and the Mac's model.
final class MacFactsTests: XCTestCase {
    func testPlatformOfNativeCatalystAndIPadAppsOnAMac() {
        XCTAssertEqual(MacFacts.platform(nativeMac: true, catalyst: false, iOSAppOnMac: false), "macos")
        XCTAssertEqual(MacFacts.platform(nativeMac: false, catalyst: true, iOSAppOnMac: false), "macos")
        XCTAssertEqual(MacFacts.platform(nativeMac: false, catalyst: false, iOSAppOnMac: true), "macos")
        XCTAssertEqual(MacFacts.platform(nativeMac: false, catalyst: false, iOSAppOnMac: false), "ios")
    }

    func testAnIOSAppOnAMacChangesOnlyItsPlatformFormAndModel() {
        var ipad = DeviceInfo()
        ipad.platform = "ios"
        ipad.form = "tablet"
        ipad.model = "iPad13,1"
        ipad.os = "17.4"
        ipad.bundleId = "maccatalyst.fr.atelier-mona"
        ipad.appVersion = "2.3.0"
        ipad.buildKind = "release"
        ipad.installSource = "app_store"
        ipad.language = "fr"
        let mac = MacFacts.onMac(ipad, model: "Mac14,2")
        XCTAssertEqual(mac.platform, "macos")
        XCTAssertEqual(mac.form, "desktop")
        XCTAssertEqual(mac.model, "Mac14,2")
        XCTAssertEqual(mac.os, "17.4")
        XCTAssertEqual(mac.bundleId, "maccatalyst.fr.atelier-mona")
        XCTAssertEqual(mac.appVersion, "2.3.0")
        XCTAssertEqual(mac.buildKind, "release")
        XCTAssertEqual(mac.installSource, "app_store")
        XCTAssertEqual(mac.language, "fr")
        XCTAssertEqual(mac.sdkName, "ios")
        let dims = mac.sessionDims
        XCTAssertEqual(dims["p"], "macos")
        XCTAssertEqual(dims["f"], "desktop")
        XCTAssertEqual(dims["m"], "Mac14,2")
        XCTAssertEqual(dims["bid"], "maccatalyst.fr.atelier-mona")
        // No model read: the iOS layer's stays.
        XCTAssertEqual(MacFacts.onMac(ipad, model: "").model, "iPad13,1")
    }

    func testMacOSVersionIsMajorDotMinor() {
        XCTAssertEqual(MacFacts.majorMinor("14.5.1"), "14.5")
        XCTAssertEqual(MacFacts.majorMinor("26.0"), "26.0")
        XCTAssertEqual(MacFacts.majorMinor("15"), "15.0")
        XCTAssertEqual(MacFacts.majorMinor(""), "")
        XCTAssertEqual(MacFacts.majorMinor("beta"), "")
    }

    func testBuildKindAndInstallSourceOfAMacApp() {
        func k(_ debug: Bool, _ r: MacFacts.Receipt, _ test: Bool = false) -> [String] {
            let x = MacFacts.kinds(debugEntitled: debug, receipt: r, testBuild: test)
            return [x.buildKind, x.installSource, x.isDebugBuild ? "debug-key" : "-"]
        }
        // Development-signed (Xcode's Debug, get-task-allow): a debug build, whatever the receipt.
        XCTAssertEqual(k(true, .none), ["debug", "other", "debug-key"])
        XCTAssertEqual(k(true, .sandbox), ["debug", "other", "debug-key"])
        // TestFlight for Mac: a sandbox receipt.
        XCTAssertEqual(k(false, .sandbox), ["testflight", "testflight", "-"])
        // The Mac App Store: a production receipt.
        XCTAssertEqual(k(false, .production), ["release", "mac_app_store", "-"])
        XCTAssertEqual(k(false, .production, true), ["test", "other", "-"])
        // Developer ID, a direct download: no receipt.
        XCTAssertEqual(k(false, .none), ["release", "other", "-"])
        XCTAssertEqual(k(false, .none, true), ["test", "other", "-"])
    }
}

#if os(macOS)
/// The native macOS layer on this Mac.
final class MacPlatformTests: XCTestCase {
    private let scheduler = ManualScheduler()
    private var dir: URL?

    private func spin(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Starts the SDK with this Mac's layer, a fake network and the manual clock.
    private func startOnThisMac() -> (FakeHTTP, DeviceInfo) {
        let http = FakeHTTP()
        let scheduler = self.scheduler
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scruter-mac-" + Random.hex(bytes: 6))
        self.dir = dir
        var device = MacDevice.info(testBuild: false)
        device.bundleId = "fr.atelier-mona.mac"
        device.appVersion = "2.3.0"
        device.appBuild = "230"
        device.language = "fr"
        let store = FileStore(directory: dir)
        Runtime.shared.makeEnvironment = { _ in
            Environment(
                now: { scheduler.now }, scheduler: scheduler, http: http, store: store,
                secrets: FileSecretStore(store: store), device: device)
        }
        MacPlatform.shared.installsCrashHandlers = false
        Scruter.start(appId: "ATMONA02")
        _ = Runtime.shared.sync { $0 != nil }
        spin()
        return (http, device)
    }

    override func tearDown() {
        if let dir = dir {
            Runtime.shared.makeEnvironment = nil
            Runtime.shared.reset()
            try? FileManager.default.removeItem(at: dir)
            self.dir = nil
        }
        super.tearDown()
    }

    func testDeviceInfoOfThisMac() throws {
        let d = MacDevice.info(testBuild: false)
        XCTAssertEqual(d.platform, "macos")
        XCTAssertEqual(d.form, "desktop")
        let model = try XCTUnwrap(MacFacts.sysctl("hw.model"))
        XCTAssertEqual(d.model, model)
        XCTAssertNotNil(d.model.range(of: #"^[A-Za-z]+[0-9]+,[0-9]+$"#, options: .regularExpression), d.model)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(d.os, "\(v.majorVersion).\(v.minorVersion)")
        XCTAssertEqual(MacFacts.majorMinor(MacFacts.sysctl("kern.osproductversion") ?? ""), d.os)
        // The test runner has no App Store receipt; it is a debug build only when development-signed.
        XCTAssertEqual(d.installSource, "other")
        XCTAssertEqual(d.isDebugBuild, MacDevice.debugEntitled())
        XCTAssertEqual(d.buildKind, d.isDebugBuild ? "debug" : "release")
        XCTAssertEqual(MacDevice.info(testBuild: true).buildKind, d.isDebugBuild ? "debug" : "test")
        XCTAssertEqual(d.sdkName, "ios")
    }

    func testFilesLiveInApplicationSupportUnderTheBundleId() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        XCTAssertEqual(
            MacPlatform.storeDirectory(support: base, bundleId: "fr.atelier-mona.mac", appId: "ATMONA02").path,
            base.path + "/fr.atelier-mona.mac/Scruter")
        XCTAssertEqual(
            MacPlatform.storeDirectory(support: base, bundleId: nil, appId: "ATMONA02").path,
            base.path + "/net.scruter.analytics.ATMONA02/Scruter")
        XCTAssertEqual(
            MacPlatform.storeDirectory(support: base, bundleId: "", appId: "ATMONA02").path,
            base.path + "/net.scruter.analytics.ATMONA02/Scruter")
    }

    func testTeamTokenRoundTripInTheKeychainOrItsFallback() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scruter-keychain-" + Random.hex(bytes: 6))
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = MacKeychainSecretStore(
            service: "net.scruter.analytics.test." + Random.hex(bytes: 4), fallback: FileSecretStore(store: FileStore(directory: dir)))
        XCTAssertNil(secrets.get("team"))
        secrets.set("team", "tok_9f2c")
        XCTAssertEqual(secrets.get("team"), "tok_9f2c")
        secrets.set("team", nil)
        XCTAssertNil(secrets.get("team"))
    }

    /// The app becomes active (a session), shows a screen and sends an event, resigns (the batch goes), comes back and
    /// quits (what waits goes before the process ends).
    func testSessionsScreensEventsAndFlushFollowTheApp() throws {
        let (http, device) = startOnThisMac()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        Scruter.screen("Mac Home")
        Scruter.track("export", props: ["format": "csv"])
        spin()
        _ = Runtime.shared.sync { _ in true }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        _ = Runtime.shared.sync { _ in true }

        let batch = try XCTUnwrap(http.batches.last, "resigning active sends the batch")
        XCTAssertEqual(batch["sdk"], .string("ios/" + scruterSDKVersion))
        let s = try XCTUnwrap(batch["s"]?.arrayValue?.first)
        XCTAssertEqual(s["p"], "macos")
        XCTAssertEqual(s["f"], "desktop")
        XCTAssertEqual(s["m"], .string(device.model))
        XCTAssertEqual(s["os"], .string(device.os))
        XCTAssertEqual(s["bid"], "fr.atelier-mona.mac")
        let events = batch["e"]?.arrayValue ?? []
        XCTAssertTrue(events.contains { $0["k"] == "screen" && $0["n"] == "Mac Home" }, "\(events)")
        XCTAssertTrue(events.contains { $0["k"] == "event" && $0["n"] == "export" }, "\(events)")

        let sent = http.batches.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        Scruter.track("quit_soon")
        _ = Runtime.shared.sync { _ in true }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertGreaterThan(http.batches.count, sent, "quitting sends what waits")
        let last = try XCTUnwrap(http.batches.last)
        XCTAssertTrue(last["e"]?.arrayValue?.contains { $0["n"] == "quit_soon" } == true)
        XCTAssertEqual(last["s"]?.arrayValue?.first?["id"], s["id"], "back within 30 minutes: the same session")
    }

    /// Quitting from the background (the Dock's Quit) sends what waits at once, and the session stays paused from the
    /// time the app resigned: the 30 minutes of its resumption count from then, as on iOS.
    func testQuitFromTheBackgroundSendsWhatWaitsAndKeepsTheTimeTheAppResigned() throws {
        let (http, _) = startOnThisMac()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        Scruter.screen("Orders")
        spin()
        _ = Runtime.shared.sync { _ in true }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        let resigned = Runtime.shared.sync { $0?.current?.backgroundAt }
        XCTAssertEqual(resigned, scheduler.now)

        scheduler.now += 20 * 60_000
        Scruter.track("late_export")
        _ = Runtime.shared.sync { _ in true }
        let sent = http.batches.count
        let quit = Date()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertLessThan(Date().timeIntervalSince(quit), 1, "the quit waits for the batch, not for its time limit")
        XCTAssertGreaterThan(http.batches.count, sent, "quitting sends what waits")
        XCTAssertTrue(http.batches.last?["e"]?.arrayValue?.contains { $0["n"] == "late_export" } == true)
        XCTAssertEqual(Runtime.shared.sync { $0?.current?.backgroundAt }, resigned, "paused since the app resigned")
    }
}
#endif
