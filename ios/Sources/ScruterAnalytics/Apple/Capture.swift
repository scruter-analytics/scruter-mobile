#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// The screen image of a team phone (docs/MOBILE.md §3.11–§3.12): taken only on the team's own phones (a debug build
/// with the debug key, or a phone added by QR code), never on a user's. Once the screen is idle, the full content of
/// its primary scroll container is drawn strip by strip (≤ 10 000 points, ≤ 2 ×), text inputs, web views and
/// `scruterMask` elements are filled with an opaque rectangle before the JPEG is encoded, and the element tree goes
/// with it (selectors and indexes of §3.5, frames in the image's pixels, labels except on masked elements).
final class ScreenCapture {
    private var pending: String?
    private var busy = false
    /// Memory ceiling of one capture (§3.18: ≤ 60 MB while capturing, freed at once).
    static let maxBitmapBytes: CGFloat = 56 * 1024 * 1024
    static let maxNodes = 2000

    func request(screen: String) {
        let p = ApplePlatform.shared
        guard p.teamPhone, !busy, p.screens.currentName == screen else { return }
        pending = screen
        attempt(screen: screen, tries: 0, after: 1.0)
    }

    private func attempt(screen: String, tries: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.pending == screen, !self.busy else { return }
            let p = ApplePlatform.shared
            guard p.screens.currentName == screen, UIApplication.shared.applicationState == .active,
                let window = ApplePlatform.keyWindow()
            else {
                self.pending = nil
                return
            }
            guard ScreenCapture.isIdle(window) else {
                if tries < 12 { self.attempt(screen: screen, tries: tries + 1, after: 0.5) } else { self.pending = nil }
                return
            }
            self.pending = nil
            self.busy = true
            ApplePlatform.shared.run { engine in
                let maxBytes = engine.team.maxBytes
                let maxHeight = engine.team.maxHeight
                DispatchQueue.main.async {
                    let shot = autoreleasepool { ScreenCapture.capture(window: window, maxHeight: CGFloat(maxHeight), maxBytes: maxBytes) }
                    guard let s = shot else {
                        self.busy = false
                        return
                    }
                    let meta = Team.meta(
                        screen: screen, device: engine.env.device, width: s.width, height: s.height, scale: s.scale,
                        takenAt: Date())
                    ApplePlatform.shared.run { e in
                        e.team.upload(screen: screen, meta: meta, jpeg: s.jpeg, tree: s.tree) { _ in
                            DispatchQueue.main.async { self.busy = false }
                        }
                    }
                }
            }
        }
    }

    /// Idle: no animation running and no activity indicator turning in the window.
    static func isIdle(_ window: UIWindow) -> Bool {
        var stack: [UIView] = [window]
        var visited = 0
        while let v = stack.popLast(), visited < 4000 {
            visited += 1
            if v.isHidden || v.alpha < 0.01 { continue }
            if let a = v as? UIActivityIndicatorView, a.isAnimating { return false }
            if let keys = v.layer.animationKeys(), !keys.isEmpty { return false }
            stack.append(contentsOf: v.subviews)
        }
        return true
    }

    struct Shot {
        var jpeg: Data
        var width: Int
        var height: Int
        var scale: Double
        var tree: JSON
    }

    /// Captures the current screen (main thread).
    static func capture(window: UIWindow, maxHeight: CGFloat, maxBytes: Int) -> Shot? {
        let p = ApplePlatform.shared
        let screenRoot: UIView = p.screens.currentController?.viewIfLoaded.flatMap { $0.window === window ? $0 : nil } ?? window
        let scroll = p.scrolls.primary.flatMap { $0.window === window ? $0 : nil }
            ?? ScrollTracker.primaryContainer(in: screenRoot, window: window)
        var collector = TreeCollector(root: screenRoot, window: window)
        let image: UIImage
        let pixelScale: CGFloat
        if let s = scroll {
            // The image is the content, without its insets. Each strip is the part of the scroll view no bar covers:
            // since iOS 26 the system also fades content at the edges under the bars.
            let inset = s.adjustedContentInset
            let contentHeight = min(s.contentSize.height, maxHeight)
            let width = s.bounds.width
            guard width > 0, contentHeight > 0 else { return nil }
            pixelScale = scale(width: width, height: contentHeight, screen: window.screen.scale)
            let saved = s.contentOffset
            let free = (s.bounds.height - inset.top - inset.bottom).rounded(.down)
            let page = free >= 100 ? free : s.bounds.height
            let top = free >= 100 ? inset.top : 0
            // drawHierarchy paints what is transparent black, and SwiftUI's scroll views are transparent: they take
            // what shows through them for the time of the capture.
            let savedBackground = s.backgroundColor
            s.backgroundColor = backdrop(of: s, window: window)
            defer { s.backgroundColor = savedBackground }
            image = renderer(width: width, height: contentHeight, scale: pixelScale).image { ctx in
                var y: CGFloat = 0
                while y < contentHeight {
                    s.setContentOffset(CGPoint(x: saved.x, y: y - top), animated: false)
                    s.layoutIfNeeded()
                    let strip = CGRect(x: 0, y: y, width: width, height: page)
                    let cg = ctx.cgContext
                    cg.saveGState()
                    cg.clip(to: strip)
                    // The offset asked is not always the one obtained: a scroll view stops at its end, and a large title
                    // collapsing moves it. Drawing happens where the content really is, again if the draw itself moved it.
                    var drawn = CGFloat.nan
                    for _ in 0..<3 where drawn != s.contentOffset.y {
                        drawn = s.contentOffset.y
                        s.drawHierarchy(in: CGRect(x: 0, y: drawn, width: width, height: s.bounds.height), afterScreenUpdates: true)
                    }
                    cg.restoreGState()
                    // Frames in the scroll view's bounds are content coordinates: the image's.
                    let masks = collector.collect(in: s, space: s, origin: CGPoint(x: s.bounds.minX, y: 0), clip: strip)
                    fill(masks, in: cg)
                    y += page
                }
                s.setContentOffset(saved, animated: false)
            }
            if SwiftUIElements.hostingView(of: s) != nil {
                collector.addWhole(s, frame: CGRect(x: 0, y: 0, width: width, height: contentHeight))
            }
        } else {
            let size = window.bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            pixelScale = scale(width: size.width, height: size.height, screen: window.screen.scale)
            image = renderer(width: size.width, height: size.height, scale: pixelScale).image { ctx in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                let masks = collector.collect(in: window, space: window, origin: .zero, clip: window.bounds)
                fill(masks, in: ctx.cgContext)
            }
        }
        var quality: CGFloat = 0.8
        var jpeg = image.jpegData(compressionQuality: quality)
        while let j = jpeg, j.count > maxBytes, quality > 0.3 {
            quality -= 0.15
            jpeg = image.jpegData(compressionQuality: quality)
        }
        guard let data = jpeg, data.count <= maxBytes else { return nil }
        let w = Int((image.size.width * pixelScale).rounded())
        let h = Int((image.size.height * pixelScale).rounded())
        return Shot(jpeg: data, width: w, height: h, scale: Double(pixelScale), tree: collector.tree(scale: pixelScale))
    }

    static func scale(width: CGFloat, height: CGFloat, screen: CGFloat) -> CGFloat {
        var s = min(2, max(1, screen))
        let limit = sqrt(maxBitmapBytes / max(1, width * height * 4))
        if s > limit { s = max(0.5, limit) }
        // ≤ 4 096 × 20 000 pixels (the server's limits).
        s = min(s, 4096 / max(1, width), 20_000 / max(1, height))
        return s
    }

    static func renderer(width: CGFloat, height: CGFloat, scale: CGFloat) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
    }

    /// The colour behind a view: the nearest opaque background above it, else the system's.
    static func backdrop(of v: UIView, window: UIWindow) -> UIColor {
        var a: UIView? = v
        while let n = a {
            if let c = n.backgroundColor {
                var alpha: CGFloat = 0
                c.resolvedColor(with: window.traitCollection).getWhite(nil, alpha: &alpha)
                if alpha > 0.99 { return c }
            }
            a = n.superview
        }
        return .systemBackground
    }

    static func fill(_ rects: [CGRect], in ctx: CGContext) {
        guard !rects.isEmpty else { return }
        ctx.saveGState()
        ctx.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
        for r in rects { ctx.fill(r) }
        ctx.restoreGState()
    }
}

/// Collects the element tree of a capture (strip by strip) and the rectangles to mask.
struct TreeCollector {
    let root: UIView
    let window: UIWindow
    private var nodes = Fields()
    private var order: [String] = []

    init(root: UIView, window: UIWindow) {
        self.root = root
        self.window = window
    }

    /// Walks the visible views under `container`; frames go into image coordinates through `space` and `origin`.
    /// Returns the rectangles to mask (image points).
    mutating func collect(in container: UIView, space: UIView, origin: CGPoint, clip: CGRect) -> [CGRect] {
        var masks: [CGRect] = []
        let cache = Identity.Cache()
        var stack: [UIView] = [container]
        var visited = 0
        while let v = stack.popLast(), visited < 6000 {
            visited += 1
            if v.isHidden || v.alpha < 0.01 || v.scruterIgnore { continue }
            let f = v.convert(v.bounds, to: space).offsetBy(dx: -origin.x, dy: -origin.y)
            let masked = Elements.isMasked(v)
            if masked { masks.append(f) }
            if v !== container, order.count < ScreenCapture.maxNodes, f.width >= 1, f.height >= 1, f.intersects(clip),
                let kind = nodeKind(v)
            {
                let id = Identity.identify(v, root: v.isDescendant(of: root) ? root : window, cache: cache)
                let key = id.selector + "\u{1F}" + String(id.index)
                if nodes[key] == nil {
                    add(key, selector: id.selector, index: id.index, kind: kind, frame: f, masked: masked,
                        label: masked ? nil : Elements.label(of: v) ?? descendantLabel(v, kind: kind))
                }
            }
            // A control is one element: its insides are the system's.
            if masked || v is UIControl { continue }
            stack.append(contentsOf: v.subviews.reversed())
        }
        return masks
    }

    /// The element that stands for a whole SwiftUI content (taps that hit no identified element land on it).
    mutating func addWhole(_ v: UIView, frame: CGRect) {
        let id = Identity.identify(v, root: v.isDescendant(of: root) ? root : window)
        let key = id.selector + "\u{1F}" + String(id.index)
        if nodes[key] == nil { add(key, selector: id.selector, index: id.index, kind: .container, frame: frame, masked: false, label: nil) }
    }

    private mutating func add(
        _ key: String, selector: String, index: Int, kind: ElementKind, frame f: CGRect, masked: Bool, label: String?
    ) {
        var n: Fields = [
            "s": .string(selector), "i": .int(Int64(min(9999, index))), "k": .string(kind.rawValue),
            "x": .double(Double(max(0, f.minX))), "y": .double(Double(max(0, f.minY))),
            "w": .double(Double(max(0, f.width))), "h": .double(Double(max(0, f.height))),
            "m": .int(masked ? 1 : 0),
        ]
        if !masked, let l = label, !l.isEmpty { n["l"] = .string(l) }
        nodes[key] = .object(n)
        order.append(key)
    }

    /// Which views are nodes: interactive elements, cells, text, images and media, elements with an explicit
    /// identifier, section headers (`container`, the blocks of "time per block").
    private func nodeKind(_ v: UIView) -> ElementKind? {
        if let m = v as? ScruterMarkerView {
            if m.marker.mask { return .other }
            return m.marker.id != nil ? (m.marker.kind == .container ? .container : m.marker.kind) : nil
        }
        if Elements.isWebView(v) { return .web }
        if v is UITableViewHeaderFooterView || SwiftUIElements.isHosting(v) { return .container }
        if v is UICollectionReusableView && !(v is UICollectionViewCell) { return .container }
        let kind = Elements.kind(of: v)
        if Elements.isInteractive(v) || Elements.isMasked(v) { return kind }
        switch kind {
        case .text, .image, .media, .cell, .input, .choice, .tab, .link, .button: return kind
        default: break
        }
        if Identity.hasStableExplicit(v) { return v.subviews.isEmpty ? kind : .container }
        return nil
    }

    /// A button's label is often its inner label.
    private func descendantLabel(_ v: UIView, kind: ElementKind) -> String? {
        guard kind == .button || kind == .cell || kind == .tab || kind == .link else { return nil }
        var stack = v.subviews
        var visited = 0
        while let s = stack.popLast(), visited < 50 {
            visited += 1
            if Elements.isMasked(s) { continue }
            if let l = s as? UILabel, let t = l.text, !t.isEmpty { return Text.clean(t, max: 80) }
            stack.append(contentsOf: s.subviews)
        }
        return nil
    }

    /// The tree in the image's pixels.
    func tree(scale: CGFloat) -> JSON {
        let list: [JSON] = order.compactMap { key in
            guard case .object(var n)? = nodes[key] else { return nil }
            for k in ["x", "y", "w", "h"] {
                let v = n[k]?.doubleValue ?? 0
                n[k] = .int(Int64(max(0, min(20_000, (v * Double(scale)).rounded()))))
            }
            return .object(n)
        }
        return ["v": 1, "nodes": .array(list)]
    }
}
#endif
