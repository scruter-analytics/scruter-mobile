import Flutter
import UIKit

// Swift Package Manager: the CMP is a module of its own. CocoaPods: its sources are compiled into this pod (ios/vendor).
#if canImport(ScruterCMP)
@_spi(ScruterBridge) import ScruterCMP
#endif

/// The bridge between `package:scruter_flutter`'s `ScruterCMP` and the iOS module (docs/CMP-MOBILE.md §3.16): the
/// sheet, the choice, the proofs and the queue stay in the module; this forwards, and tells Dart of every new snapshot.
public final class ScruterCMPPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "net.scruter/cmp", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ScruterCMPPlugin(channel: channel), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
            // Once per process; a hot restart replaces the listener and starts nothing again.
            let channel = self.channel
            ScruterCMP._bridgeListen { snapshot, fresh in
                channel.invokeMethod("changed", arguments: ["snapshot": snapshot, "newChoice": fresh])
            }
            if let appId = a["appId"] as? String {
                ScruterCMP._bridgeStart(
                    appId: appId, manual: a["manual"] as? Bool ?? false, endpoint: a["endpoint"] as? String,
                    sdk: "flutter", version: a["version"] as? String ?? "0", forceShow: a["forceShow"] as? Bool ?? false,
                    debug: a["debug"] as? Bool ?? false)
                if let language = a["language"] as? String { ScruterCMP.setLanguage(language) }
            }
            result(ScruterCMP._bridgeSnapshot())
        case "snapshot":
            result(ScruterCMP._bridgeSnapshot())
        case "showPreferences":
            ScruterCMP.showPreferences()
            result(nil)
        case "showIfNeeded":
            let needed = ScruterCMP.state == .needsDecision
            ScruterCMP.showIfNeeded()
            result(needed)
        case "requestTrackingIfGranted":
            ScruterCMP.requestTrackingIfGranted { status in
                switch status {
                case .notDetermined: result("notDetermined")
                case .restricted: result("restricted")
                case .denied: result("denied")
                case .authorized: result("authorized")
                }
            }
        case "setLanguage":
            ScruterCMP.setLanguage(a["language"] as? String)
            result(nil)
        case "setDebug":
            ScruterCMP.debug = a["on"] as? Bool ?? false
            result(nil)
        case "setForceShow":
            ScruterCMP.forceShow = a["on"] as? Bool ?? false
            result(nil)
        case "debugReset":
            ScruterCMP.debugReset()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
