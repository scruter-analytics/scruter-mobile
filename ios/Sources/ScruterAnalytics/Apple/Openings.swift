#if canImport(UIKit) && !os(watchOS)
import Foundation
import ObjectiveC
import UIKit
import UserNotifications

#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// How the app was opened (docs/MOBILE.md §3.13): links come through `Scruter.handle(url:)`; notifications are
/// observed on the app's own `UNUserNotificationCenter` delegate without replacing it; launch options tell a cold
/// start from a notification or a quick action.
enum Openings {
    private static var hooked: [UnsafeRawPointer] = []

    static func launched(options: [AnyHashable: Any]?) {
        guard let o = options else { return }
        if o[UIApplication.LaunchOptionsKey.remoteNotification] != nil {
            Scruter.openedFromNotification()
        } else if o[UIApplication.LaunchOptionsKey.shortcutItem] != nil {
            Scruter.openedFromShortcut()
        } else if let url = o[UIApplication.LaunchOptionsKey.url] as? URL {
            Scruter.handle(url: url)
        }
    }

    /// Wraps the delegate's `userNotificationCenter(_:didReceive:withCompletionHandler:)`: the original runs as
    /// before, after the SDK noted the opening.
    static func hookNotificationDelegate() {
        guard let delegate = UNUserNotificationCenter.current().delegate else { return }
        let cls: AnyClass = type(of: delegate)
        let sel = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let key = UnsafeRawPointer(method)
        guard !hooked.contains(key) else { return }
        hooked.append(key)
        typealias Original = @convention(c) (
            AnyObject, Selector, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void
        ) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (
            AnyObject, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void
        ) -> Void = { object, center, response, done in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                Scruter.openedFromNotification()
            }
            original(object, sel, center, response, done)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// SKAdNetwork / AdAttributionKit (docs/MOBILE.md §3.13): the app declares Scruter as the copy endpoint of Apple's
/// postbacks in its Info.plist; the SDK only starts the conversion window once, at the first launch (fine value 0).
/// Never the IDFA, never an ATT prompt.
enum Attribution {
    static func firstLaunch(engine: Engine) {
        guard engine.collecting, !engine.prefs.skanDone, engine.env.device.buildKind == "release" else { return }
        engine.markSkanDone()
        DispatchQueue.main.async { update() }
    }

    static func update() {
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            Task.detached {
                try? await Postback.updateConversionValue(0, coarseConversionValue: .low, lockPostback: false)
            }
            return
        }
        #endif
        #if canImport(StoreKit)
        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { _ in }
        } else if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { _ in }
        } else {
            SKAdNetwork.updateConversionValue(0)
        }
        #endif
    }
}
#endif
