#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

#if canImport(WebKit)
import WebKit
#endif

private var scruterIdKey: UInt8 = 0
private var scruterMaskKey: UInt8 = 0
private var scruterIgnoreKey: UInt8 = 0
private var scruterFormKey: UInt8 = 0
private var scruterScreenNameKey: UInt8 = 0

extension UIView {
    /// A stable identifier for Scruter (taps, forms, the team phones' element tree), when the view has no
    /// `accessibilityIdentifier` of its own (docs/MOBILE.md §3.5).
    public var scruterId: String? {
        get { Elements.bridged(self)?.id ?? objc_getAssociatedObject(self, &scruterIdKey) as? String }
        set {
            Elements.usesIds = true
            objc_setAssociatedObject(self, &scruterIdKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }

    /// Masks the view (and everything in it) in the team phones' screen images; text inputs always are.
    public var scruterMask: Bool {
        get {
            guard Elements.usesMarks else { return false }
            return Elements.bridged(self)?.mask == true || (objc_getAssociatedObject(self, &scruterMaskKey) as? Bool) ?? false
        }
        set {
            if newValue { Elements.usesMarks = true }
            objc_setAssociatedObject(self, &scruterMaskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Ignores the view and everything in it: no tap, no field, nothing in the element tree.
    public var scruterIgnore: Bool {
        get {
            guard Elements.usesMarks else { return false }
            return Elements.bridged(self)?.ignore == true || (objc_getAssociatedObject(self, &scruterIgnoreKey) as? Bool) ?? false
        }
        set {
            if newValue { Elements.usesMarks = true }
            objc_setAssociatedObject(self, &scruterIgnoreKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Groups the fields inside the view as one form ("Delivery"); without it a screen's fields are one form named
    /// after the screen.
    public var scruterForm: String? {
        get { Elements.bridged(self)?.form ?? objc_getAssociatedObject(self, &scruterFormKey) as? String }
        set { objc_setAssociatedObject(self, &scruterFormKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

extension UIViewController {
    /// The screen's name, counted when the controller appears (else its type name without `ViewController`).
    public var scruterScreenName: String? {
        get { objc_getAssociatedObject(self, &scruterScreenNameKey) as? String }
        set { objc_setAssociatedObject(self, &scruterScreenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

/// UIKit views as identity nodes (docs/MOBILE.md §3.5).
extension UIView: IdentityNode {
    var identityParent: IdentityNode? { superview }

    var identityChildren: [IdentityNode] {
        let views = subviews
        // Most views of a large screen are leaves: no cast for them.
        if views.isEmpty || scruterIgnore || scruterMask || Elements.isMaskedByDefault(self) { return [] }
        return views.filter { !$0.isHidden && $0.alpha > 0.01 && !$0.scruterIgnore }
    }

    var identityExplicit: String? {
        if Elements.usesIds, let id = scruterId, !id.isEmpty { return id }
        if Elements.usesMarkers, let marker = self as? ScruterMarkerView, let id = marker.marker.id { return id }
        if let id = accessibilityIdentifier, !id.isEmpty { return id }
        return nil
    }

    var identityTypeKey: ObjectIdentifier { ObjectIdentifier(type(of: self)) }
    var identityTypeName: String { String(describing: type(of: self)) }
    var identityKind: ElementKind { Elements.kind(of: self) }
    var identityItemIndex: Int? { Elements.itemIndex(of: self) }
}

enum Elements {
    /// Set by the first `scruterMask` or `scruterIgnore`: most apps have none, and walking a screen then skips two
    /// associated-object lookups per view (§3.18, identity of a tap ≤ 0.5 ms). Main thread only.
    static var usesMarks = false
    /// Likewise for `scruterId` and for SwiftUI's marker views.
    static var usesIds = false
    static var usesMarkers = false

    /// What a cross-platform SDK says about a view (`Scruter._setElementInspector`), and the last answer: a walk asks
    /// several times in a row about the same view. Main thread only.
    static var inspector: ((UIView) -> BridgeElement?)? {
        didSet {
            if inspector != nil {
                usesMarks = true
                usesIds = true
            }
            lastInspected = nil
            lastElement = nil
        }
    }
    private static weak var lastInspected: UIView?
    private static var lastElement: BridgeElement?

    /// Not inlined: its callers are the walk's hottest code and the binary's size is on a budget (§3.18).
    @inline(never)
    static func bridged(_ v: UIView) -> BridgeElement? {
        guard let inspect = inspector else { return nil }
        if lastInspected === v { return lastElement }
        let e = inspect(v)
        lastInspected = v
        lastElement = e
        return e
    }

    static func kind(of v: UIView) -> ElementKind {
        if usesMarkers, let m = v as? ScruterMarkerView { return m.marker.kind }
        if let k = bridged(v)?.kind, let kind = ElementKind(rawValue: k) { return kind }
        switch v {
        case is UITextField, is UISearchBar: return .input
        case let t as UITextView: return t.isEditable ? .input : .text
        case is UISwitch, is UISlider, is UISegmentedControl, is UIStepper, is UIDatePicker, is UIPickerView:
            return .choice
        case is UITableViewCell, is UICollectionViewCell: return .cell
        case is UIButton:
            return isTabItem(v) ? .tab : .button
        case is UIImageView: return .image
        case is UILabel: return .text
        default: break
        }
        if isTabItem(v) { return .tab }
        if isMedia(v) { return .media }
        let traits = v.accessibilityTraits
        if traits.contains(.link) { return .link }
        if traits.contains(.button) || hasTapGesture(v) || v is UIControl { return .button }
        return .other
    }

    static func isTabItem(_ v: UIView) -> Bool {
        let name = String(describing: type(of: v))
        return name == "UITabBarButton" || name == "_UITabButton" || v.superview is UITabBar
    }

    /// `web` in a team phone's tree, so that the server masks it whatever the tree says (§3.11).
    static func isWebView(_ v: UIView) -> Bool {
        #if canImport(WebKit)
        return v is WKWebView
        #else
        return false
        #endif
    }

    static func isMedia(_ v: UIView) -> Bool {
        if isWebView(v) { return true }
        let name = String(describing: type(of: v))
        return name.hasPrefix("MKMapView") || name.hasPrefix("AVPlayer") || name.contains("PlayerView")
    }

    /// Gesture recognizers the app added: UIKit keeps its own on some of its private views.
    static func hasTapGesture(_ v: UIView) -> Bool {
        guard let recognizers = v.gestureRecognizers, !recognizers.isEmpty else { return false }
        let name = String(describing: type(of: v))
        if name.hasPrefix("_") || name.hasSuffix("ContentView") && name.hasPrefix("UI") { return false }
        return recognizers.contains {
            $0.isEnabled && ($0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer)
        }
    }

    /// Step 1 of §3.5: an interactive element.
    static func isInteractive(_ v: UIView) -> Bool {
        if let i = bridged(v)?.interactive { return i }
        if let c = v as? UIControl { return c.isEnabled }
        if v is UITableViewCell || v is UICollectionViewCell || v is UITextView { return true }
        if hasTapGesture(v) { return true }
        let traits = v.accessibilityTraits
        return traits.contains(.button) || traits.contains(.link)
    }

    /// Text inputs and web views are always masked in screen images (§3.11).
    static func isMaskedByDefault(_ v: UIView) -> Bool {
        if v is UITextField || v is UISearchBar || isWebView(v) { return true }
        if let t = v as? UITextView, t.isEditable { return true }
        if usesMarkers, let m = v as? ScruterMarkerView, m.marker.mask { return true }
        return false
    }

    static func isMasked(_ v: UIView) -> Bool { v.scruterMask || isMaskedByDefault(v) }

    /// A masked or ignored ancestor (the view itself included), or nil.
    static func shelter(of v: UIView) -> (UIView, ignored: Bool)? {
        var a: UIView? = v
        var found: (UIView, Bool)?
        while let n = a {
            if n.scruterIgnore { return (n, true) }
            if found == nil && n.scruterMask { found = (n, false) }
            a = n.superview
        }
        return found
    }

    /// The item position of a table or collection cell, flattened over the sections (≤ 9 999).
    static func itemIndex(of v: UIView) -> Int? {
        if let i = bridged(v)?.index { return min(9999, max(0, i)) }
        if let cell = v as? UITableViewCell, let table = enclosing(UITableView.self, of: cell),
            let ip = table.indexPath(for: cell)
        {
            var n = ip.row
            for s in 0..<min(ip.section, table.numberOfSections) { n += table.numberOfRows(inSection: s) }
            return min(9999, n)
        }
        if let cell = v as? UICollectionViewCell, let cv = enclosing(UICollectionView.self, of: cell),
            let ip = cv.indexPath(for: cell)
        {
            var n = ip.item
            for s in 0..<min(ip.section, cv.numberOfSections) { n += cv.numberOfItems(inSection: s) }
            return min(9999, n)
        }
        return nil
    }

    static func enclosing<T: UIView>(_ type: T.Type, of v: UIView) -> T? {
        var a = v.superview
        while let n = a {
            if let t = n as? T { return t }
            a = n.superview
        }
        return nil
    }

    /// The tap's target (§3.5 step 1): the nearest interactive ancestor of the hit view (below `root`), else the hit
    /// view itself, climbing at most 3 levels out of private wrappers. Inside a masked element, the masked element;
    /// inside an ignored one, nothing.
    static func target(hit: UIView, root: UIView) -> (view: UIView, interactive: Bool)? {
        if let (shelter, ignored) = shelter(of: hit) {
            if ignored { return nil }
            return (shelter, isInteractive(shelter))
        }
        var a: UIView? = hit
        var depth = 0
        while let n = a, n !== root, depth < 40 {
            if isInteractive(n) { return (n, true) }
            a = n.superview
            depth += 1
        }
        var t = hit
        var climbs = 0
        while climbs < 3, let p = t.superview, p !== root, String(describing: type(of: t)).hasPrefix("_") {
            t = p
            climbs += 1
        }
        return (t, false)
    }

    /// React Native labels a view with the text of all that is inside it, masked elements and web pages included.
    private static func holdsMasked(_ v: UIView) -> Bool {
        var stack = v.subviews
        var visited = 0
        while let s = stack.popLast(), visited < 500 {
            visited += 1
            if isMasked(s) { return true }
            stack.append(contentsOf: s.subviews)
        }
        return visited >= 500
    }

    /// Visible text of a view for the team phones' tree (never for a masked view): its accessibility label, else its
    /// text, ≤ 80 characters.
    static func label(of v: UIView) -> String? {
        if isMasked(v) { return nil }
        var text: String?
        if let m = v as? ScruterMarkerView {
            text = m.marker.label
        } else if let l = v.accessibilityLabel, !l.isEmpty {
            if inspector != nil, holdsMasked(v) { return nil }
            text = l
        } else if let l = v as? UILabel {
            text = l.text
        } else if let b = v as? UIButton {
            text = b.currentTitle ?? b.titleLabel?.text
        } else if let s = v as? UISegmentedControl, s.selectedSegmentIndex >= 0 {
            text = s.titleForSegment(at: s.selectedSegmentIndex)
        } else if let t = v as? UITextView, !t.isEditable {
            text = t.text
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return Text.clean(t, max: 80)
    }
}
#endif
