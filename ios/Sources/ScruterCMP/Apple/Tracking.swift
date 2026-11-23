#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

extension ScruterCMP {
    /// Apple's App Tracking Transparency status, as `ATTrackingManager.AuthorizationStatus` names it.
    public enum TrackingStatus: Int, Equatable {
        case notDetermined = 0
        case restricted = 1
        case denied = 2
        case authorized = 3
    }

    /// Apple's tracking prompt after the CMP, only for a visitor who granted `advertising` (§3.9, M13): it asks only
    /// when `advertising` is granted, the status is `notDetermined` and no sheet is on screen; otherwise it answers the
    /// current status without asking. The prompt's text is your app's `NSUserTrackingUsageDescription`; without that
    /// key nothing is asked. The module never reads the IDFA. Call it from `whenReady`:
    ///
    /// ```swift
    /// ScruterCMP.whenReady { _ in
    ///     ScruterCMP.requestTrackingIfGranted { status in
    ///         if status == .authorized { /* the ad SDKs may read the IDFA */ }
    ///     }
    /// }
    /// ```
    @_optimize(size) public static func requestTrackingIfGranted(_ completion: ((TrackingStatus) -> Void)? = nil) {
        DispatchQueue.main.async {
            let status = CMPTracking.status()
            guard status == .notDetermined, isGranted(.advertising) else {
                completion?(status)
                return
            }
            guard Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") != nil else {
                CMPRuntime.shared.log.warn("requestTrackingIfGranted: add NSUserTrackingUsageDescription to Info.plist to ask")
                completion?(status)
                return
            }
            // After the sheet has closed, and with the app active (Apple shows nothing otherwise).
            CMPRuntime.shared.host?.whenIdle {
                CMPTracking.request { s in DispatchQueue.main.async { completion?(s) } }
            }
        }
    }

    @available(iOS 15.0, *)
    @_optimize(size) public static func requestTrackingIfGranted() async -> TrackingStatus {
        await withCheckedContinuation { c in requestTrackingIfGranted { c.resume(returning: $0) } }
    }
}

/// `ATTrackingManager` reached at run time: the module links no AppTrackingTransparency, so an app that never asks
/// for tracking carries no reference to it.
enum CMPTracking {
    private static let path = "/System/Library/Frameworks/AppTrackingTransparency.framework/AppTrackingTransparency"
    private typealias Getter = @convention(c) (AnyClass, Selector) -> UInt
    // The completion is kept by ATT until the person answers: an escaping block.
    private typealias Request = @convention(c) (AnyClass, Selector, @escaping @convention(block) (UInt) -> Void) -> Void

    private static var manager: AnyClass? {
        if NSClassFromString("ATTrackingManager") == nil { _ = dlopen(path, RTLD_LAZY) }
        return NSClassFromString("ATTrackingManager")
    }

    @_optimize(size) private static func imp(_ cls: AnyClass, _ sel: Selector) -> IMP? {
        class_getClassMethod(cls, sel).map(method_getImplementation)
    }

    @_optimize(size) static func status() -> ScruterCMP.TrackingStatus {
        let sel = NSSelectorFromString("trackingAuthorizationStatus")
        guard let m = manager, let i = imp(m, sel) else { return .restricted }
        let raw = unsafeBitCast(i, to: Getter.self)(m, sel)
        return ScruterCMP.TrackingStatus(rawValue: Int(raw)) ?? .restricted
    }

    @_optimize(size) static func request(_ done: @escaping (ScruterCMP.TrackingStatus) -> Void) {
        let sel = NSSelectorFromString("requestTrackingAuthorizationWithCompletionHandler:")
        guard let m = manager, let i = imp(m, sel) else { return done(.restricted) }
        let completion: @convention(block) (UInt) -> Void = { raw in
            done(ScruterCMP.TrackingStatus(rawValue: Int(raw)) ?? .restricted)
        }
        unsafeBitCast(i, to: Request.self)(m, sel, completion)
    }
}
#endif
