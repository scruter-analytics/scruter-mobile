import Foundation

/// What a Mac reports (docs/MOBILE.md §2.2), for a native macOS app and for an iOS app running on a Mac (Mac Catalyst,
/// an iPhone or iPad app on Apple silicon): `platform` is `macos`, `form` is `desktop`, `model` is the Mac's
/// `hw.model` (`Mac14,2`, `MacBookPro18,3`). The rules are pure here; the system reads are below, Darwin only.
enum MacFacts {
    static let platform = "macos"
    static let form = "desktop"

    /// `macos` for a native Mac app and for an iOS app on a Mac, `ios` otherwise.
    static func platform(nativeMac: Bool, catalyst: Bool, iOSAppOnMac: Bool) -> String {
        nativeMac || catalyst || iOSAppOnMac ? platform : "ios"
    }

    /// An iOS app running on a Mac keeps everything the iOS layer read, except the platform, the form and the model.
    static func onMac(_ device: DeviceInfo, model: String) -> DeviceInfo {
        var d = device
        d.platform = platform
        d.form = form
        if !model.isEmpty { d.model = model }
        return d
    }

    /// `major.minor` of a version (`14.5.1` → `14.5`, `15` → `15.0`); empty when it has no number.
    static func majorMinor(_ version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard let major = parts.first, !major.isEmpty, major.allSatisfy({ $0.isNumber }) else { return "" }
        let minor = parts.count > 1 && !parts[1].isEmpty && parts[1].allSatisfy({ $0.isNumber }) ? parts[1] : "0"
        return major + "." + minor
    }

    /// The App Store receipt a Mac app carries: none (Developer ID, direct download, development), a production one
    /// (Mac App Store), or a sandbox one (TestFlight for Mac).
    enum Receipt { case none, production, sandbox }

    /// `build_kind`, `install_source` and whether a debug key may be used, for a native Mac app. A development-signed
    /// app (`get-task-allow`) is a debug build whatever its receipt.
    static func kinds(debugEntitled: Bool, receipt: Receipt, testBuild: Bool) -> (
        buildKind: String, installSource: String, isDebugBuild: Bool
    ) {
        if debugEntitled { return ("debug", "other", true) }
        switch receipt {
        case .sandbox: return ("testflight", "testflight", false)
        case .production: return (testBuild ? "test" : "release", testBuild ? "other" : "mac_app_store", false)
        case .none: return (testBuild ? "test" : "release", "other", false)
        }
    }

    #if canImport(Darwin)
    /// A string of `sysctlbyname` (`hw.model`, `kern.osproductversion`), nil when the system has none.
    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// The Mac's model identifier (`Mac14,2`), also inside a Catalyst or iOS app on the Mac.
    static func model() -> String {
        Text.cut(sysctl("hw.model") ?? "", max: 60)
    }
    #endif
}
