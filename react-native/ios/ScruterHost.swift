import Foundation
import UIKit

/// The Swift half of the native module, on the iOS SDK's own API (same module: `ios/sdk/` is compiled in this pod).
/// React's headers stay in `ScruterModule.mm`.
@objc(ScruterHost)
public final class ScruterHost: NSObject {
    @objc public static func start(_ options: NSDictionary, launchOptions: NSDictionary?, log: ((String) -> Void)?) {
        guard let appId = options["appId"] as? String else { return }
        Scruter._setBridge(sdk: "react_native", version: options["version"] as? String ?? "1.0.0")
        Scruter._setElementInspector(ReactElements.inspect)
        if let log = log { Scruter._setLogSink(log) }
        Scruter.start(
            appId: appId,
            debugKey: options["debugKey"] as? String,
            debug: options["debug"] as? Bool ?? false,
            testBuild: options["testBuild"] as? Bool ?? false,
            endpoint: (options["endpoint"] as? String).flatMap(URL.init(string:)),
            apiEndpoint: (options["apiEndpoint"] as? String).flatMap(URL.init(string:)))
        launched(launchOptions as? [UIApplication.LaunchOptionsKey: Any] ?? [:])
    }

    /// How the app was opened, when that is no link (`Linking.getInitialURL` gives those): the SDK reads it from the
    /// launch notification, which went by before `start`.
    private static func launched(_ launch: [UIApplication.LaunchOptionsKey: Any]) {
        if launch[.remoteNotification] != nil {
            Scruter.openedFromNotification()
        } else if launch[.shortcutItem] != nil {
            Scruter.openedFromShortcut()
        }
    }

    @objc public static func screen(_ name: String, forward: Bool) {
        Scruter._screen(name, forward: forward)
    }

    @objc public static func track(_ name: String, event: NSDictionary) {
        Scruter.track(
            name, props: event["props"] as? [String: Any], revenue: (event["revenue"] as? NSNumber)?.doubleValue,
            currency: event["currency"] as? String)
    }

    @objc public static func fieldError(_ key: String, kind: String) {
        let k: ScruterFieldError
        switch kind {
        case "required": k = .required
        case "format": k = .format
        case "refused": k = .refused
        default: k = .invalid
        }
        Scruter.fieldError(key, kind: k)
    }

    @objc public static func formSent(_ name: String) { Scruter.formSent(name) }
    @objc public static func optOut() { Scruter.optOut() }
    @objc public static func optIn() { Scruter.optIn() }
    @objc public static var isOptedOut: Bool { Scruter.isOptedOut }
    @objc public static func ignoreThisDevice() { Scruter.ignoreThisDevice() }
    @objc public static func stopIgnoringThisDevice() { Scruter.stopIgnoringThisDevice() }
    @objc public static var isDeviceIgnored: Bool { Scruter.isDeviceIgnored }
    @objc public static func openedFromNotification() { Scruter.openedFromNotification() }
    @objc public static var isTeamPhone: Bool { Scruter.isTeamPhone }
    @objc public static func leaveTeamMode() { Scruter.leaveTeamMode() }
    @objc public static func flush() { Scruter.flush() }

    @objc public static func handle(_ url: String) {
        guard let u = URL(string: url) else { return }
        Scruter.handle(url: u)
    }

    @objc public static func reportError(fatal: Bool, type: String, reason: String, frames: NSArray, bundleId: String) {
        Scruter._reportError(
            kind: fatal ? "crash" : "nonfatal", src: "js", type: type, reason: reason,
            frames: frames as? [[String: Any]] ?? [], debugIds: bundleId.isEmpty ? [:] : ["bun": bundleId])
    }

    /// `rn-ios-<version>-<build>`: the same as `defaultBundleId` in the CLI.
    @objc public static var defaultBundleId: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        let id = "rn-ios-\(version)-\(build)".unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(id.prefix(100))
    }
}
