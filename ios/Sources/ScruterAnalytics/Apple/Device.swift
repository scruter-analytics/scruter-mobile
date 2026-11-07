#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// What the SDK reads about the app and the phone model (docs/MOBILE.md §2.2): the model's machine identifier, the
/// system version, the language, the app's version and build, and the kind of build. Never IDFA, IDFV or any device
/// identifier.
enum Device {
    static func info(form: String, testBuild: Bool) -> DeviceInfo {
        var d = DeviceInfo()
        d.platform = "ios"
        let b = Bundle.main
        d.bundleId = b.bundleIdentifier ?? ""
        d.appVersion = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        d.appBuild = (b.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        d.os = "\(v.majorVersion).\(v.minorVersion)"
        d.model = machine()
        d.form = form
        d.language = String((Locale.preferredLanguages.first ?? "").prefix(2)).lowercased()
        if d.language.count != 2 || !d.language.allSatisfy({ $0.isLetter }) { d.language = "" }
        let kind = buildKind()
        d.isDebugBuild = kind == .debug
        switch kind {
        case .debug: d.buildKind = "debug"
        case .testflight: d.buildKind = "testflight"
        case .release: d.buildKind = testBuild ? "test" : "release"
        }
        switch kind {
        case .release: d.installSource = testBuild ? "other" : "app_store"
        case .testflight: d.installSource = "testflight"
        case .debug: d.installSource = "other"
        }
        d.copyEndpoint = b.object(forInfoDictionaryKey: "NSAdvertisingAttributionReportEndpoint") as? String
        return d
    }

    /// Apple's machine identifier (`iPhone16,2`), the simulator's model on the simulator.
    static func machine() -> String {
        #if targetEnvironment(simulator)
        if let m = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return m }
        #endif
        var u = utsname()
        uname(&u)
        let raw = withUnsafeBytes(of: &u.machine) { buf -> String in
            let bytes = buf.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return raw.isEmpty ? "unknown" : raw
    }

    enum BuildKind { case debug, testflight, release }

    /// A development-signed app (`get-task-allow` in its embedded provisioning profile) or the simulator is a debug
    /// build; an App Store sandbox receipt is TestFlight's; anything else is a release build.
    static func buildKind() -> BuildKind {
        #if targetEnvironment(simulator)
        return .debug
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        {
            if profileAllowsDebugging(data) { return .debug }
        }
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return .testflight }
        return .release
        #endif
    }

    /// Reads `get-task-allow` from the plist inside the profile's CMS envelope (no signature check needed: the system
    /// enforces it; a release build has no such entitlement).
    static func profileAllowsDebugging(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex)
        else { return false }
        let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let ents = dict["Entitlements"] as? [String: Any]
        else { return false }
        return (ents["get-task-allow"] as? Bool) ?? false
    }

    /// Creation time of the app's data container (its Library directory): an install older than the SDK's first run
    /// is an update that adds the SDK, not a new install (docs/MOBILE.md §2.1). File timestamp API, reason C617.1.
    static func containerCreated() -> Int64? {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
            let attrs = try? FileManager.default.attributesOfItem(atPath: lib.path),
            let date = attrs[.creationDate] as? Date
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
#endif
