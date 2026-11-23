import Foundation

/// Scruter CMP for iOS apps: the consent banner of your Scruter CMP, as a native sheet, and the proofs of every choice.
///
/// ```swift
/// import ScruterCMP
///
/// @main struct AtelierMonaApp: App {
///     init() {
///         ScruterCMP.start(appId: "ATMONA02")
///         ScruterCMP.whenReady { choice in
///             if choice.isGranted(.analytics) { FirebaseApp.configure() }
///         }
///     }
///     var body: some Scene { WindowGroup { ContentView() } }
/// }
/// ```
///
/// `start` reads the stored choice at once (one storage read): `isGranted` answers from the next line, `false` for
/// every optional purpose until a choice exists. The configuration, the network and the disk are on the module's own
/// queue, never on the main thread. Before `start`, every call is a no-op that grants nothing.
public enum ScruterCMP {
    // MARK: Types

    /// Where the CMP stands (docs/CMP-MOBILE.md §3.1).
    public enum State: String, Equatable {
        /// A valid stored choice for the current configuration.
        case ready
        /// The sheet must show: no choice yet, or the banner asks again.
        case needsDecision
        /// No configuration could be fetched and none is cached, or the CMP is off for this app: every optional
        /// purpose stays denied; the module tries again at the next foreground and when the network returns.
        case unavailable
    }

    /// When the sheet shows.
    public enum Presentation: Equatable {
        /// Over the top view controller, once the app's first frame is drawn (the default).
        case automatic
        /// Where the app calls `showIfNeeded(from:)` (after an onboarding; never after a paywall or a sign-in wall).
        case manual
    }

    /// A purpose of your banner, by its key.
    public struct Purpose: RawRepresentable, Hashable, ExpressibleByStringLiteral {
        public let rawValue: String
        @_optimize(size) public init(rawValue: String) { self.rawValue = rawValue }
        @_optimize(size) public init(stringLiteral value: String) { rawValue = value }

        public static let necessary = Purpose(rawValue: "necessary")
        public static let analytics = Purpose(rawValue: "analytics")
        public static let advertising = Purpose(rawValue: "advertising")
        public static let personalization = Purpose(rawValue: "personalization")
        public static let embeddedContent = Purpose(rawValue: "embedded_content")
        public static let socialMedia = Purpose(rawValue: "social_media")
        public static let functional = Purpose(rawValue: "functional")
    }

    /// A visitor's choice.
    public struct Choice: Equatable {
        /// The receipt the visitor can give you to find their proofs (`cns_…`).
        public let consentId: String
        public let decidedAt: Date
        /// The optional purposes granted.
        public let granted: Set<String>
        /// The optional purposes refused.
        public let denied: Set<String>

        @_optimize(size) public init(consentId: String, decidedAt: Date, granted: Set<String>, denied: Set<String>) {
            self.consentId = consentId
            self.decidedAt = decidedAt
            self.granted = granted
            self.denied = denied
        }

        @_optimize(size) public func isGranted(_ purpose: Purpose) -> Bool { purpose == .necessary || granted.contains(purpose.rawValue) }
        @_optimize(size) public func isGranted(custom key: String) -> Bool { granted.contains(key) }
    }

    /// Google Consent Mode v2 signals (§3.7), named as Firebase names them (`ConsentType(rawValue:)`).
    public enum ConsentModeSignal: String, CaseIterable, Hashable {
        case adStorage = "ad_storage"
        case adUserData = "ad_user_data"
        case adPersonalization = "ad_personalization"
        case analyticsStorage = "analytics_storage"
        case functionalityStorage = "functionality_storage"
        case personalizationStorage = "personalization_storage"
        case securityStorage = "security_storage"
    }

    public enum ConsentModeStatus: String, Equatable {
        case granted
        case denied
    }

    /// Stops an `onChange` observer.
    public final class Subscription {
        private let id: Int
        @_optimize(size) init(id: Int) { self.id = id }
        @_optimize(size) public func cancel() {
            let i = id
            CMPRuntime.shared.run { $0.removeObserver(i) }
        }
    }

    // MARK: Start

    /// Starts the CMP once, at launch (`App.init`, `application(_:didFinishLaunchingWithOptions:)`).
    ///
    /// - Parameters:
    ///   - appId: the app's code in Scruter CMP (`ATMONA02`).
    ///   - presentation: `.automatic` (default) or `.manual` with `showIfNeeded(from:)`.
    ///   - endpoint: where the configuration is served (default `https://cdn.scruter.net`), for tests.
    @_optimize(size) public static func start(appId: String, presentation: Presentation = .automatic, endpoint: URL? = nil) {
        CMPRuntime.shared.start(
            appId: appId.trimmingCharacters(in: .whitespaces).uppercased(), automatic: presentation == .automatic,
            base: endpoint ?? URL(string: "https://cdn.scruter.net")!)
    }

    // MARK: Answers

    /// Whether `purpose` is granted now: synchronous, `false` for every optional purpose until a choice exists.
    @_optimize(size) public static func isGranted(_ purpose: Purpose) -> Bool {
        CMPRuntime.shared.engine?.isGranted(purpose.rawValue) ?? false
    }

    /// Your own purposes, by key (`crash_reports`).
    @_optimize(size) public static func isGranted(custom key: String) -> Bool {
        CMPRuntime.shared.engine?.isGranted(key) ?? false
    }

    public static var state: State { CMPRuntime.shared.engine?.snapshot.state ?? .unavailable }

    /// The visitor's receipt (`cns_…`), shown in the preferences; `nil` until a choice exists.
    public static var consentId: String? { CMPRuntime.shared.engine?.snapshot.consentId }

    /// Called once a valid choice exists: now, or after the decision (on the main thread). Start the app's optional SDKs
    /// here.
    @_optimize(size) public static func whenReady(_ callback: @escaping (Choice) -> Void) {
        CMPRuntime.shared.whenReady(callback)
    }

    /// Called on every later change: the preferences, a withdrawal, a re-ask (on the main thread). Keep the returned
    /// subscription to stop it.
    @discardableResult
    @_optimize(size) public static func onChange(_ callback: @escaping (Choice) -> Void) -> Subscription {
        CMPRuntime.shared.onChange(callback)
    }

    /// The Google Consent Mode signals of the current choice, every one denied until a choice exists but
    /// `securityStorage`. Pass them to Firebase's `Analytics.setConsent` (CMP.md, Consent Mode).
    @_optimize(size) public static func consentModeSignals() -> [ConsentModeSignal: ConsentModeStatus] {
        let s = CMPRuntime.shared.engine?.snapshot
        let granted: Set<String>? = s.flatMap { $0.consentId == nil ? nil : $0.granted }
        let map = ConsentModeRules.signals(map: s?.gcmMap ?? ConsentModeRules.defaultMap, granted: granted)
        var out = [ConsentModeSignal: ConsentModeStatus]()
        for sig in ConsentModeSignal.allCases { out[sig] = map[sig.rawValue] == true ? .granted : .denied }
        return out
    }

    /// The banner's language (`"de"`), for an app with its own language setting; `nil` follows the device again.
    @_optimize(size) public static func setLanguage(_ language: String?) {
        let l = language?.lowercased()
        CMPRuntime.shared.run { $0.setLanguage(l) }
    }

    // MARK: Debug

    /// Logs the state, the configuration revision and every decision to the console.
    public static var debug: Bool {
        get { CMPRuntime.shared.log.enabled }
        set { CMPRuntime.shared.log.enabled = newValue }
    }

    /// Shows the sheet at every opening, even with a valid choice (screenshots, tests). Set it before `start`.
    public static var forceShow: Bool {
        get { CMPRuntime.shared.forceShow }
        set {
            CMPRuntime.shared.forceShow = newValue
            CMPRuntime.shared.run { $0.forceShow = newValue }
        }
    }

    /// Forgets the choice (debug builds only: a release build withdraws through the preferences, with a proof). The
    /// sheet shows again.
    @_optimize(size) public static func debugReset() {
        CMPRuntime.shared.run { $0.debugReset() }
    }

    // MARK: Bridge for the cross-platform SDKs

    /// The React Native and Flutter wrappers name themselves in `cv` (not for apps: `@_spi`).
    @_spi(ScruterBridge)
    @_optimize(size) public static func _setBridge(sdk: String, version: String) {
        CMPRuntime.shared.bridge = (sdk, version)
    }
}

/// The module's single engine and what is set before `start`.
final class CMPRuntime {
    static let shared = CMPRuntime()

    private let lock = NSLock()
    private var _engine: CMPEngine?
    let log = CMPLog()
    var forceShow = false
    var bridge: (String, String)?
    private var early: [(CMPEngine) -> Void] = []
    let queue = DispatchQueue(label: "net.scruter.cmp", qos: .utility)
    #if canImport(UIKit) && !os(watchOS)
    var host: AppleHost?
    #else
    var host: HeadlessHost?
    #endif

    var engine: CMPEngine? {
        lock.lock()
        defer { lock.unlock() }
        return _engine
    }

    @_optimize(size) func start(appId: String, automatic: Bool, base: URL) {
        lock.lock()
        guard _engine == nil else {
            lock.unlock()
            log.warn("start(appId:) called twice: the second call is ignored")
            return
        }
        lock.unlock()
        var device = CMPPlatform.device()
        if let (n, v) = bridge {
            device.sdkName = n
            device.sdkVersion = v
        }
        let env = CMPEnvironment(
            scheduler: CMPQueueScheduler(queue: queue), http: CMPURLSession(queue: queue), choice: CMPDefaultsChoiceStore(),
            files: CMPFiles.standard(), log: log, device: device, classExists: { NSClassFromString($0) != nil })
        let e = CMPEngine(env: env, options: .init(appId: appId, base: base, automatic: automatic), queue: queue)
        e.forceShow = forceShow
        #if canImport(UIKit) && !os(watchOS)
        let h = AppleHost(engine: e)
        #else
        let h = HeadlessHost()
        #endif
        host = h
        e.host = h
        lock.lock()
        _engine = e
        let pending = early
        early = []
        lock.unlock()
        queue.async {
            for f in pending { f(e) }
            e.start()
        }
        #if canImport(UIKit) && !os(watchOS)
        h.observe()
        #endif
    }

    /// Runs `f` on the engine's queue; before `start`, when it starts.
    @_optimize(size) func run(_ f: @escaping (CMPEngine) -> Void) {
        lock.lock()
        if let e = _engine {
            lock.unlock()
            queue.async { f(e) }
        } else {
            early.append(f)
            lock.unlock()
        }
    }

    @_optimize(size) func whenReady(_ cb: @escaping (ScruterCMP.Choice) -> Void) {
        run { $0.whenReady(cb) }
    }

    private var observerIds = 0

    @_optimize(size) func onChange(_ cb: @escaping (ScruterCMP.Choice) -> Void) -> ScruterCMP.Subscription {
        lock.lock()
        observerIds += 1
        let id = observerIds
        lock.unlock()
        run { $0.addObserver(id: id, cb) }
        return ScruterCMP.Subscription(id: id)
    }
}

/// A host without a screen (Linux, tests of the public API): callbacks on the main queue, nothing to show.
final class HeadlessHost: CMPHost {
    @_optimize(size) func show(_ model: SheetModel, anchor: AnyObject?) {}
    @_optimize(size) func dismiss() {}
    @_optimize(size) func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
    @_optimize(size) func prefetch(_ urls: [String]) {}
}
