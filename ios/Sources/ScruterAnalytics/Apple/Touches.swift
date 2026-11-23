#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// A gesture recognizer that only watches: it never recognizes, never cancels, never delays a touch, and lets every
/// other recognizer work (docs/MOBILE.md §3.6). It sees taps on UIKit and SwiftUI alike.
final class ScruterTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var start: CGPoint?
    private var startTime: TimeInterval = 0
    private var moved = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touches.count == 1, let t = touches.first, start == nil else {
            moved = true
            return
        }
        start = t.location(in: nil)
        startTime = t.timestamp
        moved = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let s = start, let p = touches.first?.location(in: nil), hypot(p.x - s.x, p.y - s.y) > 12 { moved = true }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if let t = touches.first, start != nil, !moved, t.timestamp - startTime < 0.8 {
            ApplePlatform.shared.touches.tapped(at: t.location(in: nil), view: t.view, window: t.window)
        } else {
            ApplePlatform.shared.touches.touchEnded()
        }
        reset()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        ApplePlatform.shared.touches.touchEnded()
        reset()
        state = .failed
    }

    override func reset() {
        super.reset()
        start = nil
        moved = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { true }
}

/// Taps: engagement for every session; in the Advanced analytics sample, the target's identity, its position inside
/// the target, dead taps (1 s without any reaction) and rage taps (docs/MOBILE.md §3.5–§3.6).
final class TouchTracker {
    private var windows = NSHashTable<UIWindow>.weakObjects()

    func installOnVisibleWindows() {
        for scene in UIApplication.shared.connectedScenes {
            for w in (scene as? UIWindowScene)?.windows ?? [] { install(on: w) }
        }
    }

    func install(on window: UIWindow) {
        guard !ApplePlatform.shared.wrapperMeasures, !windows.contains(window) else { return }
        // Only the app's own windows (not the keyboard's or the system's).
        let name = String(describing: type(of: window))
        if name.hasPrefix("UIRemoteKeyboardWindow") || name.hasPrefix("UITextEffectsWindow") { return }
        windows.add(window)
        window.addGestureRecognizer(ScruterTouchRecognizer())
    }

    func touchEnded() {
        ApplePlatform.shared.run { $0.interaction() }
        ApplePlatform.shared.scrolls.findContainerIfNeeded()
    }

    func tapped(at point: CGPoint, view: UIView?, window: UIWindow?) {
        let platform = ApplePlatform.shared
        platform.scrolls.findContainerIfNeeded()
        guard platform.analysed, let hit = view, let window = window else {
            platform.run { $0.interaction() }
            return
        }
        let root = platform.screens.currentController?.viewIfLoaded ?? window
        let screenRoot: UIView = hit.isDescendant(of: root) ? root : window
        guard let identity = TouchTracker.identify(hit: hit, point: point, root: screenRoot) else {
            platform.run { $0.interaction() }
            return
        }
        if identity.kind == .choice, let field = platform.forms.choice(identity.view) {
            platform.run { e in
                e.formFocus(form: field.form, key: field.key)
                e.formChanged(form: field.form, key: field.key)
                e.formBlur(form: field.form, key: field.key)
            }
        }
        let interactive = identity.interactive
        let reactions = platform.reactions
        let fingerprint = interactive == false ? TouchTracker.fingerprint(window) : 0
        weak var weakWindow = window
        platform.run { engine in
            let token = engine.tap(
                selector: identity.selector, index: identity.index, kind: identity.kind.rawValue, x: identity.x,
                y: identity.y, point: (Double(point.x), Double(point.y)), interactive: interactive)
            guard token > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var dead = platform.reactions == reactions
                if dead, let w = weakWindow { dead = TouchTracker.fingerprint(w) == fingerprint }
                platform.run { $0.resolveTap(token, dead: dead) }
            }
        }
    }

    struct Identified {
        var view: UIView
        var selector: String
        var index: Int
        var kind: ElementKind
        var x: Int
        var y: Int
        /// nil: unknown (what SwiftUI draws): never a dead tap.
        var interactive: Bool?
    }

    /// The tap's target and its identity (§3.5), its position inside the target in %.
    static func identify(hit: UIView, point: CGPoint, root: UIView) -> Identified? {
        #if canImport(SwiftUI)
        if let host = SwiftUIElements.hostingView(of: hit) {
            if SwiftUIElements.marker(at: point, in: host, where: { $0.ignore }) != nil { return nil }
            if let m = SwiftUIElements.marker(at: point, in: host, where: { $0.mask || $0.id != nil }) {
                let r = Identity.identify(m, root: root)
                return make(view: m, selector: r.selector, index: r.index, kind: m.marker.mask ? .other : m.marker.kind, point: point, interactive: nil)
            }
            // A UIKit element inside SwiftUI: a text field, a list's cell, a control.
            var a: UIView? = hit
            while let n = a, n !== host {
                if n is UIControl || n is UITextView || n is UITableViewCell || n is UICollectionViewCell { break }
                a = n.superview
            }
            if a === host || a == nil {
                // The rest is drawn without views: the tap is placed in the content it falls on (the image of a team
                // phone holds the same element), its interactivity unknown.
                if let s = ApplePlatform.shared.scrolls.primary, s.window != nil, s.isDescendant(of: host) {
                    let r = Identity.identify(s, root: root)
                    return make(view: s, selector: r.selector, index: r.index, kind: .other, point: point, interactive: nil, frame: TouchTracker.contentFrame(of: s))
                }
                let r = Identity.identify(host, root: root)
                return make(view: host, selector: r.selector, index: r.index, kind: .other, point: point, interactive: nil)
            }
        }
        #endif
        guard let (target, interactive) = Elements.target(hit: hit, root: root) else { return nil }
        let r = Identity.identify(target, root: root)
        return make(view: target, selector: r.selector, index: r.index, kind: Elements.kind(of: target), point: point, interactive: interactive)
    }

    /// The whole content of a scroll view (a team phone's image of it), in window coordinates.
    static func contentFrame(of s: UIScrollView) -> CGRect {
        s.convert(CGRect(x: s.bounds.minX, y: 0, width: s.bounds.width, height: max(s.contentSize.height, 1)), to: nil)
    }

    private static func make(
        view: UIView, selector: String, index: Int, kind: ElementKind, point: CGPoint, interactive: Bool?,
        frame: CGRect? = nil
    ) -> Identified {
        let f = frame ?? view.convert(view.bounds, to: nil)
        let x = f.width > 0 ? Int(((point.x - f.minX) / f.width * 100).rounded()) : 50
        let y = f.height > 0 ? Int(((point.y - f.minY) / f.height * 100).rounded()) : 50
        return Identified(
            view: view, selector: selector.isEmpty ? "View[other]" : selector, index: index, kind: kind,
            x: max(0, min(100, x)), y: max(0, min(100, y)), interactive: interactive)
    }

    /// A cheap fingerprint of the window's view and layer tree: views added, removed or hidden change it (§3.6).
    static func fingerprint(_ window: UIWindow) -> Int {
        var h = Hasher()
        var count = 0
        var stack: [CALayer] = [window.layer]
        while let l = stack.popLast(), count < 5000 {
            count += 1
            h.combine(ObjectIdentifier(l))
            h.combine(l.isHidden)
            if let subs = l.sublayers { stack.append(contentsOf: subs) }
        }
        h.combine(count)
        return h.finalize()
    }
}
#endif
