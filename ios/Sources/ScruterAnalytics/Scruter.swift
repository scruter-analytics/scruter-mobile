import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Scruter Analytics for iOS.
///
/// ```swift
/// import ScruterAnalytics
///
/// @main struct AtelierMonaApp: App {
///     init() { Scruter.start(appId: "ATMONA02") }
///     var body: some Scene { WindowGroup { ContentView() } }
/// }
/// ```
///
/// No IDFA, no ATT prompt, no banner: the SDK draws a random identifier each day and forgets it at midnight; the
/// phone keeps only the app's install day (docs/MOBILE.md §2). Every call returns at once; disk and network work
/// happens on the SDK's own queue, never on the main thread. Before `start` every call is a no-op.
public enum Scruter {
    // MARK: Start

    /// Starts Scruter once, at launch (`App.init`, `application(_:didFinishLaunchingWithOptions:)`).
    ///
    /// - Parameters:
    ///   - appId: "App identifier" (`ATMONA02`), from App settings › SDK.
    ///   - debugKey: the debug-build key (`scr_dbg_…`) that makes a debug build a team phone. Used only by a build the
    ///     SDK recognises as a debug build (development-signed or the simulator); keep it under `#if DEBUG`.
    ///   - debug: logs every screen, event and batch to the console (category `Scruter`).
    ///   - testBuild: marks this build as a test build when the platform cannot tell.
    ///   - endpoint: the collection host (default `https://cdn.scruter.net`), for tests.
    ///   - apiEndpoint: the API host (default `https://api.scruter.net`), for tests.
    public static func start(
        appId: String, debugKey: String? = nil, debug: Bool = false, testBuild: Bool = false, endpoint: URL? = nil,
        apiEndpoint: URL? = nil
    ) {
        var options = StartOptions(appId: appId.trimmingCharacters(in: .whitespaces))
        options.debugKey = debugKey
        options.debug = debug
        options.testBuild = testBuild
        if let e = endpoint { options.endpoint = e }
        if let e = apiEndpoint { options.apiEndpoint = e }
        Runtime.shared.start(options)
    }

    // MARK: Screens and events

    /// Counts a screen view. UIKit screens are counted automatically; name SwiftUI screens with `.scruterScreen(_:)`.
    public static func screen(_ name: String) {
        Runtime.shared.explicitScreen(name)
    }

    /// Sends a custom event. Names ≤ 120 characters; ≤ 30 properties (strings, numbers, booleans). Revenue counts only
    /// with its ISO 4217 currency. Never put personal data in names or properties.
    public static func track(
        _ name: String, props: [String: Any]? = nil, revenue: Double? = nil, currency: String? = nil
    ) {
        let copy = props
        Runtime.shared.run { $0.track(name, props: copy, revenue: revenue, currency: currency) }
    }

    // MARK: Forms

    /// Reports an error shown on a form field (`key`: its identifier or content type, as Scruter names it).
    public static func fieldError(_ key: String, kind: ScruterFieldError) {
        Runtime.shared.run { $0.fieldError(key: key, kind: kind) }
    }

    /// Marks a form as sent (`name`: the `scruterForm` name, else the screen's name).
    public static func formSent(_ name: String) {
        Runtime.shared.run { $0.formSent(name) }
    }

    // MARK: Opt-out

    /// The user objects to audience measurement: nothing more is sent, and the queue, the daily identifier and the
    /// install day are deleted. Wire your app's "Audience measurement" setting to it. Kept across launches.
    public static func optOut() {
        Runtime.shared.setOptedOut(true)
    }

    /// The user accepts audience measurement again (starts as a new install, without an install day).
    public static func optIn() {
        Runtime.shared.setOptedOut(false)
    }

    /// Whether the user opted out.
    public static var isOptedOut: Bool { Runtime.shared.flags().optedOut }

    /// Excludes this phone from the statistics (the team's own test phones, "Test devices").
    public static func ignoreThisDevice() {
        Runtime.shared.setIgnored(true)
    }

    /// Measures this phone again.
    public static func stopIgnoringThisDevice() {
        Runtime.shared.setIgnored(false)
    }

    /// Whether this phone is excluded.
    public static var isDeviceIgnored: Bool { Runtime.shared.flags().ignored }

    // MARK: Links and openings

    /// Forward the URLs that open the app (`.onOpenURL`, `application(_:open:options:)`,
    /// `scene(_:openURLContexts:)`). Returns `true` when the URL was Scruter's own (a team-phone QR code): the app
    /// then has nothing to do with it. Other URLs are counted as the session's opening (`link`; `widget` or
    /// `shortcut` when they carry `scruter_open=widget` / `scruter_open=shortcut`) — only their host, path and
    /// `utm_*` values leave the phone.
    @discardableResult
    public static func handle(url: URL) -> Bool {
        let ours = Runtime.shared.appId.map { Links.isTeamScheme(url, appId: $0) } ?? false
        Runtime.shared.run { $0.handle(url: url) }
        return ours
    }

    #if canImport(Darwin)
    /// Forward universal links (`NSUserActivity` of type browsing web).
    @discardableResult
    public static func handle(userActivity: NSUserActivity) -> Bool {
        guard let url = userActivity.webpageURL else { return false }
        return handle(url: url)
    }
    #endif

    /// The app was opened from a notification (the SDK detects it on its own when the app has a
    /// `UNUserNotificationCenter` delegate; call this when it does not).
    public static func openedFromNotification() {
        Runtime.shared.run { $0.opened(Opening(kind: "notification")) }
    }

    /// The app was opened from a home-screen quick action.
    public static func openedFromShortcut() {
        Runtime.shared.run { $0.opened(Opening(kind: "shortcut")) }
    }

    // MARK: Team phones and sending

    /// Whether this phone is one of the team's phones (it takes the screen images of Screen analysis).
    public static var isTeamPhone: Bool { Runtime.shared.flags().teamPhone }

    /// Removes this phone from the team's phones.
    public static func leaveTeamMode() {
        Runtime.shared.run { $0.team.leave() }
    }

    /// Sends what waits now (the SDK sends on its own: every 30 s in the foreground and when the app goes to the
    /// background).
    public static func flush() {
        Runtime.shared.run { $0.flush() }
    }
}

// MARK: - Bridge for the cross-platform SDKs

/// What a cross-platform SDK knows about a view that UIKit does not show (`Scruter._setElementInspector`); nil fields
/// leave the SDK's own rule in place.
@_spi(ScruterBridge)
public final class BridgeElement {
    /// Explicit identifier (`scruterId`).
    public var id: String?
    public var mask = false
    public var ignore = false
    /// `scruterForm`: the fields inside form this form.
    public var form: String?
    /// The item position in a list.
    public var index: Int?
    public var interactive: Bool?
    /// `button`, `link`, `input`, `choice`, `tab`, `cell`, `image`, `media`, `text`, `other`.
    public var kind: String?

    public init() {}
}

/// The API the React Native and Flutter SDKs call through their native modules (not for apps: `@_spi`).
extension Scruter {
    /// Names the cross-platform SDK in front of this one (`react_native/1.0.0`): call before `start`.
    @_spi(ScruterBridge)
    public static func _setBridge(sdk: String, version: String) {
        guard ["react_native", "flutter"].contains(sdk) else { return }
        Runtime.shared.bridge = (sdk, Text.cut(version, max: 30))
    }

    /// For a cross-platform SDK whose toolkit draws its own widgets (Flutter): the native SDK sees one surface, so it
    /// measures nothing on screen and calls `listener` on its own queue when a screen view begins; the wrapper
    /// reports with `_screenEnd` and `_analysedScreen` and uploads its own images (`_teamImage`). Call before `start`.
    @_spi(ScruterBridge)
    public static func _setScreenListener(_ listener: @escaping (ScruterBridgeScreen) -> Void) {
        Runtime.shared.screenListener = listener
    }

    /// A screen view's engagement (`screen_end`, docs/MOBILE.md §3.3).
    @_spi(ScruterBridge)
    public static func _screenEnd(session: String, name: String, engagedMs: Int64, depth: Int) {
        Runtime.shared.run { $0.wrapperScreenEnd(session: session, name: name, engagedMs: engagedMs, depth: depth) }
    }

    /// One analysed state `x` of a screen view (docs/API.md §5.3), as JSON. Dropped outside the sample.
    @_spi(ScruterBridge)
    public static func _analysedScreen(session: String, json: Data) {
        Runtime.shared.run { e in
            if let body = JSON.parse(json) { e.wrapperAnalysed(session: session, body: body) }
        }
    }

    /// Uploads a team phone's screen image (masks already drawn) and its element tree (JSON, docs/API.md §5.3).
    @_spi(ScruterBridge)
    public static func _teamImage(screen: String, jpeg: Data, tree: Data, width: Int, height: Int, scale: Double) {
        Runtime.shared.run { e in
            guard e.team.isActive, let t = JSON.parse(tree) else { return }
            let meta = Team.meta(
                screen: screen, device: e.env.device, width: width, height: height, scale: scale, takenAt: Date())
            e.team.upload(screen: screen, meta: meta, jpeg: jpeg, tree: t)
        }
    }

    /// Reads what the toolkit keeps on its views, for taps, forms and the team phones' tree (docs/MOBILE.md §20). Called
    /// on the main thread for each view of a walk: it has to be quick. Set before `start`.
    #if canImport(UIKit) && !os(watchOS)
    @_spi(ScruterBridge)
    public static func _setElementInspector(_ inspect: @escaping (UIView) -> BridgeElement?) {
        DispatchQueue.main.async { Elements.inspector = inspect }
    }
    #endif

    /// A route of the cross-platform layer. `forward`: a push or a presentation, not a back or a tab: a form left
    /// that way counts as sent (docs/MOBILE.md §3.9).
    @_spi(ScruterBridge)
    public static func _screen(_ name: String, forward: Bool) {
        Runtime.shared.explicitScreen(name, forward: forward)
    }

    /// Receives the debug log's lines as well as the console (`debug: true`): Metro shows them. Set before `start`.
    @_spi(ScruterBridge)
    public static func _setLogSink(_ sink: @escaping (String) -> Void) {
        Runtime.shared.logSink = sink
    }

    /// A JavaScript or Dart error (`kind`: `crash` when it ends the app or the isolate, else `nonfatal`; `src`: `js`
    /// or `dart`). Frames: `[["fn": …, "fl": …, "l": …, "co": …, "ia": 1]]`; `debugIds`: `bun` (the bundle's debug
    /// id) or `bld` (the Dart build id); `images`: `[["n": …, "u": …, "la": …, "ar": …]]`, named by the frames' `i`.
    @_spi(ScruterBridge)
    public static func _reportError(
        kind: String, src: String, type: String, reason: String, frames: [[String: Any]], debugIds: [String: String],
        images: [[String: String]] = []
    ) {
        guard ["crash", "nonfatal"].contains(kind), ["js", "dart"].contains(src) else { return }
        let converted: [JSON] = frames.prefix(CrashReport.maxFrames).map { f in
            var o = Fields()
            for (k, v) in f {
                switch (k, v) {
                case ("fn", let s as String), ("cl", let s as String), ("fl", let s as String):
                    o[k] = .string(Text.cut(s, max: 200))
                case ("a", let s as String):
                    o[k] = .string(s)
                case ("l", let n as Int), ("co", let n as Int), ("ia", let n as Int), ("i", let n as Int):
                    o[k] = .int(Int64(max(0, n)))
                default: break
                }
            }
            return .object(o)
        }
        let convertedImages: [JSON] = images.prefix(100).map { m in
            var o = Fields()
            for (k, v) in m where ["n", "u", "la", "ar"].contains(k) { o[k] = .string(Text.cut(v, max: 200)) }
            return .object(o)
        }
        Runtime.shared.run {
            $0.reportError(
                kind: kind, src: src, type: type, reason: reason, frames: converted, debugIds: debugIds,
                images: convertedImages)
        }
        guard kind == "crash" else { return }
        // The runtime aborts next: the report is on disk first, and the abort is not a second crash.
        #if canImport(UIKit) && !os(watchOS)
        Crashes.muteNativeReports()
        #endif
        Runtime.shared.queue.sync {}
    }
}

/// A screen view that began, for a wrapper that measures its own screens (`Scruter._setScreenListener`).
@_spi(ScruterBridge)
public struct ScruterBridgeScreen {
    public let session: String
    public let name: String
    public let startMs: Int64
    /// The session is in the Advanced analytics sample.
    public let analysed: Bool
    /// This team phone is to take the screen's image, ≤ `maxBytes`, ≤ `maxHeight` points high.
    public let capture: Bool
    public let maxBytes: Int
    public let maxHeight: Int
}

/// The SDK's process-wide runtime: the serial queue, the engine, and the platform layer.
final class Runtime {
    static let shared = Runtime()

    let queue = DispatchQueue(label: "net.scruter.analytics", qos: .utility)
    private let lock = NSLock()
    private var engine: Engine?
    private var started = false
    private var loaded = false
    private(set) var appId: String?
    private var cachedFlags = Flags()

    struct Flags {
        var optedOut = false
        var ignored = false
        var teamPhone = false
    }

    /// The cross-platform SDK in front of this one, when there is one.
    var bridge: (String, String)?
    /// That SDK measures its own screens (`Scruter._setScreenListener`).
    var screenListener: ((ScruterBridgeScreen) -> Void)?
    var logSink: ((String) -> Void)?

    /// Test hook: builds the environment instead of the platform's.
    var makeEnvironment: ((StartOptions) -> Environment)?

    func start(_ options: StartOptions) {
        lock.lock()
        if started {
            lock.unlock()
            if options.debug { print("[Scruter] start called twice: ignored") }
            return
        }
        guard StartOptions.isValidAppId(options.appId) else {
            lock.unlock()
            print("[Scruter] start: \"\(options.appId)\" is not an app id (ATMONA02, App settings › SDK). Nothing is collected.")
            return
        }
        started = true
        appId = options.appId
        lock.unlock()
        #if canImport(UIKit) && !os(watchOS)
        let mainFacts = ApplePlatform.mainThreadFacts()
        #endif
        queue.async { [self] in
            let env: Environment
            if let make = makeEnvironment {
                env = make(options)
            } else {
                #if canImport(UIKit) && !os(watchOS)
                env = ApplePlatform.makeEnvironment(options: options, queue: queue, facts: mainFacts)
                #else
                let store = FileStore(
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent("scruter-\(options.appId)"))
                env = Environment(
                    scheduler: QueueScheduler(queue: queue), http: URLSessionHTTPClient(queue: queue), store: store,
                    secrets: FileSecretStore(store: store), device: DeviceInfo())
                #endif
            }
            env.log.enabled = options.debug
            if let sink = logSink {
                let printing = env.log.sink
                env.log.sink = {
                    printing($0)
                    sink($0)
                }
            }
            if let (name, version) = bridge {
                env.device.sdkName = name
                env.device.sdkVersion = version
            }
            let e = Engine(env: env, options: options)
            e.screenListener = screenListener
            engine = e
            e.team.onChange = { [weak self] active in
                self?.updateFlags { $0.teamPhone = active }
            }
            #if canImport(UIKit) && !os(watchOS)
            ApplePlatform.shared.attach(engine: e, runtime: self)
            #endif
            e.start()
            lock.lock()
            loaded = true
            lock.unlock()
            updateFlags {
                $0.optedOut = e.isOptedOut
                $0.ignored = e.isIgnored
                $0.teamPhone = e.team.isActive
            }
        }
    }

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// Runs `block` on the engine's queue once started; a no-op before `start`.
    func run(_ block: @escaping (Engine) -> Void) {
        lock.lock()
        let ok = started
        lock.unlock()
        guard ok else { return }
        queue.async { [self] in
            if let e = engine { block(e) }
        }
    }

    func explicitScreen(_ name: String, forward: Bool? = nil) {
        #if canImport(UIKit) && !os(watchOS)
        if screenListener != nil {
            run { $0.screen(name) }
            return
        }
        ApplePlatform.shared.explicitScreen(name, forward: forward)
        #else
        run { $0.screen(name) }
        #endif
    }

    func setOptedOut(_ value: Bool) {
        updateFlags { $0.optedOut = value }
        run { value ? $0.optOut() : $0.optIn() }
    }

    func setIgnored(_ value: Bool) {
        updateFlags { $0.ignored = value }
        run { $0.setIgnored(value) }
    }

    /// The switches, waiting for the engine's first load when it is still under way (a few ms, once).
    func flags() -> Flags {
        lock.lock()
        let wait = started && !loaded
        lock.unlock()
        if wait { queue.sync {} }
        lock.lock()
        defer { lock.unlock() }
        return cachedFlags
    }

    private func updateFlags(_ change: (inout Flags) -> Void) {
        lock.lock()
        change(&cachedFlags)
        lock.unlock()
    }

    /// Test hook: forgets the started engine.
    func reset() {
        queue.sync {
            engine = nil
        }
        lock.lock()
        started = false
        loaded = false
        appId = nil
        cachedFlags = Flags()
        lock.unlock()
    }

    /// Test hook: runs `block` on the queue and waits.
    func sync<T>(_ block: (Engine?) -> T) -> T {
        queue.sync { block(engine) }
    }
}
