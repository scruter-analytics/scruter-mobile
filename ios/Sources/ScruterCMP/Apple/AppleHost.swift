#if canImport(UIKit) && !os(watchOS)
import Network
import SafariServices
import SwiftUI
import UIKit

extension ScruterCMP {
    /// The app's settings entry (§2.5): the preferences, where the visitor changes or withdraws their choice. Wire it
    /// to an entry such as « Gérer mes cookies » or « Confidentialité ».
    @_optimize(size) public static func showPreferences(from viewController: UIViewController? = nil) {
        CMPRuntime.shared.run { [weak viewController] in $0.showPreferences(anchor: viewController) }
    }

    /// With `presentation: .manual`: shows the sheet when a decision is needed (after an onboarding; never after a
    /// paywall or a sign-in wall).
    @_optimize(size) public static func showIfNeeded(from viewController: UIViewController? = nil) {
        CMPRuntime.shared.run { [weak viewController] in $0.showIfNeeded(anchor: viewController) }
    }
}

/// The sheet on screen, the app's lifecycle and the network, for the engine (main thread).
final class AppleHost: CMPHost {
    private weak var engine: CMPEngine?
    private var controller: CMPSheetController?
    private var queued: (SheetModel, AnyObject?)?
    private var hidden: [UIView] = []
    private var toast: UIWindow?
    private var monitor: NWPathMonitor?
    private var idle: [() -> Void] = []
    private var active = false

    @_optimize(size) init(engine: CMPEngine) { self.engine = engine }

    @_optimize(size) func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = false
            guard let e = self?.engine else { return }
            e.queue.async { e.didEnterBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let e = self?.engine else { return }
            e.queue.async { e.willEnterForeground() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = true
            // The app's first frame is drawn: what waited for it shows now.
            DispatchQueue.main.async { self?.showQueued() }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = false
        }
        if Thread.isMainThread { active = UIApplication.shared.applicationState == .active }
        let m = NWPathMonitor()
        var wasOnline = true
        m.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            if online && !wasOnline, let e = self?.engine { e.queue.async { e.networkAvailable() } }
            wasOnline = online
        }
        m.start(queue: DispatchQueue(label: "net.scruter.cmp.network", qos: .utility))
        monitor = m
    }

    // MARK: CMPHost (any thread)

    @_optimize(size) func show(_ model: SheetModel, anchor: AnyObject?) {
        DispatchQueue.main.async {
            self.queued = (model, anchor)
            self.showQueued()
        }
    }

    @_optimize(size) func dismiss() {
        DispatchQueue.main.async {
            self.queued = nil
            self.controller?.leave(animated: true) {}
        }
    }

    @_optimize(size) func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    @_optimize(size) func prefetch(_ urls: [String]) { CMPMedia.shared.prefetch(urls) }

    /// Runs `f` once no sheet is on screen and the app is active (ATT, §3.9).
    @_optimize(size) func whenIdle(_ f: @escaping () -> Void) {
        if controller == nil && queued == nil && active { f() } else { idle.append(f) }
    }

    @_optimize(size) private func flushIdle() {
        guard controller == nil, queued == nil, active else { return }
        let list = idle
        idle = []
        for f in list { f() }
    }

    // MARK: Presentation (main thread)

    /// The view controller on top of the app's key window.
    @_optimize(size) static func top(from root: UIViewController?) -> UIViewController? {
        var c = root
        while let p = c?.presentedViewController, !p.isBeingDismissed { c = p }
        return c
    }

    @_optimize(size) static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
        for s in ordered {
            if let w = s.windows.first(where: { $0.isKeyWindow }) ?? s.windows.first(where: { !$0.isHidden && $0.rootViewController != nil }) {
                return w
            }
        }
        return nil
    }

    private var retries = 0

    @_optimize(size) private func showQueued() {
        guard let (model, anchorObj) = queued, controller == nil else { return }
        let anchorVC = (anchorObj as? UIViewController).flatMap { $0.viewIfLoaded?.window != nil ? $0 : nil }
        guard active || anchorVC != nil, let presenter = anchorVC.map({ AppleHost.top(from: $0) ?? $0 })
            ?? AppleHost.top(from: AppleHost.keyWindow()?.rootViewController),
            presenter.viewIfLoaded?.window != nil, !presenter.isBeingPresented, !presenter.isBeingDismissed
        else {
            // No window yet, or a transition running: try again shortly (the first frame, a closing alert).
            if retries < 120 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.showQueued() }
            }
            return
        }
        retries = 0
        queued = nil
        let c = CMPSheetController(model: model)
        c.onDecision = { [weak self, weak c] d in
            guard let self = self, let c = c else { return }
            // Written before the sheet closes (M5).
            if let e = self.engine { e.queue.sync { e.decide(d, model: model) } }
            c.leave(animated: true) { self.closed(saved: true, model: model) }
        }
        c.onClose = { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            if let e = self.engine { e.queue.async { e.sheetDidClose() } }
            c.leave(animated: true) { self.closed(saved: false, model: model) }
        }
        c.onAppear = { [weak self] in
            guard let e = self?.engine else { return }
            e.queue.async { e.sheetDidAppear(model.kind) }
        }
        c.openURL = { [weak c] url in
            guard let c = c else { return }
            let safari = SFSafariViewController(url: url)
            safari.modalPresentationStyle = .pageSheet
            c.present(safari, animated: true)
        }
        controller = c
        // The app behind is out of reach of VoiceOver while the sheet shows (§3.12).
        var chain: [UIView] = []
        var vc = presenter.view.window?.rootViewController
        while let v = vc {
            if let view = v.viewIfLoaded { chain.append(view) }
            if v === presenter { break }
            vc = v.presentedViewController
        }
        hidden = chain.filter { !$0.accessibilityElementsHidden }
        for v in hidden { v.accessibilityElementsHidden = true }
        presenter.present(c, animated: false)
    }

    @_optimize(size) private func closed(saved: Bool, model: SheetModel) {
        controller = nil
        for v in hidden { v.accessibilityElementsHidden = false }
        hidden = []
        if saved { showToast(model) }
        if queued != nil { showQueued() }
        flushIdle()
    }

    // MARK: The confirmation (board M1, 3)

    /// « Vos choix ont été enregistrés » for 4 seconds, where to change them under it; the app stays usable.
    @_optimize(size) private func showToast(_ model: SheetModel) {
        UIAccessibility.post(notification: .announcement, argument: model.words.saved + " " + model.words.savedHint)
        guard let scene = AppleHost.keyWindow()?.windowScene else { return }
        let w = CMPPassThroughWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: CMPToast(model: model))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        toast = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak w] in
            guard let w = w else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, animations: { w.alpha = 0 }) { _ in
                w.isHidden = true
                if self?.toast === w { self?.toast = nil }
            }
        }
    }
}

/// A window that lets every touch through to the app.
final class CMPPassThroughWindow: UIWindow {
    @_optimize(size) override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
