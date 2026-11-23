#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// What the beacons say about the app (§4.2), read once at `start`.
enum CMPPlatform {
    @_optimize(size) static func device() -> CMPDevice {
        var d = CMPDevice()
        let info = Bundle.main.infoDictionary ?? [:]
        d.bundleId = Bundle.main.bundleIdentifier ?? ""
        d.appVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        d.languages = Locale.preferredLanguages
        d.detectDebugBuild = true
        // The screen's shorter side in points (no window needed). `start` runs on the main thread; elsewhere it is
        // read there once.
        let side = { Int(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)) }
        d.shortSide = Thread.isMainThread ? side() : DispatchQueue.main.sync(execute: side)
        return d
    }

    /// A development-signed app (`get-task-allow` in its embedded provisioning profile) or the simulator: the debug
    /// builds whose proofs stay out of the registry (§3.13). A TestFlight or App Store build is a release build.
    @_optimize(size) static func isDebugBuild() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex)
        else { return false }
        let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let ents = dict["Entitlements"] as? [String: Any]
        else { return false }
        return (ents["get-task-allow"] as? Bool) ?? false
        #endif
    }
}
#endif
