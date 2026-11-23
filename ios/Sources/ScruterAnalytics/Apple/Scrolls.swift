#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// Scroll depth and the visible part of the screen's primary scroll container (docs/MOBILE.md §3.7–§3.8): the
/// largest vertically scrollable view covering ≥ 50 % of the window, observed through key-value observing of its
/// offset and content size (no timer).
final class ScrollTracker {
    private weak var container: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private weak var screenRoot: UIView?
    private var lastSent: (top: Double, bottom: Double, at: TimeInterval) = (0, 0, 0)
    private var searched = 0

    func screenStarted(controller: UIViewController?) {
        detach()
        screenRoot = controller?.viewIfLoaded
        searched = 0
        // After the screen's first layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.findContainerIfNeeded() }
    }

    /// Looks for the container again (at most 5 times per screen: after layout and after the first touches).
    func findContainerIfNeeded() {
        guard container == nil, searched < 5 else { return }
        searched += 1
        guard let window = ApplePlatform.keyWindow() else { return }
        let root = screenRoot?.window != nil ? screenRoot! : window
        guard let found = ScrollTracker.primaryContainer(in: root, window: window) else { return }
        attach(found)
    }

    static func primaryContainer(in root: UIView, window: UIWindow) -> UIScrollView? {
        let screenArea = window.bounds.width * window.bounds.height
        guard screenArea > 0 else { return nil }
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        var stack = [root]
        var visited = 0
        while let v = stack.popLast(), visited < 3000 {
            visited += 1
            if v.isHidden || v.alpha < 0.01 { continue }
            if let s = v as? UIScrollView, !(s is UITextView), s.isScrollEnabled, isVertical(s) {
                let frame = s.convert(s.bounds, to: window).intersection(window.bounds)
                let area = frame.width * frame.height
                if area >= screenArea * 0.5 && area > bestArea {
                    best = s
                    bestArea = area
                }
            }
            stack.append(contentsOf: v.subviews)
        }
        return best
    }

    static func isVertical(_ s: UIScrollView) -> Bool {
        if let cv = s as? UICollectionView, let flow = cv.collectionViewLayout as? UICollectionViewFlowLayout {
            return flow.scrollDirection == .vertical
        }
        if s is UITableView || s is UICollectionView { return true }
        let inset = s.adjustedContentInset
        return s.contentSize.height + inset.top + inset.bottom > s.bounds.height + 1 || s.alwaysBounceVertical
    }

    private func attach(_ s: UIScrollView) {
        detach()
        container = s
        observations = [
            s.observe(\.contentOffset, options: []) { [weak self] sv, _ in self?.changed(sv) },
            s.observe(\.contentSize, options: []) { [weak self] sv, _ in self?.changed(sv, force: true) },
        ]
        changed(s, force: true)
    }

    private func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        container = nil
        lastSent = (0, 0, 0)
    }

    /// The visible part as fractions of the content: by items for lazy lists (estimated heights), by points otherwise.
    static func visibleFraction(_ s: UIScrollView) -> (Double, Double, Int)? {
        if let t = s as? UITableView, let rows = t.indexPathsForVisibleRows, !rows.isEmpty {
            let total = (0..<t.numberOfSections).reduce(0) { $0 + t.numberOfRows(inSection: $1) }
            guard total > 0 else { return nil }
            func flat(_ ip: IndexPath) -> Int { (0..<ip.section).reduce(ip.row) { $0 + t.numberOfRows(inSection: $1) } }
            let first = rows.map(flat).min() ?? 0
            let last = rows.map(flat).max() ?? 0
            return (Double(first) / Double(total), Double(last + 1) / Double(total), Int(t.contentSize.height))
        }
        if let c = s as? UICollectionView, !c.indexPathsForVisibleItems.isEmpty {
            let total = (0..<c.numberOfSections).reduce(0) { $0 + c.numberOfItems(inSection: $1) }
            guard total > 0 else { return nil }
            func flat(_ ip: IndexPath) -> Int { (0..<ip.section).reduce(ip.item) { $0 + c.numberOfItems(inSection: $1) } }
            let items = c.indexPathsForVisibleItems.map(flat)
            return (Double(items.min() ?? 0) / Double(total), Double((items.max() ?? 0) + 1) / Double(total), Int(c.contentSize.height))
        }
        let inset = s.adjustedContentInset
        let content = s.contentSize.height + inset.top + inset.bottom
        guard content > 0 else { return nil }
        let top = (s.contentOffset.y + inset.top) / content
        let bottom = (s.contentOffset.y + inset.top + s.bounds.height) / content
        return (Double(top), Double(bottom), Int(content))
    }

    private func changed(_ s: UIScrollView, force: Bool = false) {
        guard let (top, bottom, height) = ScrollTracker.visibleFraction(s) else { return }
        let now = Date().timeIntervalSince1970
        let user = s.isTracking || s.isDragging || s.isDecelerating
        // At most four updates a second while scrolling, plus every new depth.
        guard force || bottom > lastSent.bottom + 0.02 || now - lastSent.at >= 0.25 else { return }
        if abs(top - lastSent.top) < 0.001 && abs(bottom - lastSent.bottom) < 0.001 && !force { return }
        lastSent = (top, bottom, now)
        if user { ApplePlatform.shared.reactions += 1 }
        let viewport = s.window?.bounds.size ?? .zero
        ApplePlatform.shared.run {
            $0.scrolled(
                top: top, bottom: bottom, contentHeight: height, viewport: (Int(viewport.width), Int(viewport.height)),
                user: user)
        }
    }

    /// The last position before the app goes to the background.
    func flush() {
        if let s = container { changed(s, force: true) }
    }

    var primary: UIScrollView? { container }
}
#endif
