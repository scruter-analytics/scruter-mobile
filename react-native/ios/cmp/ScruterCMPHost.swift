import Foundation
import UIKit

/// The Swift half of the CMP's native module, on the iOS module's bridge entry points (Bridge.swift, compiled in this
/// pod). The choice, the proofs and the queue stay in the module: this only forwards.
@objc(ScruterCMPHost)
public final class ScruterCMPHost: NSObject {
    /// Once per process; a JavaScript reload replaces the listener and starts nothing again. Called on the JS thread:
    /// the module starts on the main thread, which its start needs, and answers from the stored choice meanwhile.
    @objc public static func start(_ options: NSDictionary, listener: @escaping (NSDictionary, Bool) -> Void) -> Bool {
        ScruterCMP._bridgeListen { snapshot, fresh in listener(snapshot as NSDictionary, fresh) }
        guard let appId = options["appId"] as? String else { return false }
        let fresh = !ScruterCMP._bridgeStarted
        DispatchQueue.main.async {
            let started = ScruterCMP._bridgeStart(
                appId: appId, manual: options["manual"] as? Bool ?? false, endpoint: options["endpoint"] as? String,
                sdk: "react_native", version: options["version"] as? String ?? "1.2.0",
                forceShow: options["forceShow"] as? Bool ?? false, debug: options["debug"] as? Bool ?? false)
            if let language = options["language"] as? String { ScruterCMP.setLanguage(language) }
            if !started { listener(ScruterCMP._bridgeSnapshot() as NSDictionary, false) }
        }
        return fresh
    }

    @objc public static var snapshot: NSDictionary { ScruterCMP._bridgeSnapshot() as NSDictionary }

    @objc public static func showPreferences() { ScruterCMP.showPreferences() }

    @objc public static func showIfNeeded() -> Bool {
        let needed = ScruterCMP.state == .needsDecision
        ScruterCMP.showIfNeeded()
        return needed
    }

    @objc public static func requestTrackingIfGranted(_ completion: @escaping (String) -> Void) {
        ScruterCMP.requestTrackingIfGranted { status in
            switch status {
            case .notDetermined: completion("notDetermined")
            case .restricted: completion("restricted")
            case .denied: completion("denied")
            case .authorized: completion("authorized")
            }
        }
    }

    @objc public static func setLanguage(_ language: String?) { ScruterCMP.setLanguage(language) }
    @objc public static func setDebug(_ on: Bool) { ScruterCMP.debug = on }
    @objc public static func setForceShow(_ on: Bool) { ScruterCMP.forceShow = on }
    @objc public static func debugReset() { ScruterCMP.debugReset() }
}
