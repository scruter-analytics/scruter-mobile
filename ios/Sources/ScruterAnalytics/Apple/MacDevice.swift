#if os(macOS)
import Foundation
import Security

#if canImport(StoreKit)
import StoreKit
#endif

/// What a native Mac app reports (docs/MOBILE.md §2.2): the Mac's model identifier, the macOS version, the language,
/// the app's version and build, the kind of build and the install source. Never a serial number, a hardware UUID or
/// any other device identifier.
enum MacDevice {
    static func info(testBuild: Bool) -> DeviceInfo {
        var d = DeviceInfo()
        d.platform = MacFacts.platform
        d.form = MacFacts.form
        let b = Bundle.main
        d.bundleId = b.bundleIdentifier ?? ""
        d.appVersion = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        d.appBuild = (b.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        d.os = "\(v.majorVersion).\(v.minorVersion)"
        d.model = MacFacts.model()
        d.language = String((Locale.preferredLanguages.first ?? "").prefix(2)).lowercased()
        if d.language.count != 2 || !d.language.allSatisfy({ $0.isLetter }) { d.language = "" }
        let k = MacFacts.kinds(debugEntitled: debugEntitled(), receipt: receipt(), testBuild: testBuild)
        d.buildKind = k.buildKind
        d.installSource = k.installSource
        d.isDebugBuild = k.isDebugBuild
        return d
    }

    /// `get-task-allow` in the running app's own signature: a development-signed build (Xcode's Debug), never a Mac App
    /// Store, TestFlight or Developer ID build (the hardened runtime refuses it).
    static func debugEntitled() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.get-task-allow" as CFString, nil)
        else { return false }
        return (value as? Bool) ?? false
    }

    /// The App Store receipt of `Contents/_MASReceipt`: none (Developer ID, direct download, development), the Mac App
    /// Store's, or TestFlight's (a sandbox receipt). On macOS 12 a receipt counts as the Mac App Store's.
    static func receipt() -> MacFacts.Receipt {
        guard let url = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: url.path) else {
            return .none
        }
        if url.lastPathComponent == "sandboxReceipt" { return .sandbox }
        #if canImport(StoreKit)
        if #available(macOS 13.0, *), let r = appTransactionReceipt() { return r }
        #endif
        return .production
    }

    #if canImport(StoreKit)
    /// The App Store environment of the app's transaction, read only when a receipt exists (then it is on the Mac: no
    /// sign-in, no network wait); 1.5 s at most, on the SDK's queue.
    @available(macOS 13.0, *)
    static func appTransactionReceipt() -> MacFacts.Receipt? {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: MacFacts.Receipt?
            func set(_ r: MacFacts.Receipt?) {
                lock.lock()
                stored = r
                lock.unlock()
            }
            var value: MacFacts.Receipt? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            defer { done.signal() }
            let transaction: AppTransaction
            switch try? await AppTransaction.shared {
            case .verified(let t)?: transaction = t
            case .unverified(let t, _)?: transaction = t
            case nil: return
            }
            let r: MacFacts.Receipt? =
                transaction.environment == .sandbox ? .sandbox : transaction.environment == .production ? .production : nil
            box.set(r)
        }
        _ = done.wait(timeout: .now() + 1.5)
        return box.value
    }
    #endif

    /// Creation of a sandboxed app's container: an install older than the SDK's first run is an update that adds the
    /// SDK (docs/MOBILE.md §2.1). A non-sandboxed app has no container of its own: unknown. File timestamp API, reason
    /// C617.1.
    static func containerCreated() -> Int64? {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            let attrs = try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory()),
            let date = attrs[.creationDate] as? Date
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
#endif
