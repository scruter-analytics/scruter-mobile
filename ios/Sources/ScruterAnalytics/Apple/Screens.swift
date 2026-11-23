#if canImport(UIKit) && !os(watchOS)
import Foundation
import ObjectiveC
import UIKit

#if canImport(SafariServices)
import SafariServices
#endif

/// Automatic UIKit screens (docs/MOBILE.md §3.3): `viewDidAppear` of the controller on top of the window's
/// presentation stack, containers and Apple's own controllers excluded; explicit names (`scruterScreenName`,
/// `Scruter.screen`, `.scruterScreen`) always win.
final class ScreenTracker {
    private var swizzled = false
    /// The controller of the current screen (weak: a popped controller goes away).
    private(set) weak var currentController: UIViewController?
    private(set) var currentName: String?
    /// An explicit screen in this run-loop turn cancels the automatic one waiting.
    private var explicitTurn = 0
    private var turn = 0
    private var namelessLogged: [ObjectIdentifier] = []

    func install() {
        guard !swizzled else { return }
        swizzled = true
        let cls: AnyClass = UIViewController.self
        let sel = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, Bool) -> Void = { object, animated in
            original(object, sel, animated)
            if let vc = object as? UIViewController { ApplePlatform.shared.screens.didAppear(vc) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// The screen already on display when the SDK started (its `viewDidAppear` came before the hook).
    func reportVisibleScreen() {
        guard currentName == nil, let window = ApplePlatform.keyWindow(), let top = ScreenTracker.top(of: window.rootViewController)
        else { return }
        didAppear(top)
    }

    func didAppear(_ vc: UIViewController) {
        // A cross-platform SDK names its own routes: its controllers are hosts, not screens.
        guard Runtime.shared.bridge == nil else { return }
        guard let window = vc.viewIfLoaded?.window, ScreenTracker.top(of: window.rootViewController) === vc else { return }
        let name: String
        if let explicit = vc.scruterScreenName.flatMap(ScreenName.explicit) {
            name = explicit
        } else {
            guard !ScreenTracker.isExcluded(vc) else { return }
            guard let auto = ScreenName.fromTypeName(String(describing: type(of: vc))) else {
                let key = ObjectIdentifier(type(of: vc))
                if !namelessLogged.contains(key) {
                    namelessLogged.append(key)
                    ApplePlatform.shared.run {
                        $0.env.log.log("name this screen (scruterScreenName or Scruter.screen):", String(describing: type(of: vc)))
                    }
                }
                return
            }
            name = auto
        }
        turn += 1
        let myTurn = turn
        let forward = isForward(from: currentController)
        let explicitAtSchedule = explicitTurn
        // Wait for the end of this run-loop turn: an explicit `Scruter.screen` called in the same `viewDidAppear`
        // takes the place of the automatic name.
        DispatchQueue.main.async {
            guard self.explicitTurn == explicitAtSchedule, myTurn == self.turn else { return }
            self.begin(name: name, controller: vc, forward: forward)
        }
    }

    func explicitScreen(_ raw: String, forward: Bool? = nil) {
        guard let name = ScreenName.explicit(raw) else { return }
        explicitTurn += 1
        let vc = ApplePlatform.keyWindow().flatMap { ScreenTracker.top(of: $0.rootViewController) }
        begin(name: name, controller: vc, forward: forward ?? isForward(from: currentController))
    }

    private func begin(name: String, controller: UIViewController?, forward: Bool) {
        currentController = controller
        currentName = name
        ApplePlatform.shared.reactions += 1
        let viewport = ApplePlatform.keyWindow()?.bounds.size ?? .zero
        ApplePlatform.shared.run { engine in
            engine.screen(name, forward: forward)
            engine.setViewport(width: Int(viewport.width), height: Int(viewport.height))
        }
        ApplePlatform.shared.scrolls.screenStarted(controller: controller)
        ApplePlatform.shared.forms.screenStarted(controller: controller)
    }

    func collectionChanged() {
        ApplePlatform.shared.forms.screenStarted(controller: currentController)
    }

    /// Left forward: the previous screen's controller is still on a navigation stack or presents the new one.
    private func isForward(from previous: UIViewController?) -> Bool {
        guard let p = previous else { return false }
        if p.isBeingDismissed || p.isMovingFromParent { return false }
        if p.presentedViewController != nil { return true }
        if let nav = p.navigationController { return nav.viewControllers.contains(p) && nav.topViewController !== p }
        return false
    }

    /// The controller on top: presented controllers first, then the visible child of the known containers.
    static func top(of root: UIViewController?) -> UIViewController? {
        var vc = root
        var depth = 0
        while let c = vc, depth < 32 {
            depth += 1
            if let p = c.presentedViewController, !p.isBeingDismissed, !(p is UIAlertController) {
                vc = p
                continue
            }
            if let nav = c as? UINavigationController, let v = nav.visibleViewController ?? nav.topViewController {
                vc = v
                continue
            }
            if let tab = c as? UITabBarController, let s = tab.selectedViewController {
                vc = s
                continue
            }
            if let split = c as? UISplitViewController, let last = split.viewControllers.last {
                vc = last
                continue
            }
            if let page = c as? UIPageViewController, let first = page.viewControllers?.first {
                vc = first
                continue
            }
            return c
        }
        return vc
    }

    /// Containers and Apple's own controllers (`UI*`, `_UI*`, `SFSafariViewController`…) are never screens, nor
    /// SwiftUI's hosting controllers (named with `.scruterScreen`).
    static func isExcluded(_ vc: UIViewController) -> Bool {
        if vc is UINavigationController || vc is UITabBarController || vc is UIPageViewController
            || vc is UISplitViewController || vc is UIInputViewController || vc is UIAlertController
        {
            return true
        }
        #if canImport(SafariServices)
        if vc is SFSafariViewController { return true }
        #endif
        let name = String(describing: type(of: vc))
        if name.hasPrefix("UIHostingController") || name.contains("HostingController") { return true }
        let bundlePath = Bundle(for: type(of: vc)).bundlePath
        // A class of the system's frameworks (not the app's or its embedded frameworks).
        if bundlePath.hasPrefix("/System/") || bundlePath.hasPrefix("/usr/") || bundlePath.contains("/RuntimeRoot/") {
            return true
        }
        return name.hasPrefix("_UI")
    }
}
#endif
