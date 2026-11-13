#if os(macOS)
import AppKit
import Foundation

private var scruterMacScreenNameKey: UInt8 = 0

extension NSViewController {
    /// The screen's name, counted when the controller's window becomes key or it becomes the window's content (else
    /// its type name without `ViewController`).
    public var scruterScreenName: String? {
        get { objc_getAssociatedObject(self, &scruterMacScreenNameKey) as? String }
        set { objc_setAssociatedObject(self, &scruterMacScreenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

/// Automatic AppKit screens (docs/MOBILE.md §3.3): the content view controller of the key window, when the window
/// becomes key or its content changes. Containers, SwiftUI's hosting controllers (named with `.scruterScreen`) and
/// Apple's own controllers (panels, alerts) are not screens; explicit names (`scruterScreenName`, `Scruter.screen`,
/// `.scruterScreen`) always win. Window titles are never used: they often hold a document's or a person's name.
final class MacScreenTracker {
    private weak var window: NSWindow?
    private var contentObservation: NSKeyValueObservation?
    private(set) weak var currentController: NSViewController?
    private(set) var currentName: String?
    /// An explicit screen in this run-loop turn cancels the automatic one waiting.
    private var explicitTurn = 0
    private var turn = 0
    private var namelessLogged: [ObjectIdentifier] = []

    /// The app's key window changed (or the app came back to the front with it).
    func keyWindowChanged(_ w: NSWindow?) {
        // A cross-platform SDK names its own routes.
        guard Runtime.shared.bridge == nil, let w = w else { return }
        if w !== window {
            window = w
            contentObservation = w.observe(\.contentViewController, options: [.new]) { [weak self] win, _ in
                DispatchQueue.main.async { self?.evaluate(win) }
            }
        }
        evaluate(w)
    }

    private func evaluate(_ w: NSWindow) {
        guard w.isKeyWindow || w === NSApp?.keyWindow,
            let vc = MacScreenTracker.screenController(of: w.contentViewController),
            vc !== currentController
        else { return }
        let name: String
        if let explicit = vc.scruterScreenName.flatMap(ScreenName.explicit) {
            name = explicit
        } else {
            guard !MacScreenTracker.isExcluded(vc) else { return }
            guard let auto = ScreenName.fromTypeName(String(describing: type(of: vc))) else {
                let key = ObjectIdentifier(type(of: vc))
                if !namelessLogged.contains(key) {
                    namelessLogged.append(key)
                    let typeName = String(describing: type(of: vc))
                    MacPlatform.shared.run {
                        $0.env.log.log("name this screen (scruterScreenName or Scruter.screen):", typeName)
                    }
                }
                return
            }
            name = auto
        }
        turn += 1
        let myTurn = turn
        let explicitAtSchedule = explicitTurn
        // Wait for the end of this run-loop turn: an explicit `Scruter.screen` called meanwhile takes the place of the
        // automatic name.
        DispatchQueue.main.async {
            guard self.explicitTurn == explicitAtSchedule, myTurn == self.turn else { return }
            self.begin(name: name, controller: vc, forward: false)
        }
    }

    func explicitScreen(_ raw: String, forward: Bool? = nil) {
        guard let name = ScreenName.explicit(raw) else { return }
        explicitTurn += 1
        // The key window's controller belongs to this screen now: it is not counted again until it changes.
        let vc = MacScreenTracker.screenController(of: NSApp?.keyWindow?.contentViewController)
        begin(name: name, controller: vc, forward: forward ?? false)
    }

    private func begin(name: String, controller: NSViewController?, forward: Bool) {
        currentController = controller
        currentName = name
        MacPlatform.shared.run { $0.screen(name, forward: forward) }
    }

    /// The controller that stands for the window's screen: the selected tab of a tab view controller, else the content
    /// controller itself.
    static func screenController(of root: NSViewController?) -> NSViewController? {
        var vc = root
        var depth = 0
        while let tabs = vc as? NSTabViewController, depth < 8 {
            let i = tabs.selectedTabViewItemIndex
            guard i >= 0, i < tabs.tabViewItems.count, let child = tabs.tabViewItems[i].viewController else { break }
            vc = child
            depth += 1
        }
        return vc
    }

    /// Containers, SwiftUI's hosting controllers and the system's own controllers (`NS*`, `_NS*`, panels) are never
    /// screens.
    static func isExcluded(_ vc: NSViewController) -> Bool {
        if vc is NSTabViewController || vc is NSSplitViewController || vc is NSPageController
            || vc is NSTitlebarAccessoryViewController
        {
            return true
        }
        let name = String(describing: type(of: vc))
        if name.contains("HostingController") { return true }
        let bundlePath = Bundle(for: type(of: vc)).bundlePath
        // A class of the system's frameworks (not the app's or its embedded frameworks).
        if bundlePath.hasPrefix("/System/") || bundlePath.hasPrefix("/usr/") { return true }
        return name.hasPrefix("_NS")
    }
}
#endif
