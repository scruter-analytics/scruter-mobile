#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// Form fields (docs/MOBILE.md §3.9): focus, hesitation, changes and errors of text inputs and choices, never a value
/// nor its length. Passwords, one-time codes and payment fields are ignored entirely.
final class FormTracker {
    struct Field {
        var form: String?
        var key: String
        var type: String
    }

    private var fields: [(view: ObjectIdentifier, field: Field)] = []
    private weak var root: UIView?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(began(_:)), name: UITextField.textDidBeginEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(ended(_:)), name: UITextField.textDidEndEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(changed(_:)), name: UITextField.textDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(began(_:)), name: UITextView.textDidBeginEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(ended(_:)), name: UITextView.textDidEndEditingNotification, object: nil)
        nc.addObserver(self, selector: #selector(changed(_:)), name: UITextView.textDidChangeNotification, object: nil)
    }

    /// A new screen: its fields are found once laid out (Advanced analytics sessions only).
    func screenStarted(controller: UIViewController?) {
        fields = []
        root = controller?.viewIfLoaded
        guard ApplePlatform.shared.analysed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scan() }
    }

    /// Registers every field of the screen (forms seen), in depth-first order (their positions).
    func scan() {
        guard ApplePlatform.shared.analysed, let r = root ?? ApplePlatform.keyWindow() else { return }
        var positions = Fields()
        var found: [(Field, Int)] = []
        let markers = SwiftUIElements.markers(in: r).filter { $0.marker.form != nil }
        var stack = [r]
        var visited = 0
        while let v = stack.popLast(), visited < 3000, found.count < 400 {
            visited += 1
            if v.isHidden || v.scruterIgnore { continue }
            if let field = describe(v, markers: markers, positions: &positions) {
                found.append((field, (positions[field.form ?? ""]?.intValue ?? 1) - 1))
                remember(field, for: v)
                continue
            }
            stack.append(contentsOf: v.subviews.reversed())
        }
        guard !found.isEmpty else { return }
        ApplePlatform.shared.run { e in
            for (f, position) in found { e.formField(form: f.form, key: f.key, type: f.type, position: position) }
        }
    }

    private func describe(_ v: UIView, markers: [ScruterMarkerView], positions: inout Fields) -> Field? {
        let type: String
        var contentType: String?
        var secure = false
        switch v {
        case let t as UITextField:
            secure = t.isSecureTextEntry
            contentType = t.textContentType?.rawValue
            type = FormTracker.textType(keyboard: t.keyboardType, contentType: contentType)
        case let t as UITextView where t.isEditable:
            secure = t.isSecureTextEntry
            contentType = t.textContentType?.rawValue
            type = "textarea"
        case is UISwitch: type = "switch"
        case is UISegmentedControl: type = "segmented"
        case is UISlider: type = "slider"
        case is UIStepper: type = "stepper"
        case is UIDatePicker: type = "date"
        case is UIPickerView: type = "picker"
        default: return nil
        }
        let explicit = v.identityExplicit
        let form = formName(of: v, markers: markers)
        if FieldRules.isSensitive(secure: secure, contentType: contentType, names: [explicit, form]) { return nil }
        let formKey = form ?? ""
        let position = positions[formKey]?.intValue ?? 0
        positions[formKey] = .int(Int64(position + 1))
        let key: String
        if let id = explicit, Identity.isStable(id) {
            key = id
        } else if let ct = contentType, !ct.isEmpty {
            key = FieldRules.key(fromContentType: ct)
        } else {
            key = "\(type):\(position)"
        }
        return Field(form: form, key: Text.cut(key, max: 100), type: type)
    }

    private func formName(of v: UIView, markers: [ScruterMarkerView]) -> String? {
        var a: UIView? = v
        while let n = a {
            if let f = n.scruterForm, !(n is ScruterMarkerView) { return f }
            a = n.superview
        }
        let frame = v.convert(v.bounds, to: nil)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var best: (String, CGFloat)?
        for m in markers {
            let f = m.convert(m.bounds, to: nil)
            if f.contains(center), best == nil || f.width * f.height < best!.1 { best = (m.marker.form!, f.width * f.height) }
        }
        return best?.0
    }

    static func textType(keyboard: UIKeyboardType, contentType: String?) -> String {
        switch keyboard {
        case .emailAddress: return "email"
        case .phonePad: return "phone"
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: return "number"
        case .URL, .webSearch: return "url"
        default: return "text"
        }
    }

    private func field(for object: Any?) -> Field? {
        guard ApplePlatform.shared.analysed, let v = object as? UIView else { return nil }
        if let f = known(v) { return f }
        scan()
        return known(v)
    }

    private func known(_ v: UIView) -> Field? {
        let id = ObjectIdentifier(v)
        for f in fields where f.view == id { return f.field }
        return nil
    }

    private func remember(_ field: Field, for v: UIView) {
        let id = ObjectIdentifier(v)
        if known(v) == nil { fields.append((id, field)) }
    }

    /// A choice control tapped (switch, segmented control…): focus, change, blur.
    func choice(_ v: UIView) -> Field? {
        field(for: v)
    }

    @objc private func began(_ note: Notification) {
        ApplePlatform.shared.reactions += 1
        guard let f = field(for: note.object) else { return }
        ApplePlatform.shared.run { $0.formFocus(form: f.form, key: f.key) }
    }

    @objc private func ended(_ note: Notification) {
        guard let f = field(for: note.object) else { return }
        ApplePlatform.shared.run { $0.formBlur(form: f.form, key: f.key) }
    }

    @objc private func changed(_ note: Notification) {
        guard let f = field(for: note.object) else {
            ApplePlatform.shared.run { $0.interaction() }
            return
        }
        ApplePlatform.shared.run { $0.formChanged(form: f.form, key: f.key) }
    }
}
#endif
