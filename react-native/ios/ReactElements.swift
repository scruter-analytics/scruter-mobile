import UIKit
import WebKit

/// What the iOS SDK cannot read on React Native's host views (docs/MOBILE.md §20): `nativeID` and Scruter's marks,
/// what a press target is, and the position of a list's items. The other facts are UIKit's: `testID` is the view's
/// `accessibilityIdentifier`, text inputs are `UITextField`s, lists are `UIScrollView`s.
enum ReactElements {
    /// What a view's class says, once per class: a walk visits thousands of views of a few classes.
    private struct ClassFacts {
        var react: Bool
        var text: Bool
        var nativeIdKey: String?
    }

    private static var classes: [ObjectIdentifier: ClassFacts] = [:]
    private static var marks: [String: Marks] = [:]

    private static func facts(_ v: UIView) -> ClassFacts {
        let key = ObjectIdentifier(type(of: v))
        if let f = classes[key] { return f }
        let name = String(describing: type(of: v))
        let idKey = v.responds(to: NSSelectorFromString("nativeId")) ? "nativeId"
            : v.responds(to: NSSelectorFromString("nativeID")) ? "nativeID" : nil
        let f = ClassFacts(
            // A web view stays what the SDK says it is: the server masks that kind.
            react: name.hasPrefix("RCT") && !(v is WKWebView), text: name.contains("Paragraph") || name == "RCTTextView",
            nativeIdKey: idKey)
        classes[key] = f
        return f
    }

    private static func nativeId(_ v: UIView, _ f: ClassFacts) -> String? {
        guard let key = f.nativeIdKey else { return nil }
        return v.value(forKey: key) as? String
    }

    static func inspect(_ v: UIView) -> BridgeElement? {
        let f = facts(v)
        let field = v is UITextField || v is UITextView || v is UISwitch
        guard f.react || field else { return nil }
        let e = BridgeElement()
        // A field's props live on its wrapper, its UIKit control below it. `testID` too in the first Fabric (0.73).
        var raw = nativeId(v, f)
        if field, let host = v.superview, facts(host).react {
            if raw == nil { raw = nativeId(host, facts(host)) }
            if (v.accessibilityIdentifier ?? "").isEmpty { e.id = host.accessibilityIdentifier }
        }
        if let raw = raw, !raw.isEmpty {
            if raw.hasPrefix(Marks.prefix) {
                let m = marks[raw] ?? Marks(raw)
                if marks.count < 500 { marks[raw] = m }
                e.id = m.id ?? e.id
                e.mask = m.mask
                e.ignore = m.ignore
                e.form = m.form
                e.index = m.index
            } else if (v.accessibilityIdentifier ?? "").isEmpty, e.id?.isEmpty != false {
                // §3.5: `testID`, else `nativeID`.
                e.id = raw
            }
        }
        if f.text {
            e.kind = "text"
        } else if v.isAccessibilityElement, !(v is UIControl), !(v is UITextView) {
            // `Pressable` and the `Touchable`s are `accessible` by default: nothing else tells them on iOS, since
            // their handlers live in JavaScript. Their press stays silent for a disabled element.
            let traits = v.accessibilityTraits
            e.interactive = !traits.contains(.notEnabled)
            e.kind = traits.contains(.link) ? "link" : traits.contains(.image) ? "image" : "button"
        }
        if e.index == nil { e.index = ListPosition.index(of: v) }
        return e
    }
}

/// The marks `ScruterView` writes in `nativeID`: `scruter:m;g;i=<id>;f=<form>;c=<index>`, values percent-encoded.
struct Marks {
    static let prefix = "scruter:"
    var mask = false
    var ignore = false
    var id: String?
    var form: String?
    var index: Int?

    init(_ raw: String) {
        for part in raw.dropFirst(Marks.prefix.count).split(separator: ";") {
            if part == "m" {
                mask = true
            } else if part == "g" {
                ignore = true
            } else if part.count > 2 {
                let value = String(part.dropFirst(2))
                switch part.first {
                case "i": id = value.removingPercentEncoding
                case "f": form = value.removingPercentEncoding
                case "c": index = Int(value)
                default: break
                }
            }
        }
    }
}

/// The item position in a React Native list. `FlatList` keeps its items in JavaScript and mounts a window of them
/// between two empty spacers: the position is the rank among the mounted items, plus what the leading spacer stands
/// for. A list is told from a page of sections by those spacers, else by items of one height. Exact with items of one
/// height; `ScruterCell` gives the exact index otherwise (docs/MOBILE.md §20).
enum ListPosition {
    static func index(of v: UIView) -> Int? {
        // The cheap test first: this runs for every view of a walk.
        guard let content = v.superview, let up = content.superview else { return nil }
        guard up is UIScrollView || up.superview is UIScrollView, !v.subviews.isEmpty else { return nil }
        let siblings = content.subviews
        let horizontal = content.bounds.width > content.bounds.height
        let size = { (s: UIView) -> CGFloat in horizontal ? s.bounds.width : s.bounds.height }
        var rank = -1
        var extents: [CGFloat] = []
        for s in siblings where !s.subviews.isEmpty {
            if s === v { rank = extents.count }
            extents.append(size(s))
        }
        guard extents.count >= 3, rank >= 0 else { return nil }
        let leading = siblings.first.map { $0.subviews.isEmpty ? size($0) : 0 } ?? 0
        let trailing = siblings.last.map { $0.subviews.isEmpty ? size($0) : 0 } ?? 0
        let common = Dictionary(grouping: extents) { $0 }.values.map(\.count).max() ?? 0
        guard leading > 0 || trailing > 0 || common * 2 >= extents.count else { return nil }
        let average = extents.reduce(0, +) / CGFloat(extents.count)
        return (average > 0 ? Int((leading / average).rounded()) : 0) + rank
    }
}
