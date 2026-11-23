import Foundation

#if !(canImport(UIKit) && !os(watchOS))
/// The device facts where there is no UIKit (the module's logic builds on Linux and macOS for its tests).
enum CMPPlatform {
    @_optimize(size) static func device() -> CMPDevice {
        var d = CMPDevice()
        d.bundleId = Bundle.main.bundleIdentifier ?? ""
        d.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        d.languages = Locale.preferredLanguages
        return d
    }

    @_optimize(size) static func isDebugBuild() -> Bool { false }
}
#endif
