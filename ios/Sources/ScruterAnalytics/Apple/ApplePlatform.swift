#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import os.log

#if canImport(ScruterCrash)
import ScruterCrash
#endif

/// The iOS layer: the app's lifecycle, automatic screens, taps, scroll, forms, crashes, openings and team phones.
/// Runs on the main thread and hands plain values to the engine's queue; never blocks the main thread on disk or
/// network (docs/MOBILE.md §3.18).
final class ApplePlatform: NSObject {
    static let shared = ApplePlatform()

    private(set) var engine: Engine?
    private(set) var queue: DispatchQueue?
    private var installed = false

    // Main-thread copies of the engine's switches.
    var analysed = false
    var crashesOn = true
    var teamPhone = false

    let screens = ScreenTracker()
    let touches = TouchTracker()
    let scrolls = ScrollTracker()
    let forms = FormTracker()
    let capture = ScreenCapture()
    /// A wrapper measures the screens (Flutter draws its own widgets: UIKit sees one view): no hook on the UI.
    private(set) var wrapperMeasures = false

    /// Incremented by everything that shows the app reacted to a tap: screens, scrolls, keyboard, focus, windows.
    var reactions = 0

    struct MainFacts {
        var form = "phone"
    }

    /// What only the main thread may read, collected in `start` (cheap: no disk).
    static func mainThreadFacts() -> MainFacts {
        var f = MainFacts()
        if Thread.isMainThread {
            f.form = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        }
        return f
    }

    // MARK: Environment

    static func makeEnvironment(options: StartOptions, queue: DispatchQueue, facts: MainFacts) -> Environment {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let store = FileStore(directory: support.appendingPathComponent("Scruter", isDirectory: true))
        let log = Logger()
        let osLog = OSLog(subsystem: "net.scruter.analytics", category: "Scruter")
        log.sink = { os_log("%{public}@", log: osLog, type: .default, $0) }
        var device = Device.info(form: facts.form, testBuild: options.testBuild)
        device.containerCreatedMs = Device.containerCreated()
        let env = Environment(
            scheduler: QueueScheduler(queue: queue), http: URLSessionHTTPClient(queue: queue), store: store,
            secrets: KeychainSecretStore(service: "net.scruter.analytics." + options.appId), log: log, device: device)
        env.confirmTeamPhone = { done in DispatchQueue.main.async { ApplePlatform.askTeamPhone(attempts: 8, done: done) } }
        return env
    }

    /// The native question of a team link. At a cold start the window may not be there yet: a few tries, then no.
    static func askTeamPhone(attempts: Int, done: @escaping (Bool) -> Void) {
        guard var top = keyWindow()?.rootViewController else {
            if attempts <= 0 {
                done(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { askTeamPhone(attempts: attempts - 1, done: done) }
            }
            return
        }
        while let next = top.presentedViewController { top = next }
        let info = Bundle.main.infoDictionary
        let app = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? ""
        let text = TeamPrompt.text(language: Locale.preferredLanguages.first ?? "en", app: app)
        let alert = UIAlertController(title: text.title, message: text.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text.cancel, style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: text.add, style: .default) { _ in done(true) })
        top.present(alert, animated: true)
    }

    // MARK: Attach (engine queue)

    /// Wires the engine (called on its queue, before `engine.start()`), then installs the UI hooks on the main thread.
    func attach(engine: Engine, runtime: Runtime) {
        self.engine = engine
        queue = runtime.queue
        wrapperMeasures = engine.screenListener != nil
        engine.onCrashContext = { json in
            let bytes = Array(json.encoded())
            bytes.withUnsafeBufferPointer { b in
                b.baseAddress?.withMemoryRebound(to: CChar.self, capacity: b.count) {
                    scruter_crash_set_context($0, b.count)
                }
            }
        }
        engine.onCollection = { analysed, crashes in
            DispatchQueue.main.async {
                let changed = ApplePlatform.shared.analysed != analysed
                ApplePlatform.shared.analysed = analysed
                ApplePlatform.shared.crashesOn = crashes
                if changed { ApplePlatform.shared.screens.collectionChanged() }
            }
        }
        engine.onCapture = { screen in
            DispatchQueue.main.async { ApplePlatform.shared.capture.request(screen: screen) }
        }
        let previousChange = engine.team.onChange
        engine.team.onChange = { active in
            previousChange?(active)
            DispatchQueue.main.async { ApplePlatform.shared.teamPhone = active }
        }
        Crashes.collectPending(engine: engine)
        let crashPath = Crashes.reportPath(engine.env.store)
        DispatchQueue.main.async {
            self.teamPhone = engine.team.isActive
            self.installUI(crashPath: crashPath)
        }
        Attribution.firstLaunch(engine: engine)
    }

    /// Runs on the engine's queue.
    func run(_ block: @escaping (Engine) -> Void) {
        // Through the runtime: a SwiftUI screen can appear before the engine exists, its turn comes right after.
        Runtime.shared.run(block)
    }

    // MARK: UI hooks (main thread)

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func installUI(crashPath: String) {
        guard !installed else { return }
        installed = true
        Crashes.install(path: crashPath)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didFinishLaunching(_:)), name: UIApplication.didFinishLaunchingNotification, object: nil)
        nc.addObserver(self, selector: #selector(somethingReacted), name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(somethingReacted), name: UIWindow.didBecomeVisibleNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        if !wrapperMeasures {
            screens.install()
            forms.install()
            touches.installOnVisibleWindows()
        }
        MetricKitSubscriber.install()
        Openings.hookNotificationDelegate()
        if UIApplication.shared.applicationState != .background {
            run { $0.enterForeground() }
        }
        if !wrapperMeasures { screens.reportVisibleScreen() }
    }

    @objc private func didFinishLaunching(_ note: Notification) {
        Openings.launched(options: note.userInfo)
        Openings.hookNotificationDelegate()
        touches.installOnVisibleWindows()
    }

    @objc private func didBecomeActive() {
        run { $0.enterForeground() }
        touches.installOnVisibleWindows()
    }

    @objc private func willEnterForeground() {
        Openings.hookNotificationDelegate()
        run { $0.enterForeground() }
    }

    @objc private func didEnterBackground() {
        scrolls.flush()
        let app = UIApplication.shared
        if backgroundTask == .invalid {
            backgroundTask = app.beginBackgroundTask(withName: "Scruter") { [weak self] in self?.endBackgroundTask() }
        }
        run { engine in
            engine.enterBackground {
                DispatchQueue.main.async { ApplePlatform.shared.endBackgroundTask() }
            }
        }
        // The system gives ≈ 30 s; the send is done long before (a batch is 1–3 KB).
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        reactions += 1
        if let w = note.object as? UIWindow { touches.install(on: w) }
    }

    @objc func somethingReacted() {
        reactions += 1
    }

    // MARK: Explicit screens

    func explicitScreen(_ name: String, forward: Bool? = nil) {
        guard Runtime.shared.isStarted else { return }
        if Thread.isMainThread {
            screens.explicitScreen(name, forward: forward)
        } else {
            DispatchQueue.main.async { self.screens.explicitScreen(name, forward: forward) }
        }
    }

    /// The app's key window (never another process's, never the keyboard's).
    static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, ws.activationState == .foregroundActive else { continue }
            if let w = ws.windows.first(where: { $0.isKeyWindow }) { return w }
        }
        for scene in UIApplication.shared.connectedScenes {
            if let w = (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) { return w }
        }
        return nil
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// The device token of a team phone, in the Keychain: this device only, readable after the first unlock.
final class KeychainSecretStore: SecretStore {
    let service: String
    init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func set(_ key: String, _ value: String?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let v = value else { return }
        var q = query(key)
        q[kSecValueData as String] = Text.utf8(v)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
#endif
