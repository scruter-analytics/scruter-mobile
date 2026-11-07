#if canImport(UIKit) && canImport(SwiftUI) && !os(watchOS)
import SwiftUI
import UIKit

/// What a SwiftUI modifier marks: a hidden UIKit view in the modified view's background, with its frame, so that taps,
/// forms, masks and the team phones' element tree find SwiftUI elements. SwiftUI draws the rest without UIKit views,
/// and describes it through accessibility only while an assistive technology runs (nothing on an ordinary phone):
/// its elements cannot be told apart otherwise.
struct Marker: Equatable {
    var id: String?
    var kind: ElementKind = .other
    var mask = false
    var ignore = false
    var form: String?
    var label: String?
}

/// The marker view: never touched, never drawn, invisible to accessibility.
final class ScruterMarkerView: UIView {
    var marker = Marker() {
        didSet {
            scruterMask = marker.mask
            scruterIgnore = marker.ignore
            scruterForm = marker.form
        }
    }

    override init(frame: CGRect) {
        Elements.usesMarkers = true
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

struct ScruterMarkerRepresentable: UIViewRepresentable {
    let marker: Marker

    func makeUIView(context: Context) -> ScruterMarkerView {
        let v = ScruterMarkerView()
        v.marker = marker
        return v
    }

    func updateUIView(_ v: ScruterMarkerView, context: Context) {
        if v.marker != marker { v.marker = marker }
    }
}

struct ScruterScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Scruter.screen(name) }
    }
}

extension View {
    /// Counts a screen view named `name` each time this view appears (SwiftUI screens have no automatic name).
    public func scruterScreen(_ name: String) -> some View {
        modifier(ScruterScreenModifier(name: name))
    }

    /// A stable identifier for Scruter's taps and forms (`#add_to_cart`). `label`: its name in Screen analysis
    /// (SwiftUI's text cannot be read back from the screen).
    public func scruterId(_ id: String, label: String? = nil) -> some View {
        background(ScruterMarkerRepresentable(marker: Marker(id: id, kind: .button, label: label)))
    }

    /// Masks this view in the team phones' screen images (text inputs always are).
    public func scruterMask() -> some View {
        overlay(ScruterMarkerRepresentable(marker: Marker(kind: .other, mask: true)).allowsHitTesting(false))
    }

    /// Ignores this view: no tap, no field, nothing in the element tree.
    public func scruterIgnore() -> some View {
        overlay(ScruterMarkerRepresentable(marker: Marker(kind: .other, ignore: true)).allowsHitTesting(false))
    }

    /// Groups the fields inside this view as one form ("Delivery").
    public func scruterForm(_ name: String) -> some View {
        background(ScruterMarkerRepresentable(marker: Marker(kind: .container, form: name)))
    }
}

/// SwiftUI elements under a point: the marker views of a hosting view whose frame holds it.
enum SwiftUIElements {
    static func isHosting(_ v: UIView) -> Bool {
        String(describing: type(of: v)).contains("HostingView")
    }

    /// The nearest SwiftUI hosting view at or above `v`.
    static func hostingView(of v: UIView) -> UIView? {
        var a: UIView? = v
        while let n = a {
            if isHosting(n) { return n }
            a = n.superview
        }
        return nil
    }

    /// Marker views under `root` (bounded).
    static func markers(in root: UIView, limit: Int = 2000) -> [ScruterMarkerView] {
        var out = [ScruterMarkerView]()
        var stack = [root]
        var visited = 0
        while let v = stack.popLast(), visited < limit {
            visited += 1
            if let m = v as? ScruterMarkerView { out.append(m) }
            stack.append(contentsOf: v.subviews)
        }
        return out
    }

    /// The innermost marker of a given use containing `point` (window coordinates).
    static func marker(at point: CGPoint, in root: UIView, where match: (Marker) -> Bool) -> ScruterMarkerView? {
        var best: ScruterMarkerView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for m in markers(in: root) where match(m.marker) && m.window != nil {
            let f = m.convert(m.bounds, to: nil)
            let area = f.width * f.height
            if f.contains(point) && area < bestArea {
                best = m
                bestArea = area
            }
        }
        return best
    }
}
#endif
