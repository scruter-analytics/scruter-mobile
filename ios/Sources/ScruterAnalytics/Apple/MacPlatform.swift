#if os(macOS)
import AppKit
import Foundation
import os.log

#if canImport(ScruterCrash)
import ScruterCrash
#endif

/// The native macOS layer: sessions follow the app becoming active, resigning and quitting; screens follow the key
/// window's content view controller, `.scruterScreen` and `Scruter.screen`; crashes come from ScruterCrash's handlers
/// and MetricKit. A Mac gets no taps, scrolls, forms, screen images, team-phone prompt or ad attribution: those stay
/// UIKit's. Runs on the main thread and hands plain values to the engine's queue.
final class MacPlatform: NSObject {
    static let shared = MacPlatform()

    private(set) var engine: Engine?
    private var installed = false
    /// Whether the app is the active one, as the hooks last saw it (main thread).
    private var active = false
    let screens = MacScreenTracker()
    /// Test hook: a unit test's process keeps its own signal and exception handlers.
    var installsCrashHandlers = true

    // MARK: Environment

    /// `Application Support/<bundle id>/Scruter/`: a Mac app that is not sandboxed shares Application Support with the
    /// user's other apps.
    static func storeDirectory(support: URL, bundleId: String?, appId: String) -> URL {
        let owner = bundleId.flatMap { $0.isEmpty ? nil : $0 } ?? "net.scruter.analytics." + appId
        return support.appendingPathComponent(owner, isDirectory: true).appendingPathComponent("Scruter", isDirectory: true)
    }

    static func makeEnvironment(options: StartOptions, queue: DispatchQueue) -> Environment {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let store = FileStore(
            directory: storeDirectory(support: support, bundleId: Bundle.main.bundleIdentifier, appId: options.appId))
        let log = Logger()
        let osLog = OSLog(subsystem: "net.scruter.analytics", category: "Scruter")
        log.sink = { os_log("%{public}@", log: osLog, type: .default, $0) }
        var device = MacDevice.info(testBuild: options.testBuild)
        device.containerCreatedMs = MacDevice.containerCreated()
        return Environment(
            scheduler: QueueScheduler(queue: queue), http: URLSessionHTTPClient(queue: queue), store: store,
            secrets: MacKeychainSecretStore(
                service: "net.scruter.analytics." + options.appId, fallback: FileSecretStore(store: store)),
            log: log, device: device)
    }

    // MARK: Attach (engine queue)

    /// Wires the engine (called on its queue, before `engine.start()`), then installs the hooks on the main thread.
    func attach(engine: Engine, runtime: Runtime) {
        self.engine = engine
        engine.onCrashContext = { json in
            let bytes = Array(json.encoded())
            bytes.withUnsafeBufferPointer { b in
                b.baseAddress?.withMemoryRebound(to: CChar.self, capacity: b.count) {
                    scruter_crash_set_context($0, b.count)
                }
            }
        }
        Crashes.collectPending(engine: engine)
        let crashPath = Crashes.reportPath(engine.env.store)
        DispatchQueue.main.async { self.installHooks(crashPath: crashPath) }
    }

    /// Runs on the engine's queue (through the runtime: a SwiftUI screen can appear before the engine exists).
    func run(_ block: @escaping (Engine) -> Void) {
        Runtime.shared.run(block)
    }

    // MARK: Hooks (main thread)

    private func installHooks(crashPath: String) {
        guard !installed else { return }
        installed = true
        if installsCrashHandlers {
            Crashes.install(path: crashPath)
            MetricKitSubscriber.install()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        // An app without NSApplication (a command-line tool) has no lifecycle: its explicit screens open its sessions.
        if let app = NSApp, app.isActive {
            didBecomeActive()
        }
    }

    @objc func didBecomeActive() {
        active = true
        run { $0.enterForeground() }
        screens.keyWindowChanged(NSApp?.keyWindow)
    }

    /// The app is no longer the one in front: the session pauses and everything waiting is sent.
    @objc func didResignActive() {
        active = false
        run { $0.enterBackground() }
    }

    /// The app quits: what waits is sent before the process ends (2 s at most on the main thread, once). An app that
    /// quits from the background (the Dock's Quit) paused its session when it resigned: the 30 minutes of a session's
    /// resumption count from then, as on iOS, so the quit only sends.
    @objc func willTerminate() {
        let wasActive = active
        active = false
        let done = DispatchSemaphore(value: 0)
        run { engine in
            if wasActive {
                engine.enterBackground { done.signal() }
            } else {
                engine.flush { done.signal() }
            }
        }
        _ = done.wait(timeout: .now() + 2)
    }

    @objc func windowDidBecomeKey(_ note: Notification) {
        screens.keyWindowChanged(note.object as? NSWindow)
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
}

/// A team device's token in the Keychain, as on iOS: the data protection keychain, this Mac only, after the first
/// unlock. A build that may not use it (unsigned or without a team: `errSecMissingEntitlement`) keeps the token in the
/// SDK's own directory instead; the login keychain is never used, it would ask the user for access after each rebuild.
final class MacKeychainSecretStore: SecretStore {
    let service: String
    private let fallback: SecretStore
    private var refused = false

    init(service: String, fallback: SecretStore) {
        self.service = service
        self.fallback = fallback
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func get(_ key: String) -> String? {
        if refused { return fallback.get(key) }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecMissingEntitlement {
            refused = true
            return fallback.get(key)
        }
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func set(_ key: String, _ value: String?) {
        if refused { return fallback.set(key, value) }
        let deleted = SecItemDelete(query(key) as CFDictionary)
        if deleted == errSecMissingEntitlement {
            refused = true
            return fallback.set(key, value)
        }
        guard let v = value else { return }
        var q = query(key)
        q[kSecValueData as String] = Text.utf8(v)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(q as CFDictionary, nil) == errSecMissingEntitlement {
            refused = true
            fallback.set(key, value)
        }
    }
}
#endif
